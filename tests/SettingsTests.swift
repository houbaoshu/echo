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

@Suite(.serialized) enum SettingsTests {
    @Test @MainActor static func providerMigrationAndCredentialRollback() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("provider-settings-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        let secrets = ProviderSecrets()
        secrets.values = ["legacy": "deepseek-secret", "voice": "agent-plan-secret"]
        let legacy = #"{"version":1,"model":{"baseURL":"https://api.deepseek.com/v1","model":"existing-deepseek"},"secretAccount":"legacy","selectedPetID":"builtin:chiyan","voiceSecretAccount":"voice"}"#
        try Data(legacy.utf8).write(to: url)
        let settings = SettingsStore(url: url, secrets: secrets)
        #expect(settings.selectedProvider == .deepSeek && settings.apiKey == "deepseek-secret")
        #expect(settings.snapshot.secretAccount == "legacy" && settings.draft.model == "existing-deepseek")
        #expect(settings.draft.apiProtocol == .chatCompletions && !settings.isDirty)
        #expect(settings.snapshot.quickComposerHotKey, "Settings saved before the quick composer shortcut enable it")
        #expect(settings.snapshot.selectedPlanetID == SettingsSnapshot.defaultPlanetID,
                     "Settings saved before Live Voice had a planet fall back to the built-in one")
        #expect(secrets.values.count == 2, "Migration adopts the original reference without touching Keychain")
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
        #expect(secrets.values["legacy"] == "deepseek-secret", "Saving another provider must not delete the migrated key")
        #expect(try tryValue { try settings.savedVoiceCredentials().key } == "agent-plan-secret",
                     "Saving a model provider leaves the voice key alone")
        let reopened = SettingsStore(url: url, secrets: secrets)
        #expect(reopened.selectedProvider == .openAI && reopened.apiKey == "openai-secret", "Explicit provider identity survives custom URLs")
        #expect(reopened.draft.baseURL == "https://gateway.example/v1" && reopened.draft.model == "custom-openai")
        reopened.setQuickComposerHotKey(false)
        #expect(!reopened.snapshot.quickComposerHotKey && reopened.hotKeyNotice == nil
                     && !SettingsStore(url: url, secrets: secrets).snapshot.quickComposerHotKey, "Turning the shortcut off persists")
        reopened.selectProvider(.deepSeek)
        #expect(reopened.apiKey == "deepseek-secret" && reopened.draft.model == "existing-deepseek")
        reopened.apiKey = "rotated-deepseek"; reopened.save()
        #expect(secrets.values["legacy"] == nil && secrets.values.values.contains("openai-secret"))
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
        let json = try String(contentsOf: url, encoding: .utf8)
        for key in secrets.values.values { #expect(!json.contains(key), "JSON must only store Keychain references") }
        #expect(!json.contains("must-not-save"))

        // One provider's unreadable credential cannot block another or erase its own reference.
        let deepSeekAccount = reopened.snapshot.settings(for: .deepSeek).secretAccount!
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
    @Test(arguments: ["https://unknown.example/v1", "http://localhost:11434/v1", "http://localhost:8080/v1", "https://api.openai.com/v1"])
    @MainActor static func legacyEndpointMigration(baseURL: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("provider-settings-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let secrets = ProviderSecrets()
        secrets.values["voice"] = "agent-plan-secret"
        let provider: ModelProvider = baseURL == "http://localhost:11434/v1" ? .ollama : baseURL == "https://api.openai.com/v1" ? .openAI : .custom
        // Custom legacy endpoints and no-key local endpoints retain model configuration.

            let fixtureURL = directory.appendingPathComponent("\(UUID()).json")
            let data = try JSONSerialization.data(withJSONObject: ["version": 1, "selectedPetID": "pet",
                "model": ["baseURL": baseURL, "model": "legacy-model"], "secretAccount": "voice"])
            try data.write(to: fixtureURL)
            let migrated = SettingsStore(url: fixtureURL, secrets: secrets)
            #expect(migrated.selectedProvider == provider && migrated.draft.baseURL == baseURL && migrated.draft.model == "legacy-model")
            #expect(migrated.apiKey == (provider == .ollama ? "" : "agent-plan-secret"))
            try migrated.selectPet("new-pet")
            try migrated.selectPlanet("builtin:test-planet")
            let reload = SettingsStore(url: fixtureURL, secrets: secrets)
            #expect(reload.selectedProvider == provider && reload.snapshot.selectedPetID == "new-pet")
            #expect(reload.snapshot.selectedPlanetID == "builtin:test-planet", "The planet choice survives a reload")
    }
    @Test @MainActor static func unknownVersionIsPreserved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("provider-settings-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let secrets = ProviderSecrets()
        // Unknown versions cannot be overwritten by a model save.
        let unsupported = directory.appendingPathComponent("unsupported.json")
        let original = Data(#"{"version":99}"#.utf8)
        try original.write(to: unsupported)
        let blocked = SettingsStore(url: unsupported, secrets: secrets)
        blocked.apiKey = "blocked-secret"; blocked.save()
        let retained = try Data(contentsOf: unsupported)
        #expect(blocked.notice != nil && retained == original)
        #expect(!secrets.values.values.contains("blocked-secret"))

    }
    private static func tryValue<T>(_ body: () throws -> T) throws -> T { try body() }
}
