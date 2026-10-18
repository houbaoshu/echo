import Foundation
import Testing

@MainActor private final class ProviderSecrets: SecretStore {
    var values: [String: String] = [:]
    var unreadable: Set<String> = []
    var failWrites = false
    var failRemoves: Set<String> = []
    func read(_ account: String) throws -> String {
        guard !unreadable.contains(account), let value = values[account] else { throw SettingsError("unreadable") }
        return value
    }
    func write(_ value: String, account: String) throws {
        guard !failWrites else { throw SettingsError("write failed") }
        values[account] = value
    }
    func remove(_ account: String) throws {
        guard !failRemoves.contains(account) else { throw SettingsError("remove failed") }
        values[account] = nil
    }
}

@MainActor private func withSavedProviders(_ body: (URL, ProviderSecrets, SettingsStore) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("provider-failure-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("settings.json"), secrets = ProviderSecrets()
    let settings = SettingsStore(url: url, secrets: secrets)
    settings.selectProvider(.deepSeek)
    settings.draft.model = "existing-deepseek"; settings.apiKey = "rotated-deepseek"; settings.save()
    try #require(settings.notice == nil)
    settings.selectProvider(.ollama)
    settings.draft.model = "local-model"; settings.save()
    try #require(settings.notice == nil && settings.snapshot.activeProvider == .ollama)
    try body(url, secrets, SettingsStore(url: url, secrets: secrets))
}

@Suite(.serialized) enum SettingsTests {
    /// With a Volcengine Ark key, voice uses it whether or not Ark chats; chat goes to Volcengine
    /// Ark — its key, its language model, the Agent Plan's address — and search to Doubao search
    /// only with the switch on, and both to the model service, here DeepSeek, otherwise. Without a
    /// key the switch will not turn on, and the model service's key never stands in for voice.
    @Test(arguments: [false, true], [nil, " ark-key "] as [String?])
    @MainActor static func theArkKeyAndSwitchDecideWhatEachServiceUses(useForChat: Bool, arkKey: String?) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ark-key-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json"), secrets = ProviderSecrets()
        let settings = SettingsStore(url: url, secrets: secrets)
        #expect(settings.arkDraft == ArkSettings() && settings.arkDraft.languageModel == "doubao-seed-2.0-mini"
                && settings.arkDraft.visionModel == "doubao-seedream-5.0-pro" && !settings.arkDraft.useForChat)
        settings.selectProvider(.deepSeek)
        settings.draft.model = "deepseek-chat"; settings.apiKey = "model-page-key"
        if let arkKey { settings.arkAPIKey = arkKey }
        #expect(settings.canUseArkForChat == (arkKey != nil))
        settings.arkDraft.useForChat = useForChat
        let on = useForChat && arkKey != nil
        #expect(settings.arkDraft.useForChat == on, "The switch turns on only with a key")
        #expect(settings.canTestArk == (arkKey != nil) && settings.canTestModelService, "Each group's test needs its own key")
        if arkKey != nil {
            #expect(AgentWebSearcher.searcher(for: settings) == nil && ArkImageGenerator.generator(for: settings) == nil && !settings.canTestVoice,
                    "An unsaved key is not used yet")
        }
        settings.save(); settings.saveArk()
        try #require(settings.notice == nil && settings.arkNotice == nil && !settings.isDirty && !settings.isArkDirty)
        for store in [settings, SettingsStore(url: url, secrets: secrets)] {
            let saved = arkKey == nil ? nil : "ark-key"
            let search = AgentWebSearcher.searcher(for: store)
            #expect(search?.service == (on ? .doubao : .deepSeek) && search?.key == (on ? "ark-key" : "model-page-key"), "search")
            let images = ArkImageGenerator.generator(for: store)
            #expect(images?.key == saved && images.map { $0.model == "doubao-seedream-5.0-pro" } != false, "images, with the vision model")
            #expect((try? store.savedVoiceCredentials().key) == saved, "voice")
            #expect(store.canTestVoice == (saved != nil))
            let chat = try store.savedModelCredentials()
            if on {
                #expect(chat.key == "ark-key" && chat.configuration == ModelConfiguration(
                    baseURL: "https://ark.cn-beijing.volces.com/api/plan/v3", model: "doubao-seed-2.0-mini", apiProtocol: .responses))
            } else {
                #expect(chat.key == "model-page-key" && chat.configuration.model == "deepseek-chat", "The model service chats")
            }
        }
    }

    /// web_search follows whoever chats: Doubao search with the Volcengine Ark key while Volcengine
    /// Ark chats, DeepSeek Search with the DeepSeek key while DeepSeek does, and none with any other
    /// model service. Neither key stands in for the other, and a key not saved is not used.
    @Test @MainActor static func webSearchFollowsWhoeverChats() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("search-route-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json"), secrets = ProviderSecrets()
        let settings = SettingsStore(url: url, secrets: secrets)
        func route(_ store: SettingsStore = settings) -> String? {
            AgentWebSearcher.searcher(for: store).map { "\($0.service.rawValue) \($0.key)" }
        }
        settings.selectProvider(.deepSeek); settings.draft.model = "deepseek-chat"; settings.save()
        #expect(route() == nil, "DeepSeek without a key of its own")
        settings.apiKey = " deepseek-key "
        #expect(route() == nil, "A key not saved yet")
        settings.save()
        #expect(route() == "deepseek deepseek-key")
        settings.arkAPIKey = "ark-key"; settings.saveArk()
        #expect(!settings.snapshot.ark.useForChat && route() == "deepseek deepseek-key", "An Ark key alone changes nothing")
        settings.arkDraft.useForChat = true; settings.saveArk()
        #expect(route() == "doubao ark-key", "Volcengine Ark chats")
        #expect(route(SettingsStore(url: url, secrets: secrets)) == "doubao ark-key")

        settings.arkDraft.useForChat = false; settings.saveArk()
        settings.selectProvider(.custom); settings.draft.baseURL = "https://llm.example.com/v1"; settings.draft.model = "m"
        settings.apiKey = "custom-key"; settings.save()
        try #require(settings.notice == nil && settings.snapshot.activeProvider == .custom)
        #expect(route() == nil, "A custom service has no search, even with both other keys saved")
        settings.selectProvider(.openAI); settings.draft.model = "gpt"; settings.apiKey = "openai-key"; settings.save()
        #expect(route() == nil && route(SettingsStore(url: url, secrets: secrets)) == nil)
        settings.arkDraft.useForChat = true; settings.saveArk()
        #expect(route() == "doubao ark-key", "Volcengine Ark chats, whatever the model service")

        // A key that cannot be read leaves no search: the other key does not stand in.
        settings.selectProvider(.deepSeek); settings.save()
        secrets.unreadable = [try #require(settings.snapshot.arkSecretAccount)]
        let unreadable = SettingsStore(url: url, secrets: secrets)
        #expect(unreadable.snapshot.ark.useForChat && route(unreadable) == nil)
        secrets.unreadable = []
        settings.arkDraft.useForChat = false; settings.saveArk()
        secrets.unreadable = [try #require(settings.snapshot.secretAccount)]
        #expect(route(SettingsStore(url: url, secrets: secrets)) == nil)
    }

    /// Emptying the Volcengine Ark key turns the switch back off, so chat returns to the model
    /// service once the page is saved.
    @Test @MainActor static func clearingTheArkKeyTurnsTheSwitchOff() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ark-switch-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json"), secrets = ProviderSecrets()
        let settings = SettingsStore(url: url, secrets: secrets)
        settings.selectProvider(.deepSeek); settings.draft.model = "deepseek-chat"; settings.apiKey = "deepseek-key"
        settings.arkAPIKey = "ark-key"; settings.arkDraft.useForChat = true; settings.arkDraft.languageModel = " doubao-pro "
        settings.save(); settings.saveArk()
        #expect(try settings.savedModelCredentials().configuration.model == "doubao-pro", "The language model is trimmed")
        settings.arkAPIKey = "  "
        #expect(!settings.arkDraft.useForChat && !settings.canUseArkForChat && !settings.canTestArk)
        settings.arkDraft.useForChat = true
        #expect(!settings.arkDraft.useForChat, "It cannot be turned back on without a key")
        settings.saveArk()
        #expect(!settings.snapshot.ark.useForChat && settings.savedArkKey == nil)
        #expect(try settings.savedModelCredentials().key == "deepseek-key")

        settings.arkAPIKey = "ark-key"; settings.arkDraft.useForChat = true; settings.arkDraft.languageModel = " "
        settings.saveArk()
        #expect(settings.arkNotice != nil && !settings.snapshot.ark.useForChat, "Ark chat needs a language model")
    }

    /// Settings from when Volcengine Ark was a provider: chosen, it becomes the switch turned on,
    /// with its default model as the language model and the first provider set up as the model service.
    /// Not chosen, only its entry goes. The key is not moved: without one the switch stays off.
    @Test(arguments: [true, false])
    @MainActor static func volcengineArkAsAProviderBecomesTheSwitch(withArkKey: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ark-format-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json"), secrets = ProviderSecrets()
        secrets.values = ["deepseek": "deepseek-key", "model-ark-old": "old-ark-model-key"]
        if withArkKey { secrets.values["ark"] = "ark-key" }
        let ark = withArkKey ? #","arkSecretAccount":"ark""# : ""
        try Data((#"{"version":2,"activeProvider":"volcengineArk","providers":{"volcengineArk":{"model":{"baseURL":"https://ark.cn-beijing.volces.com/api/plan/v3","model":"doubao-old","apiProtocol":"responses"},"secretAccount":"model-ark-old"},"deepSeek":{"model":{"baseURL":"https://api.deepseek.com","model":"deepseek-chat","apiProtocol":"chatCompletions"},"secretAccount":"deepseek"}},"selectedPetID":"builtin:chiyan""# + ark + "}").utf8).write(to: url)
        let settings = SettingsStore(url: url, secrets: secrets)
        #expect(settings.snapshot.activeProvider == .deepSeek && settings.selectedProvider == .deepSeek && settings.apiKey == "deepseek-key")
        #expect(settings.snapshot.ark.languageModel == "doubao-old" && settings.snapshot.ark.useForChat == withArkKey)
        #expect(!settings.isDirty && !settings.isArkDirty, "Carrying the format over is no edit")
        #expect(secrets.values["model-ark-old"] == nil && secrets.values["deepseek"] == "deepseek-key")
        #expect(try settings.savedModelCredentials().key == (withArkKey ? "ark-key" : "deepseek-key"))
        try settings.selectPet("builtin:other")
        let file = try String(contentsOf: url, encoding: .utf8)
        #expect(!file.contains("volcengineArk") && file.contains("doubao-old"), "The next save writes the new format")
        let reopened = SettingsStore(url: url, secrets: secrets)
        #expect(reopened.snapshot.ark.useForChat == withArkKey && reopened.snapshot.activeProvider == .deepSeek)

        // Volcengine Ark set up but not chosen: the switch stays off and the provider stays.
        try Data(#"{"version":2,"activeProvider":"deepSeek","providers":{"volcengineArk":{"model":{"baseURL":"https://ark.cn-beijing.volces.com/api/plan/v3","model":"doubao-old","apiProtocol":"responses"}},"deepSeek":{"model":{"baseURL":"https://api.deepseek.com","model":"deepseek-chat","apiProtocol":"chatCompletions"},"secretAccount":"deepseek"}},"selectedPetID":"builtin:chiyan","arkSecretAccount":"ark"}"#.utf8).write(to: url)
        secrets.values["ark"] = "ark-key"
        let notChosen = SettingsStore(url: url, secrets: secrets)
        #expect(!notChosen.snapshot.ark.useForChat && notChosen.snapshot.ark.languageModel == ArkSettings.defaultLanguageModel)
        #expect(notChosen.snapshot.activeProvider == .deepSeek && notChosen.snapshot.providers["volcengineArk"] == nil)
    }

    /// The Volcengine Ark key lives in the keychain under its own account, which a change replaces
    /// and clearing removes, with nothing but the account name in settings.json.
    @Test @MainActor static func arkKeySavesReplacesAndClears() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ark-key-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json"), secrets = ProviderSecrets()
        let settings = SettingsStore(url: url, secrets: secrets)
        #expect(!settings.isArkDirty && settings.arkAPIKey.isEmpty)
        settings.arkAPIKey = "first"
        #expect(settings.isArkDirty && !settings.isDirty, "The Ark key is apart from the model service")
        settings.restoreArk()
        #expect(!settings.isArkDirty && settings.arkAPIKey.isEmpty, "Revert brings back the saved key")

        settings.arkAPIKey = "first\nsecond"; settings.saveArk()
        #expect(settings.arkNotice != nil && settings.snapshot.arkSecretAccount == nil && secrets.values.isEmpty)

        settings.arkAPIKey = " first "; settings.saveArk()
        let first = try #require(settings.snapshot.arkSecretAccount)
        #expect(settings.arkNotice == nil && !settings.isArkDirty && settings.arkAPIKey == "first")
        #expect(secrets.values == [first: "first"])
        let file = try String(contentsOf: url, encoding: .utf8)
        #expect(file.contains(first) && !file.contains("\"first\""), "settings.json names the account, not the key")
        #expect(SettingsStore(url: url, secrets: secrets).arkAPIKey == "first")

        settings.arkAPIKey = "second"; settings.saveArk()
        let second = try #require(settings.snapshot.arkSecretAccount)
        #expect(second != first && secrets.values == [second: "second"], "The old account is removed")

        secrets.failWrites = true
        settings.arkAPIKey = "third"; settings.saveArk()
        #expect(settings.arkNotice != nil && settings.snapshot.arkSecretAccount == second && settings.savedArkKey == "second")
        secrets.failWrites = false

        settings.arkAPIKey = ""; settings.saveArk()
        #expect(settings.arkNotice == nil && settings.snapshot.arkSecretAccount == nil && secrets.values.isEmpty)
        #expect(settings.savedArkKey == nil)

        settings.arkAPIKey = "fourth"; settings.saveArk()
        secrets.unreadable = [try #require(settings.snapshot.arkSecretAccount)]
        let unreadable = SettingsStore(url: url, secrets: secrets)
        #expect(unreadable.arkNotice != nil && unreadable.arkAPIKey.isEmpty && unreadable.savedArkKey == nil)
        #expect(throws: SettingsError.self) { try unreadable.savedVoiceCredentials() }
        unreadable.saveArk()
        #expect(unreadable.snapshot.arkSecretAccount != nil, "An unread key is not cleared by saving an empty field")
    }

    /// Before the Volcengine Ark group, voice kept its own key and Volcengine Ark chat its own.
    /// Neither is read: launch removes both, keychain and file, and leaves every other key alone.
    /// A key the keychain would not remove keeps its name, to be tried again at the next launch.
    @Test @MainActor static func launchRemovesTheKeysTheArkKeyReplaced() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ark-legacy-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json"), secrets = ProviderSecrets()
        secrets.values = ["voice-old": "old-voice-key", "model-ark-old": "old-ark-model-key", "deepseek": "deepseek-key"]
        try Data(#"{"version":2,"activeProvider":"volcengineArk","providers":{"volcengineArk":{"model":{"baseURL":"https://ark.cn-beijing.volces.com/api/plan/v3","model":"doubao","apiProtocol":"responses"},"secretAccount":"model-ark-old"},"deepSeek":{"model":{"baseURL":"https://api.deepseek.com","model":"deepseek-chat","apiProtocol":"chatCompletions"},"secretAccount":"deepseek"}},"selectedPetID":"builtin:chiyan","voiceSecretAccount":"voice-old"}"#.utf8).write(to: url)
        secrets.failRemoves = ["voice-old"]
        let first = SettingsStore(url: url, secrets: secrets)
        #expect(secrets.values == ["voice-old": "old-voice-key", "deepseek": "deepseek-key"])
        var file = try String(contentsOf: url, encoding: .utf8)
        #expect(file.contains("voice-old") && !file.contains("model-ark-old"), "Only the removed key's name goes")
        #expect(first.savedArkKey == nil, "The old keys are not read")
        #expect(throws: SettingsError.arkKeyMissing) { try first.savedVoiceCredentials() }

        secrets.failRemoves = []
        let second = SettingsStore(url: url, secrets: secrets)
        #expect(secrets.values == ["deepseek": "deepseek-key"], "The next launch tries again")
        file = try String(contentsOf: url, encoding: .utf8)
        #expect(!file.contains("voice-old") && !file.contains("model-ark-old") && file.contains("\"deepseek\""))
        #expect(second.snapshot.legacyVoiceSecretAccount == nil && second.snapshot.legacyArkSecretAccount == nil)
        #expect(second.selectedProvider == .deepSeek && second.apiKey == "deepseek-key")
    }

    /// Each group on the model page saves and reverts only itself, and reports why it could not
    /// be saved below its own box: an unsaveable model service never holds the Ark group back.
    @Test @MainActor static func eachGroupSavesAndRevertsItself() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("model-page-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json"), secrets = ProviderSecrets()
        let settings = SettingsStore(url: url, secrets: secrets)
        #expect(!settings.isDirty && !settings.canRestoreModel && !settings.isArkDirty)
        settings.arkAPIKey = "ark-key"
        #expect(settings.isArkDirty && !settings.isDirty && !settings.canRestoreModel, "The Ark key is only the Ark group's edit")
        settings.selectProvider(.openAI); settings.draft.model = "gpt"; settings.apiKey = "openai-key"
        settings.restore()
        #expect(!settings.isDirty && settings.selectedProvider == .deepSeek && settings.arkAPIKey == "ark-key",
                "Reverting the model service leaves the Ark group as typed")
        settings.restoreArk()
        #expect(!settings.isArkDirty && settings.arkAPIKey.isEmpty)

        settings.selectProvider(.deepSeek); settings.draft.model = "deepseek-chat"; settings.apiKey = "deepseek-key"
        settings.arkAPIKey = "ark-key"
        settings.save()
        #expect(settings.notice == nil && !settings.isDirty && settings.isArkDirty && settings.savedArkKey == nil,
                "Saving the model service leaves the Ark key unsaved")
        settings.saveArk()
        #expect(settings.arkNotice == nil && !settings.isArkDirty && settings.savedArkKey == "ark-key")
        #expect(try settings.savedModelCredentials().key == "deepseek-key")
        settings.arkDraft.visionModel = " seedream-next "
        #expect(settings.isArkDirty && !settings.isDirty, "The group's models are its edits too")
        settings.saveArk()
        #expect(settings.snapshot.ark.visionModel == "seedream-next" && !settings.isArkDirty)

        settings.draft.baseURL = "not a url"; settings.arkAPIKey = "not-held-back"
        settings.save()
        #expect(settings.modelServiceStatus == SettingsTestLine(text: settings.notice ?? "", succeeded: false) && settings.isDirty,
                "Why the model service could not be saved shows below its box")
        settings.saveArk()
        #expect(settings.savedArkKey == "not-held-back" && settings.arkStatus == nil, "The Ark group saves on its own")
        settings.testConnection()
        #expect(settings.notice == nil && settings.modelServiceStatus?.succeeded == false && settings.modelServiceStatus == settings.testResult,
                "A test's result takes the save error's place")
        settings.arkDraft.useForChat = true; settings.arkDraft.languageModel = ""
        settings.saveArk()
        #expect(settings.arkStatus == SettingsTestLine(text: "请输入火山方舟的语言模型。", succeeded: false) && settings.modelServiceStatus != nil)
        settings.restoreArk()
        #expect(settings.arkStatus == nil && settings.modelServiceStatus != nil, "Reverting a group clears only its report")
    }

    /// A new install starts on DeepSeek, the picker's first provider, at its own address, and
    /// Volcengine Ark's group at its defaults with the switch off.
    @Test @MainActor static func aNewInstallStartsOnDeepSeek() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("new-install-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json"), secrets = ProviderSecrets()
        let settings = SettingsStore(url: url, secrets: secrets)
        #expect(ModelProvider.allCases.first == .deepSeek)
        #expect(settings.snapshot.activeProvider == .deepSeek && settings.selectedProvider == .deepSeek)
        #expect(settings.draft == ModelConfiguration(baseURL: "https://api.deepseek.com", model: "") && !settings.isDirty && !settings.isArkDirty)
        #expect(settings.arkDraft == ArkSettings() && settings.arkDraft.languageModel == "doubao-seed-2.0-mini"
                && settings.arkDraft.visionModel == "doubao-seedream-5.0-pro" && !settings.arkDraft.useForChat)
        #expect(throws: SettingsError.modelNotConfigured) { try settings.savedModelCredentials() }
        settings.draft.model = "deepseek-chat"; settings.apiKey = "deepseek-key"; settings.save()
        let reopened = SettingsStore(url: url, secrets: secrets)
        #expect(reopened.snapshot.activeProvider == .deepSeek && reopened.snapshot.providers.keys.sorted() == ["deepSeek"])
        #expect(try reopened.savedModelCredentials().key == "deepseek-key")
    }

    @Test @MainActor static func localModelOnlyIsOffUntilChosenAndSaved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("local-only-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        try Data(#"{"version":2,"activeProvider":"openAI","providers":{"openAI":{"model":{"baseURL":"https://api.openai.com/v1","model":"","apiProtocol":"chatCompletions"}}},"selectedPetID":"builtin:chiyan"}"#.utf8).write(to: url)
        let settings = SettingsStore(url: url, secrets: ProviderSecrets())
        #expect(!settings.snapshot.localModelOnly, "Settings saved before the switch leave it off")
        settings.setLocalModelOnly(true)
        #expect(settings.snapshot.localModelOnly && settings.localModelNotice == nil)
        #expect(SettingsStore(url: url, secrets: ProviderSecrets()).snapshot.localModelOnly, "The choice is saved")
        settings.setLocalModelOnly(false)
        #expect(!SettingsStore(url: url, secrets: ProviderSecrets()).snapshot.localModelOnly)
    }

    @Test @MainActor static func providerDraftsAndCredentialRotation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("provider-settings-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        let secrets = ProviderSecrets()
        secrets.values = ["deepseek": "deepseek-secret", "ark": "agent-plan-secret"]
        let saved = #"{"version":2,"activeProvider":"deepSeek","providers":{"deepSeek":{"model":{"baseURL":"https://api.deepseek.com/v1","model":"existing-deepseek","apiProtocol":"chatCompletions"},"secretAccount":"deepseek"}},"selectedPetID":"builtin:chiyan","arkSecretAccount":"ark"}"#
        try Data(saved.utf8).write(to: url)
        let settings = SettingsStore(url: url, secrets: secrets)
        #expect(settings.selectedProvider == .deepSeek && settings.apiKey == "deepseek-secret")
        #expect(settings.snapshot.secretAccount == "deepseek" && settings.draft.model == "existing-deepseek")
        #expect(settings.draft.apiProtocol == .chatCompletions && !settings.isDirty)
        #expect(settings.snapshot.selectedPlanetID == SettingsSnapshot.defaultPlanetID,
                     "Settings saved before Live Voice had a planet fall back to the built-in one")
        #expect(secrets.values.count == 2, "Loading reads the saved references without touching Keychain")
        settings.selectProvider(.openAI)
        #expect(settings.apiKey.isEmpty && settings.draft == ModelProvider.openAI.defaults && settings.isDirty)
        #expect(try tryValue { try settings.savedModelCredentials().key } == "deepseek-secret", "Selection stays a draft until saved")
        #expect(try tryValue { try settings.savedVoiceCredentials().key } == "agent-plan-secret")
        settings.apiKey = "openai-secret"
        settings.draft = ModelConfiguration(baseURL: "https://gateway.example/v1/", model: "  custom-openai  ", apiProtocol: .responses)
        settings.selectProvider(.deepSeek)
        #expect(settings.apiKey == "deepseek-secret")
        settings.selectProvider(.openAI)
        #expect(settings.apiKey == "openai-secret" && settings.draft.apiProtocol == .responses, "Switching retains per-provider drafts")
        settings.save()
        #expect(settings.notice == nil && !settings.isDirty && settings.snapshot.activeProvider == .openAI)
        #expect(secrets.values["deepseek"] == "deepseek-secret", "Saving another provider must not delete its key")
        #expect(try tryValue { try settings.savedVoiceCredentials().key } == "agent-plan-secret",
                     "Saving a model provider leaves the Volcengine Ark key alone")
        let reopened = SettingsStore(url: url, secrets: secrets)
        #expect(reopened.selectedProvider == .openAI && reopened.apiKey == "openai-secret", "Explicit provider identity survives custom URLs")
        #expect(reopened.draft.baseURL == "https://gateway.example/v1" && reopened.draft.model == "custom-openai")
        reopened.selectProvider(.deepSeek)
        #expect(reopened.apiKey == "deepseek-secret" && reopened.draft.model == "existing-deepseek")
        reopened.apiKey = "rotated-deepseek"; reopened.save()
        #expect(secrets.values["deepseek"] == nil && secrets.values.values.contains("openai-secret"))
        reopened.selectProvider(.openAI)
        #expect(reopened.apiKey == "openai-secret" && reopened.draft.apiProtocol == .responses)
        reopened.apiKey = ""; reopened.save()
        #expect(!secrets.values.values.contains("openai-secret") && secrets.values.values.contains("rotated-deepseek"))
        reopened.selectProvider(.ollama)
        #expect(reopened.apiKey.isEmpty && reopened.draft.baseURL == "http://localhost:11434/v1")
        reopened.draft.model = "local-model"; reopened.apiKey = "must-not-save"; reopened.save()
        #expect(reopened.apiKey.isEmpty && reopened.snapshot.secretAccount == nil)
        #expect(try tryValue { try reopened.savedModelCredentials().key }.isEmpty)
        #expect(try tryValue { try reopened.savedVoiceCredentials().key } == "agent-plan-secret")
        reopened.selectProvider(.deepSeek)
        #expect(reopened.apiKey == "rotated-deepseek")
        reopened.restore()
        #expect(reopened.selectedProvider == .ollama && !reopened.isDirty)
        reopened.selectProvider(.deepSeek)
        reopened.apiKey = "discard-this-draft"
        reopened.selectProvider(.ollama)
        #expect(!reopened.isDirty && reopened.canRestoreModel, "Restore remains available for another provider's unsaved edits")
        reopened.restore()
        reopened.selectProvider(.deepSeek)
        #expect(reopened.apiKey == "rotated-deepseek")
        reopened.restore()
        try reopened.selectPet("new-pet"); try reopened.selectPlanet("builtin:test-planet")
        let reload = SettingsStore(url: url, secrets: secrets)
        #expect(reload.snapshot.selectedPetID == "new-pet" && reload.snapshot.selectedPlanetID == "builtin:test-planet",
                "Pet and planet choices survive a reload")
        let json = try String(contentsOf: url, encoding: .utf8)
        for key in secrets.values.values { #expect(!json.contains(key), "JSON must only store Keychain references") }
        #expect(!json.contains("must-not-save"))

    }

    @Test @MainActor static func unreadableCredentialDoesNotBlockAnotherProvider() throws {
        try withSavedProviders { url, secrets, reopened in
            // One provider's unreadable credential cannot block another or erase its own reference.
            let deepSeekAccount = try #require(reopened.snapshot.settings(for: .deepSeek).secretAccount)
            secrets.unreadable.insert(deepSeekAccount)
            let locked = SettingsStore(url: url, secrets: secrets)
            locked.selectProvider(.deepSeek)
            locked.draft.model = "changed"; locked.save()
            #expect(locked.notice != nil && locked.snapshot.activeProvider == .ollama)
            #expect(secrets.values[deepSeekAccount] == "rotated-deepseek")
            locked.selectProvider(.custom)
            locked.draft = ModelConfiguration(baseURL: "https://custom.example/v1", model: "custom")
            locked.apiKey = "custom-secret"; locked.save()
            #expect(locked.notice == nil && locked.snapshot.activeProvider == .custom)
            locked.selectProvider(.deepSeek)
            locked.apiKey = "replacement-deepseek"; locked.save()
            #expect(locked.notice == nil && secrets.values.values.contains("custom-secret"))
            #expect(try tryValue { try locked.savedModelCredentials().key } == "replacement-deepseek")
        }
    }

    @Test @MainActor static func failedCredentialAndDiskWritesRollBack() throws {
        try withSavedProviders { url, secrets, locked in
            locked.selectProvider(.custom)
            locked.draft = ModelConfiguration(baseURL: "https://custom.example/v1", model: "custom")
            locked.apiKey = "custom-secret"; locked.save()
            locked.selectProvider(.deepSeek)
            locked.apiKey = "replacement-deepseek"; locked.save()
            try #require(locked.notice == nil)
            // Failed Keychain/disk writes leave active configuration and all saved credentials intact.
            let before = secrets.values
            locked.selectProvider(.openAI); locked.apiKey = "failed-secret"
            secrets.failWrites = true; locked.save(); secrets.failWrites = false
            #expect(locked.notice != nil && secrets.values == before && locked.snapshot.activeProvider == .deepSeek)
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            locked.save()
            #expect(locked.notice != nil && secrets.values == before && locked.snapshot.activeProvider == .deepSeek)
            locked.restore()
            #expect(locked.apiKey == "replacement-deepseek")
        }
    }
    /// A file this build cannot read — another version, including the first, or a model without its
    /// protocol — is reported and kept: no save overwrites it.
    @Test(arguments: [
        (#"{"version":99}"#, true),
        (#"{"version":1,"model":{"baseURL":"https://api.deepseek.com/v1","model":"m"},"secretAccount":"old","selectedPetID":"builtin:chiyan"}"#, true),
        (#"{"version":2,"activeProvider":"openAI","providers":{"openAI":{"model":{"baseURL":"https://api.openai.com/v1","model":"m"}}},"selectedPetID":"builtin:chiyan"}"#, false),
    ])
    @MainActor static func unreadableFileIsPreserved(json: String, unsupportedVersion: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("provider-settings-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let secrets = ProviderSecrets()
        let unsupported = directory.appendingPathComponent("unsupported.json")
        let original = Data(json.utf8)
        try original.write(to: unsupported)
        let blocked = SettingsStore(url: unsupported, secrets: secrets)
        #expect((blocked.notice == SettingsSnapshot.unsupportedVersion.message) == unsupportedVersion && blocked.notice != nil)
        blocked.apiKey = "blocked-secret"; blocked.save()
        #expect(throws: SettingsError.self) { try blocked.selectPet("builtin:other") }
        let retained = try Data(contentsOf: unsupported)
        #expect(blocked.notice != nil && retained == original)
        #expect(!secrets.values.values.contains("blocked-secret"))
    }
    /// Each group tests itself, as typed and unsaved. The model service: one request that must call
    /// a tool, and only with its key when the provider takes one. Volcengine Ark: one search with
    /// the key, and the language model's tool calling when one is filled in, switch on or off.
    @Test @MainActor static func eachGroupTestsItself() async throws {
        let tester = RecordingTester(), arkTester = RecordingArkTester()
        let settings = SettingsStore(secrets: ProviderSecrets(), tester: tester, arkTester: arkTester)
        #expect(settings.selectedProvider == .deepSeek && !settings.canTestModelService, "No key, no model service test")
        #expect(!settings.canTestArk, "No Ark key, no Ark test")
        settings.draft.model = "deepseek-chat"; settings.apiKey = " typed-model-key "
        #expect(settings.canTestModelService)
        settings.testConnection()
        try await eventually("the model service test ends") { !settings.testing }
        #expect(tester.calls.map(\.key) == [" typed-model-key "] && tester.calls.last?.configuration.model == "deepseek-chat")
        #expect(settings.testResult == SettingsTestLine(text: "连接成功，指定协议已返回有效的工具调用。", succeeded: true))
        #expect(arkTester.keys.isEmpty && settings.arkTestResult == nil, "The Ark group is not tested with it")
        settings.selectProvider(.ollama)
        #expect(settings.canTestModelService, "A provider without a key can always be tested")

        settings.arkAPIKey = " typed-ark-key "
        #expect(settings.canTestArk && settings.arkTestResult == nil)
        settings.arkDraft.languageModel = ""
        arkTester.failure = SettingsError("refused")
        settings.testArk()
        try await eventually("the Ark search ends") { !settings.arkTesting }
        #expect(arkTester.keys == ["typed-ark-key"] && tester.calls.count == 1, "No language model, only the search")
        #expect(settings.arkTestResult == SettingsTestLine(text: "refused", succeeded: false))

        arkTester.failure = nil
        settings.arkDraft.languageModel = " doubao-typed "
        #expect(settings.arkTestResult == nil, "Editing the group clears its result")
        settings.testArk()
        try await eventually("the Ark test with a language model ends") { !settings.arkTesting }
        #expect(!settings.arkDraft.useForChat && tester.calls.last?.key == "typed-ark-key" && tester.calls.last?.configuration == ModelConfiguration(
            baseURL: "https://ark.cn-beijing.volces.com/api/plan/v3", model: "doubao-typed", apiProtocol: .responses),
            "The language model is tested with the switch off too")
        #expect(settings.arkTestResult == SettingsTestLine(text: "连接成功，联网搜索和工具调用均正常。", succeeded: true),
                "Both checks passing read as one sentence")
        #expect(settings.testResult == nil, "Changing provider cleared the model service's result, and the Ark test left it alone")

        // A failure reports only what failed, one line however many checks ran.
        tester.failure = SettingsError("no tools")
        settings.testArk()
        try await eventually("the Ark test with a failing language model ends") { !settings.arkTesting }
        #expect(settings.arkTestResult == SettingsTestLine(text: "语言模型：no tools", succeeded: false))
        arkTester.failure = SettingsError("refused.")
        settings.testArk()
        try await eventually("the Ark test with both failing ends") { !settings.arkTesting }
        #expect(settings.arkTestResult == SettingsTestLine(text: "refused. 语言模型：no tools", succeeded: false))
        tester.failure = nil
        settings.testArk()
        try await eventually("the Ark test with a failing search ends") { !settings.arkTesting }
        #expect(settings.arkTestResult == SettingsTestLine(text: "refused.", succeeded: false))
    }

    /// The first Volcengine Ark key saved while the model service has no key of its own turns
    /// "use for chat" on, once. With a model service key it stays off, and afterwards the switch
    /// is the person's.
    @Test @MainActor static func theFirstArkKeyTurnsArkChatOnOnlyWithoutAModelKey() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ark-first-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        let settings = SettingsStore(url: url, secrets: ProviderSecrets())
        settings.arkAPIKey = "ark-key"; settings.saveArk()
        #expect(settings.snapshot.ark.useForChat && settings.arkDraft.useForChat && !settings.isArkDirty)
        settings.arkDraft.useForChat = false; settings.saveArk()
        #expect(!settings.snapshot.ark.useForChat)
        settings.arkAPIKey = "rotated-ark-key"; settings.saveArk()
        #expect(!settings.snapshot.ark.useForChat, "Only the first key turns it on")

        let other = SettingsStore(url: directory.appendingPathComponent("other.json"), secrets: ProviderSecrets())
        other.draft.model = "deepseek-chat"; other.apiKey = "deepseek-key"; other.arkAPIKey = "ark-key"
        other.save(); other.saveArk()
        #expect(!other.snapshot.ark.useForChat && other.savedArkKey == "ark-key", "A model service key keeps it off")

        // Codex review #4: with the language model emptied, chat would have no model, so it stays
        // off and what is saved is valid.
        let emptied = SettingsStore(url: directory.appendingPathComponent("emptied.json"), secrets: ProviderSecrets())
        emptied.arkDraft.languageModel = " "; emptied.arkAPIKey = "ark-key"; emptied.saveArk()
        #expect(emptied.arkNotice == nil && !emptied.snapshot.ark.useForChat && emptied.savedArkKey == "ark-key")

        // Codex review #3: the model service as saved decides, not one picked and not saved.
        let picked = SettingsStore(url: directory.appendingPathComponent("picked.json"), secrets: ProviderSecrets())
        picked.draft.model = "deepseek-chat"; picked.apiKey = "deepseek-key"; picked.save()
        picked.selectProvider(.openAI)
        picked.arkAPIKey = "ark-key"; picked.saveArk()
        #expect(!picked.snapshot.ark.useForChat && (try? picked.savedModelCredentials().key) == "deepseek-key",
                "A saved DeepSeek key keeps it off while another provider without one is only picked")
        let ollama = SettingsStore(url: directory.appendingPathComponent("ollama.json"), secrets: ProviderSecrets())
        ollama.selectProvider(.ollama); ollama.draft.model = "llama"; ollama.save()
        ollama.selectProvider(.deepSeek)
        ollama.arkAPIKey = "ark-key"; ollama.saveArk()
        #expect(!ollama.snapshot.ark.useForChat, "Ollama, saved, needs no key, while DeepSeek is only picked")
    }

    private final class RecordingTester: ConnectionTesting, @unchecked Sendable {
        private let lock = NSLock()
        private var made: [(configuration: ModelConfiguration, key: String)] = []
        private var error: SettingsError?
        var calls: [(configuration: ModelConfiguration, key: String)] { lock.withLock { made } }
        var failure: SettingsError? { get { lock.withLock { error } } set { lock.withLock { error = newValue } } }
        func test(configuration: ModelConfiguration, key: String) async throws {
            let failure = lock.withLock { made.append((configuration, key)); return error }
            if let failure { throw failure }
        }
    }
    private final class RecordingArkTester: ArkConnectionTesting, @unchecked Sendable {
        private let lock = NSLock()
        private var made: [String] = []
        private var error: SettingsError?
        var keys: [String] { lock.withLock { made } }
        var failure: SettingsError? { get { lock.withLock { error } } set { lock.withLock { error = newValue } } }
        func test(key: String) async throws {
            let failure = lock.withLock { made.append(key); return error }
            if let failure { throw failure }
        }
    }
    private static func tryValue<T>(_ body: () throws -> T) throws -> T { try body() }
}
