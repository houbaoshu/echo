import Foundation
import Security

enum ModelAPIProtocol: String, Codable, CaseIterable, Sendable {
    case chatCompletions
    case responses

    var title: String { self == .chatCompletions ? "Chat Completions" : "Responses" }
    var path: String { self == .chatCompletions ? "chat/completions" : "responses" }
}

struct ModelConfiguration: Codable, Equatable, Sendable {
    var baseURL = "https://api.openai.com/v1"
    var model = ""
    var apiProtocol: ModelAPIProtocol = .chatCompletions

    private enum CodingKeys: String, CodingKey { case baseURL, model, apiProtocol }

    func rootURL() throws -> URL {
        guard let parts = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.scheme == "https" || (parts.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host.lowercased())),
              let url = parts.url else { throw SettingsError(localized: "请输入 HTTPS API 根地址；本机服务可使用 HTTP。地址不能包含凭据、查询参数或片段。") }
        return url
    }
    func endpoint() throws -> URL { try rootURL().appendingPathComponent(apiProtocol.path) }
    func validated(requiresModel: Bool = true) throws -> Self {
        _ = try endpoint()
        var result = self
        result.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.baseURL.hasSuffix("/") { result.baseURL.removeLast() }
        result.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requiresModel || !result.model.isEmpty else { throw SettingsError(localized: "请输入默认模型。") }
        return result
    }
}

extension ModelConfiguration {
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try values.decode(String.self, forKey: .baseURL)
        model = try values.decode(String.self, forKey: .model)
        // Settings saved before protocol selection used Chat Completions.
        apiProtocol = try values.decodeIfPresent(ModelAPIProtocol.self, forKey: .apiProtocol) ?? .chatCompletions
    }
}

struct SettingsError: LocalizedError, Equatable {
    /// What the interface shows, in the interface language.
    let message: String
    /// What diagnostics record: the zh-Hans source text, so the voice log reads the same in
    /// every interface language. Equal to `message` for text that is not localized.
    let diagnostic: String
    init(_ message: String) { self.message = message; diagnostic = message }
    init(message: String, diagnostic: String) { self.message = message; self.diagnostic = diagnostic }
    init(localized resource: LocalizedStringResource) {
        self.init(message: String(localized: resource), diagnostic: resource.sourceText)
    }
    var errorDescription: String? { message }
    /// No default model is saved: a turn may use the local model instead.
    static let modelNotConfigured = SettingsError(localized: "请先在设置中配置并保存默认模型。")
}

extension LocalizedStringResource {
    /// The text in the source language, zh-Hans, whatever the interface language is.
    var sourceText: String {
        var source = self
        source.locale = Locale(identifier: "zh-Hans")
        return String(localized: source)
    }
}

@MainActor protocol SecretStore {
    func read(_ account: String) throws -> String
    func write(_ value: String, account: String) throws
    func remove(_ account: String) throws
}

@MainActor final class KeychainSecretStore: SecretStore {
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "local.chiyan.desktop-pet.model", kSecAttrAccount as String: account]
    }
    func read(_ account: String) throws -> String {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw SettingsError(localized: "无法读取钥匙串中的 API Key（OSStatus \(status)），请检查钥匙串访问权限。")
        }
        return value
    }
    func write(_ value: String, account: String) throws {
        var query = query(account)
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
            throw SettingsError(localized: "无法保存 API Key 到钥匙串。")
        }
    }
    func remove(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SettingsError(localized: "无法清除旧的钥匙串凭据。") }
    }
}

enum ModelProvider: String, Codable, CaseIterable, Sendable {
    case openAI, deepSeek, ollama, custom

    var title: String {
        switch self {
        case .openAI: "OpenAI"
        case .deepSeek: "DeepSeek"
        case .ollama: "Ollama"
        case .custom: String(localized: "自定义（兼容 API）")
        }
    }
    var requiresKey: Bool { self != .ollama }
    var defaults: ModelConfiguration {
        switch self {
        case .openAI: ModelConfiguration()
        case .deepSeek: ModelConfiguration(baseURL: "https://api.deepseek.com", model: "")
        case .ollama: ModelConfiguration(baseURL: "http://localhost:11434/v1", model: "")
        case .custom: ModelConfiguration(baseURL: "", model: "")
        }
    }
    static func infer(from configuration: ModelConfiguration) -> Self {
        let url = URLComponents(string: configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines))
        switch url?.host?.lowercased() {
        case "api.openai.com": return .openAI
        case "api.deepseek.com": return .deepSeek
        default:
            return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url?.host?.lowercased() ?? "") && url?.port == 11434 ? .ollama : .custom
        }
    }
}

struct ProviderSettings: Codable, Equatable {
    var model: ModelConfiguration
    var secretAccount: String?
}

struct SettingsSnapshot: Codable {
    var version = 2
    var activeProvider: ModelProvider = .openAI
    var providers: [String: ProviderSettings] = [ModelProvider.openAI.rawValue: ProviderSettings(model: ModelConfiguration())]
    var selectedPetID = "builtin:chiyan"
    /// Which planet visualizes Live Voice, in both the chat window and the pet's control strip.
    var selectedPlanetID = SettingsSnapshot.defaultPlanetID
    /// Declared here rather than on `PlanetStore`: the targets that build this file do not all
    /// build that one.
    static let defaultPlanetID = "builtin:ember-planet"
    var voice: VoiceConfiguration?
    var voiceSecretAccount: String?
    /// Every new turn goes to the local model, never the cloud.
    var localModelOnly = false

    var model: ModelConfiguration { settings(for: activeProvider).model }
    var secretAccount: String? { settings(for: activeProvider).secretAccount }
    func settings(for provider: ModelProvider) -> ProviderSettings {
        providers[provider.rawValue] ?? ProviderSettings(model: provider.defaults)
    }
    private enum CodingKeys: String, CodingKey {
        case version, activeProvider, providers, selectedPetID, selectedPlanetID, voice, voiceSecretAccount, localModelOnly
    }
    private enum LegacyKeys: String, CodingKey { case model, secretAccount }
    init() {}
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .version)
        guard version == 1 || version == 2 else { throw SettingsError(localized: "设置文件版本不受支持。") }
        selectedPetID = try values.decode(String.self, forKey: .selectedPetID)
        selectedPlanetID = try values.decodeIfPresent(String.self, forKey: .selectedPlanetID) ?? SettingsSnapshot.defaultPlanetID
        voice = try values.decodeIfPresent(VoiceConfiguration.self, forKey: .voice)
        voiceSecretAccount = try values.decodeIfPresent(String.self, forKey: .voiceSecretAccount)
        localModelOnly = try values.decodeIfPresent(Bool.self, forKey: .localModelOnly) ?? false
        if version == 1 {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            let model = try legacy.decode(ModelConfiguration.self, forKey: .model)
            activeProvider = ModelProvider.infer(from: model)
            // Adopt the existing Keychain reference; migration never copies or deletes a key.
            providers = [activeProvider.rawValue: ProviderSettings(model: model,
                secretAccount: try legacy.decodeIfPresent(String.self, forKey: .secretAccount))]
        } else {
            activeProvider = try values.decode(ModelProvider.self, forKey: .activeProvider)
            providers = try values.decode([String: ProviderSettings].self, forKey: .providers)
            guard providers[activeProvider.rawValue] != nil else { throw SettingsError(localized: "缺少当前 provider 配置。") }
        }
    }
}

/// A page of the settings window. Declaration order is the order the sidebar and its keyboard
/// traversal follow.
enum SettingsSection: String, CaseIterable, Hashable {
    /// Raw values only name the section in accessibility identifiers (`settings.section.模型`),
    /// which must not follow the interface language; what the sidebar shows is `title`.
    case model = "模型", voice = "语音", planet = "星球", pet = "精灵"
    var title: String {
        switch self {
        case .model: String(localized: "模型")
        case .voice: String(localized: "语音")
        case .planet: String(localized: "星球")
        case .pet: String(localized: "精灵")
        }
    }
}

protocol ConnectionTesting: Sendable {
    func test(configuration: ModelConfiguration, key: String) async throws
}

@MainActor final class SettingsStore: ObservableObject {
    @Published var voiceDraft = VoiceConfiguration()
    @Published var voiceAPIKey = ""
    @Published var voiceNotice: String?
    private var savedVoiceKey = ""
    private var voiceKeyLoaded = true
    var isVoiceDirty: Bool { voiceDraft != (snapshot.voice ?? VoiceConfiguration()) || voiceAPIKey != savedVoiceKey }
    @Published var selectedSection = SettingsSection.model
    @Published var presentationRevision = 0
    @Published private(set) var selectedProvider: ModelProvider = .openAI
    @Published var draft = ModelConfiguration() { didSet { invalidateTest() } }
    @Published var apiKey = "" { didSet { invalidateTest() } }
    @Published private(set) var snapshot = SettingsSnapshot()
    @Published var notice: String?
    @Published private(set) var testResult: String?
    @Published private(set) var testing = false
    @Published private(set) var testSucceeded = false
    /// The offline model, as its files show it; refreshed when the model settings appear.
    @Published private(set) var localModel: LocalModelAvailability = .missing
    /// The ready model's name from its metadata, read with `localModel`; nil when there is no usable one.
    @Published private(set) var localModelName: String?
    @Published private(set) var importingLocalModel = false
    @Published var localModelNotice: String?
    private let url: URL?
    private let secrets: any SecretStore
    private let tester: any ConnectionTesting
    private struct Credential {
        var key = ""
        var loaded = true
    }
    private struct ProviderDraft {
        var model: ModelConfiguration
        var key: String
    }
    private var credentials: [ModelProvider: Credential] = [:]
    private var providerDrafts: [ModelProvider: ProviderDraft] = [:]
    private var savedKey: String { credentials[snapshot.activeProvider]?.key ?? "" }
    private var keyLoaded: Bool { credentials[snapshot.activeProvider]?.loaded ?? true }
    private var selectedCredential: Credential { credentials[selectedProvider] ?? Credential() }
    private var task: Task<Void, Never>?
    private var revision = 0
    private var loadBlocked = false
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.chiyan.desktop-pet")
    }
    var isDirty: Bool {
        selectedProvider != snapshot.activeProvider || draft != snapshot.settings(for: selectedProvider).model
            || apiKey != selectedCredential.key
    }
    var canRestoreModel: Bool {
        isDirty || providerDrafts.contains { provider, value in
            value.model != snapshot.settings(for: provider).model || value.key != (credentials[provider]?.key ?? "")
        }
    }
    init(url: URL? = nil, secrets: any SecretStore = KeychainSecretStore(), tester: any ConnectionTesting = NativeConnectionTester()) {
        self.url = url; self.secrets = secrets; self.tester = tester
        if let url, FileManager.default.fileExists(atPath: url.path) {
            do {
                let decoded = try JSONDecoder().decode(SettingsSnapshot.self, from: Data(contentsOf: url))
                snapshot = decoded
            } catch {
                loadBlocked = true
                notice = String(localized: "设置文件无法读取，原文件保留。请修复或移走 settings.json 后重启应用。")
            }
        }
        selectedProvider = snapshot.activeProvider
        loadProvider(selectedProvider)
        voiceDraft = snapshot.voice ?? VoiceConfiguration()
        if let account = snapshot.voiceSecretAccount {
            do { savedVoiceKey = try secrets.read(account); voiceAPIKey = savedVoiceKey }
            catch { voiceKeyLoaded = false; voiceNotice = String(localized: "无法读取已保存的语音密钥，请检查钥匙串访问权限。") }
        }
    }
    private func loadProvider(_ provider: ModelProvider) {
        if credentials[provider] == nil {
            var credential = Credential()
            if provider.requiresKey, let account = snapshot.settings(for: provider).secretAccount {
                do { credential.key = try secrets.read(account) }
                catch { credential.loaded = false; notice = error.localizedDescription }
            }
            credentials[provider] = credential
        }
        if credentials[provider]?.loaded == false {
            notice = String(localized: "无法读取此 provider 的 API Key，请检查钥匙串权限或重新填写后保存。")
        }
        draft = providerDrafts[provider]?.model ?? snapshot.settings(for: provider).model
        apiKey = provider.requiresKey ? (providerDrafts[provider]?.key ?? selectedCredential.key) : ""
    }
    func selectProvider(_ provider: ModelProvider) {
        guard provider != selectedProvider else { return }
        providerDrafts[selectedProvider] = ProviderDraft(model: draft, key: apiKey)
        selectedProvider = provider
        notice = nil
        loadProvider(provider)
    }
    func savedVoiceCredentials() throws -> (configuration: VoiceConfiguration, key: String) {
        guard voiceKeyLoaded else { throw SettingsError(localized: "无法读取已保存的语音密钥，请检查钥匙串访问权限。") }
        let key = try resolvedVoiceKey(savedVoiceKey)
        VoiceDiagnostics.shared.record("1 API Key", "PASS", "来源=\(savedVoiceKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "已保存的模型密钥" : "语音专用密钥")；非空且格式有效，服务端鉴权待连接验证")
        return (try (snapshot.voice ?? VoiceConfiguration()).validated(), key)
    }
    // An empty override shares the saved model credential without duplicating it in Keychain.
    // Model form drafts must never silently change the credentials used by voice tests or calls.
    private func resolvedVoiceKey(_ override: String) throws -> String {
        let key: String
        if !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { key = override }
        else {
            guard keyLoaded else { throw SettingsError(localized: "无法读取共用的模型 API Key，请在模型设置中重新保存。") }
            key = savedKey
        }
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("\r"), !value.contains("\n") else {
            throw SettingsError(localized: "请在模型设置中保存可用于语音服务的 API Key。")
        }
        return value
    }
    func voiceTestKey() throws -> String { try resolvedVoiceKey(voiceAPIKey) }
    var canTestVoice: Bool { (try? voiceTestKey()) != nil }
    func restoreVoice() {
        voiceDraft = snapshot.voice ?? VoiceConfiguration(); voiceAPIKey = savedVoiceKey; voiceNotice = nil
    }
    func saveVoice() {
        do {
            let value = try voiceDraft.validated()
            let key = voiceAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.contains("\r"), !key.contains("\n") else { throw SettingsError(localized: "语音 API Key 不能包含换行。") }
            guard voiceKeyLoaded || !key.isEmpty else { throw SettingsError(localized: "原语音密钥尚未读取，请重新填写后保存。") }
            let changed = key != savedVoiceKey || !voiceKeyLoaded
            let oldAccount = snapshot.voiceSecretAccount
            var next = snapshot; next.voice = value
            if changed {
                next.voiceSecretAccount = key.isEmpty ? nil : "voice-\(UUID().uuidString)"
                if let account = next.voiceSecretAccount { try secrets.write(key, account: account) }
            }
            do { try persist(next) }
            catch {
                if changed, let account = next.voiceSecretAccount { try? secrets.remove(account) }
                throw error
            }
            snapshot = next; voiceDraft = value; savedVoiceKey = key; voiceAPIKey = key; voiceKeyLoaded = true
            voiceNotice = nil
            if changed, let oldAccount {
                do { try secrets.remove(oldAccount) }
                catch { voiceNotice = String(localized: "语音配置已保存，但旧密钥清理失败，请检查钥匙串。") }
            }
        } catch { voiceNotice = error is SettingsError ? error.localizedDescription : String(localized: "语音配置保存失败，请检查目录写入权限。") }
    }
    func refreshLocalModel() {
        localModel = LocalModelLocation.find()
        if case .ready(let url) = localModel {
            localModelName = LocalModelLocation.displayName(in: url) ?? url.lastPathComponent
        } else { localModelName = nil }
    }
    /// Copies a model folder the user picked into Echo's Models folder, checking it first.
    func importLocalModel(from source: URL) {
        guard !importingLocalModel else { return }
        importingLocalModel = true; localModelNotice = nil
        Task {
            let failure = await Task.detached {
                let access = source.startAccessingSecurityScopedResource()
                defer { if access { source.stopAccessingSecurityScopedResource() } }
                return LocalModelLocation.install(from: source)
            }.value
            importingLocalModel = false
            localModelNotice = failure ?? String(localized: "已导入本地模型。")
            refreshLocalModel()
        }
    }
    func savedModelCredentials() throws -> (configuration: ModelConfiguration, key: String) {
        guard !snapshot.model.model.isEmpty else { throw SettingsError.modelNotConfigured }
        guard keyLoaded else { throw SettingsError(localized: "无法读取已保存的 API Key，请在设置中重新填写并保存。") }
        guard !savedKey.contains("\n"), !savedKey.contains("\r") else { throw SettingsError(localized: "已保存的 API Key 无效，请重新设置。") }
        return (try snapshot.model.validated(), savedKey)
    }
    private func persist(_ value: SettingsSnapshot) throws {
        guard !loadBlocked else { throw SettingsError(localized: "设置文件无法读取，暂不能覆盖原文件。") }
        guard let url else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
    func save() {
        do {
            let value = try draft.validated(requiresModel: false)
            let key = selectedProvider.requiresKey ? apiKey : ""
            guard !key.contains("\n"), !key.contains("\r") else { throw SettingsError(localized: "API Key 不能包含换行。") }
            guard selectedCredential.loaded || !key.isEmpty else { throw SettingsError(localized: "原 API Key 尚未读取，请重新填写密钥后保存。") }
            var next = snapshot
            next.activeProvider = selectedProvider
            let oldAccount = snapshot.settings(for: selectedProvider).secretAccount
            let changedKey = key != selectedCredential.key || !selectedCredential.loaded
                || (!selectedProvider.requiresKey && oldAccount != nil)
            var entry = ProviderSettings(model: value, secretAccount: oldAccount)
            if changedKey {
                entry.secretAccount = key.isEmpty ? nil : "model-\(selectedProvider.rawValue)-\(UUID().uuidString)"
                if let account = entry.secretAccount { try secrets.write(key, account: account) }
            }
            next.providers[selectedProvider.rawValue] = entry
            do { try persist(next) }
            catch {
                if changedKey, let account = entry.secretAccount { try? secrets.remove(account) }
                throw error
            }
            snapshot = next; draft = value; apiKey = key
            credentials[selectedProvider] = Credential(key: key)
            providerDrafts[selectedProvider] = nil
            notice = nil
            if changedKey, let oldAccount {
                do { try secrets.remove(oldAccount) }
                catch { notice = String(localized: "配置已保存，但旧密钥清理失败，请检查钥匙串访问权限。") }
            }
        } catch { notice = error is SettingsError ? error.localizedDescription : String(localized: "保存失败，请检查设置目录的写入权限后重试。") }
    }
    /// Takes effect from the next turn; a reply being written keeps its model.
    func setLocalModelOnly(_ enabled: Bool) {
        guard enabled != snapshot.localModelOnly else { return }
        do { try update { $0.localModelOnly = enabled } }
        catch { localModelNotice = error is SettingsError ? error.localizedDescription : String(localized: "设置保存失败，请检查目录写入权限。") }
    }
    func selectPet(_ id: String) throws { try update { $0.selectedPetID = id } }
    func selectPlanet(_ id: String) throws { try update { $0.selectedPlanetID = id } }
    /// One saved preference: the published snapshot changes only once the file has it.
    private func update(_ change: (inout SettingsSnapshot) -> Void) throws {
        var next = snapshot; change(&next)
        try persist(next); snapshot = next
    }
    func restore() {
        providerDrafts.removeAll()
        selectedProvider = snapshot.activeProvider
        notice = nil
        loadProvider(selectedProvider)
    }
    private func invalidateTest() {
        revision += 1; task?.cancel(); task = nil; testing = false; testResult = nil; testSucceeded = false
    }
    func cancelTest() { invalidateTest(); testResult = String(localized: "测试已取消。") }
    func testConnection() {
        invalidateTest()
        do {
            let configuration = try draft.validated()
            guard !apiKey.contains("\r"), !apiKey.contains("\n") else { throw SettingsError(localized: "API Key 不能包含换行。") }
            let key = selectedProvider.requiresKey ? apiKey : ""; let current = revision; let tester = tester
            testing = true
            task = Task { [weak self] in
                var result: String; var success = false
                do { try await tester.test(configuration: configuration, key: key); result = String(localized: "连接成功，指定协议已返回有效的 bash 工具调用。"); success = true }
                catch is CancellationError { return }
                catch let error as SettingsError { result = error.message }
                catch let error as URLError where error.code == .timedOut { result = String(localized: "连接超时，请检查服务地址与网络后重试。") }
                catch { result = String(localized: "网络连接失败，请检查服务地址、证书和网络。") }
                guard let self, self.revision == current, !Task.isCancelled else { return }
                self.testing = false; self.testResult = result; self.testSucceeded = success; self.task = nil
            }
        } catch { testResult = error.localizedDescription }
    }
}
