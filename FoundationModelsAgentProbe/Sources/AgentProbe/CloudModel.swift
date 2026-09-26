import Foundation
import FoundationModels
import FoundationModelsUtilities
import Security

/// 云模型配置，只从环境变量读取；API key 永不打印。
///
///     ARK_BASE_URL  例如火山方舟 OpenAI 兼容地址（需含 /v3 等版本段，适配器只追加 /chat/completions）
///     ARK_MODEL     模型名 / Endpoint ID，原样放进请求的 model 字段
///     ARK_API_KEY   Bearer token
public struct CloudConfig: Sendable {
    public var baseURL: URL
    public var model: String
    var apiKey: String

    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> CloudConfig? {
        guard let base = env["ARK_BASE_URL"], let url = URL(string: base),
              let model = env["ARK_MODEL"], !model.isEmpty,
              let key = env["ARK_API_KEY"], !key.isEmpty
        else { return nil }
        return CloudConfig(baseURL: url, model: model, apiKey: key)
    }

    /// 从 Echo 自己的配置读取：`settings.json` 中当前 provider 的 baseURL / model，
    /// API key 从 Echo 的 Keychain 项（service `local.chiyan.desktop-pet.model`，account = secretAccount）读取。
    /// 只读，不写回任何 Echo 状态。环境变量 ARK_BASE_URL / ARK_MODEL / ARK_API_KEY 若存在则覆盖对应字段。
    public static func fromEchoSettings(_ env: [String: String] = ProcessInfo.processInfo.environment) throws -> (CloudConfig, apiProtocol: String) {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.chiyan.desktop-pet/settings.json")
        struct Settings: Decodable {
            struct Provider: Decodable {
                struct Model: Decodable { let baseURL: String; let model: String; let apiProtocol: String? }
                let model: Model
                let secretAccount: String?
            }
            let activeProvider: String
            let providers: [String: Provider]
        }
        let settings = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: url))
        guard let provider = settings.providers[settings.activeProvider] else {
            throw EchoSettingsError("active provider \(settings.activeProvider) has no settings")
        }
        let base = env["ARK_BASE_URL"] ?? provider.model.baseURL
        guard let baseURL = URL(string: base) else { throw EchoSettingsError("invalid baseURL") }
        let key: String
        if let override = env["ARK_API_KEY"], !override.isEmpty {
            key = override
        } else {
            guard let account = provider.secretAccount else { throw EchoSettingsError("provider has no secretAccount") }
            key = try readKeychain(service: "local.chiyan.desktop-pet.model", account: account)
        }
        return (CloudConfig(baseURL: baseURL, model: env["ARK_MODEL"] ?? provider.model.model, apiKey: key),
                provider.model.apiProtocol ?? "chatCompletions")
    }

    private static func readKeychain(service: String, account: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw EchoSettingsError("Keychain read failed (OSStatus \(status))")
        }
        return value
    }

    /// 可安全打印的描述（不含 key）。
    public var redacted: String { "\(baseURL.absoluteString) model=\(model) key=<\(apiKey.count) chars>" }

    /// 直接使用 Apple 官方 `ChatCompletionsLanguageModel`，不自写 executor、不自写 agent loop。
    public func makeModel() -> ChatCompletionsLanguageModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        if let path = ProcessInfo.processInfo.environment["ARK_WIRE_LOG"], !path.isEmpty {
            WireTap.install(into: configuration, path: path)
        }
        return ChatCompletionsLanguageModel(
            name: model,
            url: baseURL,
            additionalHeaders: ["Authorization": "Bearer \(apiKey)"],
            supportsGuidedGeneration: false,
            urlSessionConfiguration: configuration
        )
    }

    /// 自写的最小 Responses adapter，同样挂 WireTap 旁路。
    public func makeResponsesModel() -> ArkResponsesLanguageModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        if let path = ProcessInfo.processInfo.environment["ARK_WIRE_LOG"], !path.isEmpty {
            WireTap.install(into: configuration, path: path)
        }
        return ArkResponsesLanguageModel(
            name: model, url: baseURL,
            additionalHeaders: ["Authorization": "Bearer \(apiKey)"],
            urlSessionConfiguration: configuration
        )
    }
}

public struct EchoSettingsError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
