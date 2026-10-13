import Foundation
import Testing

@MainActor private final class ProviderSecrets: SecretStore {
    var values: [String: String] = [:]
    var unreadable: Set<String> = []
    var failWrites = false
    func read(_ account: String) throws -> String {
        guard !unreadable.contains(account), let value = values[account] else { throw SettingsError("unreadable") }
        return value
    }
    func write(_ value: String, account: String) throws {
        guard !failWrites else { throw SettingsError("write failed") }
        values[account] = value
    }
    func remove(_ account: String) throws { values[account] = nil }
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
    /// Volcengine Ark starts from the Agent Plan's address, and only it gives a turn web_search,
    /// with its own saved model key. Any other provider has none, even at the same address.
    @Test @MainActor static func onlyVolcengineArkSearchesTheWeb() throws {
        let settings = SettingsStore(secrets: ProviderSecrets())
        settings.selectProvider(.volcengineArk)
        #expect(settings.draft == ModelConfiguration(baseURL: "https://ark.cn-beijing.volces.com/api/plan/v3", model: "", apiProtocol: .responses))
        #expect(DoubaoSearch.searcher(for: settings) == nil, "Nothing is saved yet")
        settings.draft.model = "doubao-seed-2.0-mini"; settings.apiKey = " ark-plan-key "; settings.save()
        try #require(settings.notice == nil && settings.snapshot.activeProvider == .volcengineArk)
        #expect(DoubaoSearch.searcher(for: settings)?.key == "ark-plan-key")
        for provider in [ModelProvider.openAI, .deepSeek, .ollama, .custom] {
            settings.selectProvider(provider)
            settings.draft.baseURL = provider == .ollama ? "http://localhost:11434/v1" : "https://ark.cn-beijing.volces.com/api/plan/v3"
            settings.draft.model = "model"; if provider.requiresKey { settings.apiKey = "ark-plan-key" }
            settings.save()
            try #require(settings.notice == nil && settings.snapshot.activeProvider == provider)
            #expect(DoubaoSearch.searcher(for: settings) == nil, "\(provider)")
        }
        settings.selectProvider(.volcengineArk); settings.save()
        #expect(DoubaoSearch.searcher(for: settings)?.key == "ark-plan-key", "Switching back brings it back")
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
        secrets.values = ["deepseek": "deepseek-secret", "voice": "agent-plan-secret"]
        let saved = #"{"version":2,"activeProvider":"deepSeek","providers":{"deepSeek":{"model":{"baseURL":"https://api.deepseek.com/v1","model":"existing-deepseek","apiProtocol":"chatCompletions"},"secretAccount":"deepseek"}},"selectedPetID":"builtin:chiyan","voiceSecretAccount":"voice"}"#
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
                     "Saving a model provider leaves the voice key alone")
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
    /// The connection test runs the injected tester with the typed configuration.
    @Test @MainActor static func connectionTestUsesTheAgentTester() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-settings-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        try Data(#"{"version":2,"activeProvider":"ollama","providers":{"ollama":{"model":{"baseURL":"http://localhost:11434/v1","model":"m","apiProtocol":"chatCompletions"}}},"selectedPetID":"builtin:chiyan"}"#.utf8).write(to: url)
        let tester = RecordingTester()
        let settings = SettingsStore(url: url, secrets: ProviderSecrets(), tester: tester)
        #expect(settings.notice == nil)
        settings.testConnection()
        try await eventually("the connection test ends") { !settings.testing }
        #expect(tester.count == 1 && settings.testSucceeded)
    }
    private final class RecordingTester: ConnectionTesting, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        var count: Int { lock.withLock { calls } }
        func test(configuration: ModelConfiguration, key: String) async throws { lock.withLock { calls += 1 } }
    }
    private static func tryValue<T>(_ body: () throws -> T) throws -> T { try body() }
}
