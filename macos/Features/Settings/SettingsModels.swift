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

    func rootURL() throws -> URL {
        guard let parts = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.scheme == "https" || (parts.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host.lowercased())),
              let url = parts.url else { throw SettingsError(localized: "请输入 HTTPS API 根地址；本机服务可使用 HTTP。地址不能包含凭据、查询参数或片段。") }
        return url
    }
    func validated(requiresModel: Bool = true) throws -> Self {
        _ = try rootURL()
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
    /// Voice and chat with Volcengine Ark, and with it Doubao search, all wait for the one Volcengine Ark key.
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

/// Volcengine Ark's group on the model page. Its one key pays for voice and image generation, and
/// for chat and web_search while it chats, so it stands apart from the model service rather than
/// among its providers.
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
    var selectedPetID = SettingsSnapshot.defaultPetID
    /// Which planet visualizes Live Voice, in both the chat window and the pet's control strip.
    var selectedPlanetID = SettingsSnapshot.defaultPlanetID
    /// Declared here rather than on `PetCatalog` and `PlanetStore`: the targets that build this
    /// file do not all build those.
    static let defaultPetID = "builtin:chiyan"
    static let defaultPlanetID = "builtin:ember-planet"
    var voice: VoiceConfiguration?
    var ark = ArkSettings()
    /// The Volcengine Ark key: voice always uses it, and chat and Doubao search do when
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
