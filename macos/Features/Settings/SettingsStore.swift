import Foundation
import Observation
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
    /// Voice, web_search and chat with Volcengine Ark all wait for the one Volcengine Ark key.
    static let arkKeyMissing = SettingsError(localized: "请在设置的模型页填写并保存火山方舟的 API Key。")
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
         kSecAttrService as String: "io.github.houbaoshu.echo.model", kSecAttrAccount as String: account]
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

/// The model service: a provider that only chats. Volcengine Ark is not one of them; it has a
/// group of its own (`ArkSettings`). Declaration order is the picker's order.
enum ModelProvider: String, Codable, CaseIterable, Sendable {
    case deepSeek, openAI, ollama, custom

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
}

/// Volcengine Ark's group on the model page. Its one key pays for chat, voice, web_search and
/// image generation, so it stands apart from the model service rather than among its providers.
/// The address and protocol are the Agent Plan's and are not shown.
struct ArkSettings: Codable, Equatable, Sendable {
    static let defaultLanguageModel = "doubao-seed-2.0-mini"
    static let defaultVisionModel = "doubao-seedream-5.0-pro"
    /// The Agent Plan's OpenAI-compatible address.
    static let baseURL = "https://ark.cn-beijing.volces.com/api/plan/v3"
    var languageModel = ArkSettings.defaultLanguageModel
    var visionModel = ArkSettings.defaultVisionModel
    /// Chat goes to Volcengine Ark, with its key and language model, instead of to the model service.
    var useForChat = false

    var chatConfiguration: ModelConfiguration {
        ModelConfiguration(baseURL: Self.baseURL, model: languageModel, apiProtocol: .responses)
    }
    func validated() throws -> Self {
        var result = self
        result.languageModel = languageModel.trimmingCharacters(in: .whitespacesAndNewlines)
        result.visionModel = visionModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !useForChat || !result.languageModel.isEmpty else { throw SettingsError(localized: "请输入火山方舟的语言模型。") }
        return result
    }
    init() {}
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        languageModel = try values.decodeIfPresent(String.self, forKey: .languageModel) ?? Self.defaultLanguageModel
        visionModel = try values.decodeIfPresent(String.self, forKey: .visionModel) ?? Self.defaultVisionModel
        useForChat = try values.decodeIfPresent(Bool.self, forKey: .useForChat) ?? false
    }
}

struct ProviderSettings: Codable, Equatable {
    var model: ModelConfiguration
    var secretAccount: String?
}

struct SettingsSnapshot: Codable {
    var version = 2
    /// A new install starts on DeepSeek, the first provider in the picker.
    var activeProvider: ModelProvider = .deepSeek
    var providers: [String: ProviderSettings] = [ModelProvider.deepSeek.rawValue: ProviderSettings(model: ModelProvider.deepSeek.defaults)]
    var selectedPetID = "builtin:chiyan"
    /// Which planet visualizes Live Voice, in both the chat window and the pet's control strip.
    var selectedPlanetID = SettingsSnapshot.defaultPlanetID
    /// Declared here rather than on `PlanetStore`: the targets that build this file do not all
    /// build that one.
    static let defaultPlanetID = "builtin:ember-planet"
    var voice: VoiceConfiguration?
    var ark = ArkSettings()
    /// The Volcengine Ark key: voice and web_search always use it, and chat does when
    /// `ark.useForChat` is on.
    var arkSecretAccount: String?
    /// The keys voice and Volcengine Ark chat kept before the Volcengine Ark group took their
    /// place. Read only so launch can remove them; once removed they are nil and not written.
    var legacyVoiceSecretAccount: String?
    var legacyArkSecretAccount: String?
    /// Every new turn goes to the local model, never the cloud.
    var localModelOnly = false
    /// Turns get the memory and its tools. Off leaves the memory file as it is.
    var memoryEnabled = true

    var model: ModelConfiguration { settings(for: activeProvider).model }
    var secretAccount: String? { settings(for: activeProvider).secretAccount }
    func settings(for provider: ModelProvider) -> ProviderSettings {
        providers[provider.rawValue] ?? ProviderSettings(model: provider.defaults)
    }
    private enum CodingKeys: String, CodingKey {
        case version, activeProvider, providers, selectedPetID, selectedPlanetID, voice, ark, arkSecretAccount, localModelOnly, memoryEnabled
        case legacyVoiceSecretAccount = "voiceSecretAccount", legacyArkSecretAccount
    }
    /// What Volcengine Ark was called when it was one of the model service's providers.
    private static let formerArkProvider = "volcengineArk"
    /// Any version but this build's own, including the first, which kept one model and no provider.
    static let unsupportedVersion = SettingsError(localized: "设置文件版本不受支持，原文件保留。请移走 settings.json 后重启应用。")
    init() {}
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .version) == 2 else { throw Self.unsupportedVersion }
        selectedPetID = try values.decode(String.self, forKey: .selectedPetID)
        selectedPlanetID = try values.decodeIfPresent(String.self, forKey: .selectedPlanetID) ?? SettingsSnapshot.defaultPlanetID
        voice = try values.decodeIfPresent(VoiceConfiguration.self, forKey: .voice)
        arkSecretAccount = try values.decodeIfPresent(String.self, forKey: .arkSecretAccount)
        legacyVoiceSecretAccount = try values.decodeIfPresent(String.self, forKey: .legacyVoiceSecretAccount)
        legacyArkSecretAccount = try values.decodeIfPresent(String.self, forKey: .legacyArkSecretAccount)
        ark = try values.decodeIfPresent(ArkSettings.self, forKey: .ark) ?? ArkSettings()
        localModelOnly = try values.decodeIfPresent(Bool.self, forKey: .localModelOnly) ?? false
        memoryEnabled = try values.decodeIfPresent(Bool.self, forKey: .memoryEnabled) ?? true
        let active = try values.decode(String.self, forKey: .activeProvider)
        providers = try values.decode([String: ProviderSettings].self, forKey: .providers)
        // Volcengine Ark used to be a provider. Chosen, it becomes the switch turned on, its default
        // model the group's language model, and the model service the first provider set up; its key's
        // name is kept only for launch to remove the key.
        if let former = providers.removeValue(forKey: Self.formerArkProvider) {
            legacyArkSecretAccount = legacyArkSecretAccount ?? former.secretAccount
            if active == Self.formerArkProvider {
                ark.useForChat = true
                if !former.model.model.isEmpty { ark.languageModel = former.model.model }
            }
        }
        if active == Self.formerArkProvider {
            activeProvider = ModelProvider.allCases.first { providers[$0.rawValue] != nil } ?? .deepSeek
            if providers[activeProvider.rawValue] == nil { providers[activeProvider.rawValue] = ProviderSettings(model: activeProvider.defaults) }
        } else if let provider = ModelProvider(rawValue: active) {
            activeProvider = provider
        } else {
            throw SettingsError(localized: "缺少当前 provider 配置。")
        }
        guard providers[activeProvider.rawValue] != nil else { throw SettingsError(localized: "缺少当前 provider 配置。") }
    }
}

/// A page of the settings window. Declaration order is the order the sidebar and its keyboard
/// traversal follow.
enum SettingsSection: String, CaseIterable, Hashable {
    /// Raw values only name the section in accessibility identifiers (`settings.section.模型`),
    /// which must not follow the interface language; what the sidebar shows is `title`.
    case model = "模型", memory = "记忆", voice = "语音", planet = "星球", pet = "精灵"
    var title: String {
        switch self {
        case .model: String(localized: "模型")
        case .memory: String(localized: "记忆")
        case .voice: String(localized: "语音")
        case .planet: String(localized: "星球")
        case .pet: String(localized: "精灵")
        }
    }
}

protocol ConnectionTesting: Sendable {
    func test(configuration: ModelConfiguration, key: String) async throws
}

/// Checks the Volcengine Ark key; a SettingsError carries what to show.
protocol ArkConnectionTesting: Sendable {
    func test(key: String) async throws
}

/// A group's one-line report below its box: a finished test, or why the group could not be saved.
struct SettingsTestLine: Equatable {
    let text: String
    let succeeded: Bool
}

@MainActor @Observable final class SettingsStore {
    var voiceDraft = VoiceConfiguration()
    var voiceNotice: String?
    var isVoiceDirty: Bool { voiceDraft != (snapshot.voice ?? VoiceConfiguration()) }
    /// The Volcengine Ark group's key, as edited. Emptying it turns "use for chat" off.
    var arkAPIKey = "" {
        didSet {
            if arkDraft.useForChat && !canUseArkForChat { arkDraft.useForChat = false }
            invalidateArkTest()
        }
    }
    /// The rest of the Volcengine Ark group, as edited. "Use for chat" stays off without a key.
    var arkDraft = ArkSettings() {
        didSet {
            if arkDraft.useForChat && !canUseArkForChat { arkDraft.useForChat = false }
            invalidateArkTest()
        }
    }
    var arkNotice: String?
    private var savedArkKeyValue = ""
    private var arkKeyLoaded = true
    var isArkDirty: Bool { arkAPIKey != savedArkKeyValue || arkDraft != snapshot.ark }
    /// What the Volcengine Ark group reports below its box: why it could not be saved, or its test.
    var arkStatus: SettingsTestLine? { arkNotice.map { SettingsTestLine(text: $0, succeeded: false) } ?? arkTestResult }
    /// Whether "use for chat" can be on: only with a Volcengine Ark key typed in.
    var canUseArkForChat: Bool { !arkAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// The Volcengine Ark group's test: one search with the key as typed, and the language model's
    /// tool calling when one is filled in, as one line.
    private(set) var arkTestResult: SettingsTestLine?
    private(set) var arkTesting = false
    @ObservationIgnored private var arkTask: Task<Void, Never>?
    @ObservationIgnored private var arkRevision = 0
    var selectedSection = SettingsSection.model
    var presentationRevision = 0
    private(set) var selectedProvider: ModelProvider = .deepSeek
    var draft = ModelConfiguration() { didSet { invalidateTest() } }
    var apiKey = "" { didSet { invalidateTest() } }
    private(set) var snapshot = SettingsSnapshot()
    var notice: String?
    /// The model service's test: chat and tool calling with the group as typed.
    private(set) var testResult: SettingsTestLine?
    /// What the model service group reports below its box: why it could not be saved, or its test.
    var modelServiceStatus: SettingsTestLine? { notice.map { SettingsTestLine(text: $0, succeeded: false) } ?? testResult }
    private(set) var testing = false
    /// The offline model, as its files show it; refreshed when the model settings appear.
    private(set) var localModel: LocalModelAvailability = .missing
    /// The ready model's name from its metadata, read with `localModel`; nil when there is no usable one.
    private(set) var localModelName: String?
    private(set) var importingLocalModel = false
    var localModelNotice: String?
    private let url: URL?
    /// What the person asked the Agent to remember, beside settings.json; nil when the store is off disk.
    var memoryFile: AgentMemoryFile? { url.map { AgentMemoryFile(folder: $0.deletingLastPathComponent()) } }
    /// Why the memory file could not be opened or cleared, or the switch saved, beneath the buttons.
    var memoryNotice: String?
    /// The memory as the memory page last read it; nil when it holds nothing.
    private(set) var memoryContents: MemoryContents?
    struct MemoryContents: Equatable {
        let modified: Date?
        let lines: [AgentMemoryLine]
    }
    /// Where clearing the memory moves its file.
    private let trash: AgentTrash
    /// Where the offline model is imported and looked for. Like `url`, nil keeps the store off
    /// disk: there is no model.
    let localModels: LocalModelLocation?
    private let secrets: any SecretStore
    private let tester: any ConnectionTesting
    private let arkTester: any ArkConnectionTesting
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
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var revision = 0
    private var loadBlocked = false
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("io.github.houbaoshu.echo")
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
    init(url: URL? = nil, localModels: LocalModelLocation? = nil, secrets: any SecretStore = KeychainSecretStore(),
         tester: any ConnectionTesting = NativeConnectionTester(),
         arkTester: any ArkConnectionTesting = DoubaoSearchTester(), trash: AgentTrash = .system) {
        self.url = url; self.localModels = localModels; self.secrets = secrets; self.tester = tester
        self.arkTester = arkTester; self.trash = trash
        if let url, FileManager.default.fileExists(atPath: url.path) {
            do {
                let decoded = try JSONDecoder().decode(SettingsSnapshot.self, from: Data(contentsOf: url))
                snapshot = decoded
            } catch let error as SettingsError where error == SettingsSnapshot.unsupportedVersion {
                loadBlocked = true
                notice = error.message
            } catch {
                loadBlocked = true
                notice = String(localized: "设置文件无法读取，原文件保留。请修复或移走 settings.json 后重启应用。")
            }
        }
        removeReplacedKeys()
        // Without a key the switch cannot be on, a setting carried over from a provider included.
        if snapshot.arkSecretAccount == nil { snapshot.ark.useForChat = false }
        selectedProvider = snapshot.activeProvider
        loadProvider(selectedProvider)
        voiceDraft = snapshot.voice ?? VoiceConfiguration()
        if let account = snapshot.arkSecretAccount {
            do { savedArkKeyValue = try secrets.read(account); arkAPIKey = savedArkKeyValue }
            catch { arkKeyLoaded = false; arkNotice = String(localized: "无法读取已保存的火山方舟 API Key，请检查钥匙串访问权限。") }
        }
        arkDraft = snapshot.ark
    }
    /// Voice's own key and Volcengine Ark's own model key, from before the Volcengine Ark group,
    /// are never read: launch removes them from the keychain and their names from settings.json.
    /// A name whose key could not be removed stays, to be tried again at the next launch.
    private func removeReplacedKeys() {
        guard !loadBlocked else { return }
        var next = snapshot
        if let account = next.legacyVoiceSecretAccount, (try? secrets.remove(account)) != nil {
            next.legacyVoiceSecretAccount = nil
        }
        if let account = next.legacyArkSecretAccount, (try? secrets.remove(account)) != nil {
            next.legacyArkSecretAccount = nil
        }
        guard next.legacyVoiceSecretAccount != snapshot.legacyVoiceSecretAccount
                || next.legacyArkSecretAccount != snapshot.legacyArkSecretAccount else { return }
        do { try persist(next); snapshot = next } catch {}
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
        let key = try savedArkCredential()
        VoiceDiagnostics.shared.record("1 API Key", "PASS", "非空且格式有效，服务端鉴权待连接验证")
        return (try (snapshot.voice ?? VoiceConfiguration()).validated(), key)
    }
    /// Voice tests what voice will use: the saved Volcengine Ark key, not one still being typed.
    func voiceTestKey() throws -> String { try savedArkCredential() }
    var canTestVoice: Bool { savedArkKey != nil }
    /// Saves the voice ID when it was edited: the voice page has no save button, so Return and
    /// leaving the field both come here.
    func commitVoice() { if isVoiceDirty { saveVoice() } }
    func saveVoice() {
        do {
            let value = try voiceDraft.validated()
            var next = snapshot; next.voice = value
            try persist(next)
            snapshot = next; voiceDraft = value
            voiceNotice = nil
        } catch { voiceNotice = error is SettingsError ? error.localizedDescription : String(localized: "语音配置保存失败，请检查目录写入权限。") }
    }
    /// The saved Volcengine Ark key, trimmed; nil when there is none or it cannot be read. Voice,
    /// web_search and chat with Volcengine Ark use this key whichever provider chats, and no other
    /// key ever stands in for it.
    var savedArkKey: String? {
        let key = savedArkKeyValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard arkKeyLoaded, !key.isEmpty, !key.contains("\r"), !key.contains("\n") else { return nil }
        return key
    }
    private func savedArkCredential() throws -> String {
        guard arkKeyLoaded else { throw SettingsError(localized: "无法读取已保存的火山方舟 API Key，请检查钥匙串访问权限。") }
        guard let key = savedArkKey else { throw SettingsError.arkKeyMissing }
        return key
    }
    func restoreArk() { arkAPIKey = savedArkKeyValue; arkDraft = snapshot.ark; arkNotice = nil }
    func saveArk() {
        do {
            var value = try arkDraft.validated()
            let key = arkAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.contains("\r"), !key.contains("\n") else { throw SettingsError(localized: "API Key 不能包含换行。") }
            guard arkKeyLoaded || !key.isEmpty else { throw SettingsError(localized: "原 API Key 尚未读取，请重新填写密钥后保存。") }
            let changed = key != savedArkKeyValue || !arkKeyLoaded
            let oldAccount = snapshot.arkSecretAccount
            // The first key saved while the model service has none of its own turns Volcengine Ark
            // chat on, once; from then on the switch is the person's.
            if snapshot.arkSecretAccount == nil, !key.isEmpty, selectedProvider.requiresKey,
               apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { value.useForChat = true }
            var next = snapshot; next.ark = value
            if changed {
                next.arkSecretAccount = key.isEmpty ? nil : "ark-\(UUID().uuidString)"
                if let account = next.arkSecretAccount { try secrets.write(key, account: account) }
            }
            do { try persist(next) }
            catch {
                if changed, let account = next.arkSecretAccount { try? secrets.remove(account) }
                throw error
            }
            snapshot = next; savedArkKeyValue = key; arkAPIKey = key; arkKeyLoaded = true; arkDraft = value
            arkNotice = nil
            if changed, let oldAccount {
                do { try secrets.remove(oldAccount) }
                catch { arkNotice = String(localized: "配置已保存，但旧密钥清理失败，请检查钥匙串访问权限。") }
            }
        } catch { arkNotice = error is SettingsError ? error.localizedDescription : String(localized: "保存失败，请检查设置目录的写入权限后重试。") }
    }
    func refreshLocalModel() {
        localModel = localModels?.find() ?? .missing
        if case .ready(let url) = localModel {
            localModelName = LocalModelLocation.displayName(in: url) ?? url.lastPathComponent
        } else { localModelName = nil }
    }
    /// Copies a model folder the user picked into Echo's Models folder, checking it first.
    func importLocalModel(from source: URL) {
        guard !importingLocalModel, let localModels else { return }
        importingLocalModel = true; localModelNotice = nil
        Task {
            let failure = await Task.detached {
                let access = source.startAccessingSecurityScopedResource()
                defer { if access { source.stopAccessingSecurityScopedResource() } }
                return localModels.install(from: source)
            }.value
            importingLocalModel = false
            localModelNotice = failure ?? String(localized: "已导入本地模型。")
            refreshLocalModel()
        }
    }
    /// The memory file to open in the person's editor, created empty when there is none. Nil when
    /// it cannot be, with `memoryNotice` saying why.
    func memoryFileForEditing() -> URL? {
        guard let memoryFile else { return nil }
        do {
            let url = try memoryFile.prepareForEditing()
            memoryNotice = nil
            return url
        } catch {
            memoryNotice = String(localized: "无法创建记忆文件：\(error.localizedDescription)")
            return nil
        }
    }
    /// Reads the memory again, as the Agent's next turn would get it.
    func reloadMemory() {
        guard let memoryFile, let text = memoryFile.read() else { memoryContents = nil; return }
        let lines = AgentMemoryLine.lines(of: text)
        memoryContents = lines.isEmpty ? nil : MemoryContents(modified: memoryFile.modified(), lines: lines)
    }
    /// Moves the memory file to the Trash, so Put Back restores it.
    func clearMemory() {
        guard let memoryFile else { return }
        do {
            try trash.move(memoryFile.url)
            memoryNotice = nil
        } catch {
            memoryNotice = String(localized: "无法清空记忆：\(error.localizedDescription)")
        }
        reloadMemory()
    }
    func savedModelCredentials() throws -> (configuration: ModelConfiguration, key: String) {
        if snapshot.ark.useForChat {
            guard !snapshot.ark.languageModel.isEmpty else { throw SettingsError.modelNotConfigured }
            return (try snapshot.ark.chatConfiguration.validated(), try savedArkCredential())
        }
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
    /// Takes effect from the next turn; a reply being written keeps the memory it started with.
    func setMemoryEnabled(_ enabled: Bool) {
        guard enabled != snapshot.memoryEnabled else { return }
        do { try update { $0.memoryEnabled = enabled } }
        catch { memoryNotice = error is SettingsError ? error.localizedDescription : String(localized: "设置保存失败，请检查目录写入权限。") }
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
        revision += 1; task?.cancel(); task = nil; testing = false; testResult = nil
    }
    private func invalidateArkTest() {
        arkRevision += 1; arkTask?.cancel(); arkTask = nil; arkTesting = false; arkTestResult = nil
    }
    private static let cancelled = SettingsTestLine(text: String(localized: "测试已取消。"), succeeded: false)
    /// Stops whichever tests are running; a group whose test was not running keeps what it showed.
    func cancelTest() {
        if testing { cancelModelServiceTest() }
        if arkTesting { cancelArkTest() }
    }
    func cancelModelServiceTest() { invalidateTest(); testResult = Self.cancelled }
    func cancelArkTest() { invalidateArkTest(); arkTestResult = Self.cancelled }
    /// The model service's own test needs its key, unless the provider takes none.
    var canTestModelService: Bool {
        !selectedProvider.requiresKey || !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var canTestArk: Bool { canUseArkForChat }
    /// Tests the model service as typed, saved or not: one request that must call a tool. Its result
    /// takes the place of whatever the group last said.
    func testConnection() {
        invalidateTest(); notice = nil
        let configuration: ModelConfiguration, key: String
        do {
            configuration = try draft.validated()
            key = selectedProvider.requiresKey ? apiKey : ""
            guard !key.contains("\r"), !key.contains("\n") else { throw SettingsError(localized: "API Key 不能包含换行。") }
        } catch { testResult = SettingsTestLine(text: error.localizedDescription, succeeded: false); return }
        let current = revision, tester = tester
        testing = true
        task = Task { [weak self] in
            let line = await Self.testChat(tester, (configuration, key))
            guard let self, self.revision == current, !Task.isCancelled else { return }
            self.testing = false; self.testResult = line; self.task = nil
        }
    }
    /// Tests the Volcengine Ark group as typed, saved or not: one web search with the key, and the
    /// language model's tool calling when one is filled in, whether or not the switch is on.
    func testArk() {
        invalidateArkTest(); arkNotice = nil
        let key = arkAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        guard !key.contains("\r"), !key.contains("\n") else {
            arkTestResult = SettingsTestLine(text: String(localized: "API Key 不能包含换行。"), succeeded: false); return
        }
        let model = arkDraft.languageModel.trimmingCharacters(in: .whitespacesAndNewlines)
        var chat = arkDraft; chat.languageModel = model
        let request = model.isEmpty ? nil : (configuration: chat.chatConfiguration, key: key)
        let current = arkRevision, tester = tester, arkTester = arkTester
        arkTesting = true
        arkTask = Task { [weak self] in
            async let searchLine = Self.testSearch(arkTester, key: key)
            async let chatLine = Self.testChat(tester, request)
            let line = Self.arkLine(search: await searchLine, chat: await chatLine)
            guard let self, self.arkRevision == current, !Task.isCancelled else { return }
            self.arkTesting = false; self.arkTestResult = line; self.arkTask = nil
        }
    }
    /// The two checks as one line: one sentence when both pass, otherwise only what failed.
    private nonisolated static func arkLine(search: SettingsTestLine, chat: SettingsTestLine?) -> SettingsTestLine {
        guard let chat else { return search }
        let chatFailure = String(localized: "语言模型：\(chat.text)")
        switch (search.succeeded, chat.succeeded) {
        case (true, true): return SettingsTestLine(text: String(localized: "连接成功，联网搜索和工具调用均正常。"), succeeded: true)
        case (true, false): return SettingsTestLine(text: chatFailure, succeeded: false)
        case (false, true): return search
        case (false, false): return SettingsTestLine(text: "\(search.text) \(chatFailure)", succeeded: false)
        }
    }
    private nonisolated static func testChat(_ tester: any ConnectionTesting,
                                             _ request: (configuration: ModelConfiguration, key: String)?) async -> SettingsTestLine? {
        guard let request else { return nil }
        do {
            try await tester.test(configuration: request.configuration, key: request.key)
            return SettingsTestLine(text: String(localized: "连接成功，指定协议已返回有效的工具调用。"), succeeded: true)
        }
        catch let error as SettingsError { return SettingsTestLine(text: error.message, succeeded: false) }
        catch let error as URLError where error.code == .timedOut { return SettingsTestLine(text: String(localized: "连接超时，请检查服务地址与网络后重试。"), succeeded: false) }
        catch { return SettingsTestLine(text: String(localized: "网络连接失败，请检查服务地址、证书和网络。"), succeeded: false) }
    }
    private nonisolated static func testSearch(_ tester: any ArkConnectionTesting, key: String) async -> SettingsTestLine {
        do {
            try await tester.test(key: key)
            return SettingsTestLine(text: String(localized: "连接成功，联网搜索已返回结果。"), succeeded: true)
        }
        catch let error as SettingsError { return SettingsTestLine(text: error.message, succeeded: false) }
        catch { return SettingsTestLine(text: String(localized: "无法连接豆包搜索：\(error.localizedDescription)"), succeeded: false) }
    }
}
