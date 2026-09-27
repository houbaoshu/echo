import Foundation
import FoundationModels
import FoundationModelsUtilities
import Synchronization

/// 远程模型配置。API key 只在内存里，永不打印、不写日志，也不会进入 bash 子进程环境（见 `ProcessRunner.baseEnvironment`）。
///
///     ark       ARK_API_KEY（必需）；ARK_BASE_URL / ARK_MODEL 可选，缺省读 Echo settings.json 中当前 provider 的非密钥字段
///               → 自写 `ArkResponsesLanguageModel`（从 FoundationModelsAgentProbe 原样复制）
///     deepseek  DEEPSEEK_BASE_URL / DEEPSEEK_MODEL / DEEPSEEK_API_KEY（全部必需，独立于 Echo provider 配置）
///               → Apple 官方 `ChatCompletionsLanguageModel`
///     deepseek-responses  同一组 DEEPSEEK_* 变量 → 原样复用的 `ArkResponsesLanguageModel`（Echo 的 DeepSeek provider 配置为 responses 协议）
///     WIRE_LOG  可选，JSONL 记录请求体与 SSE 原文（不含请求头）
public struct RemoteModelConfig: Sendable {
    public enum Backend: String, Sendable {
        case ark, deepseek
        case deepseekResponses = "deepseek-responses"
    }

    public var backend: Backend
    public var baseURL: URL
    public var model: String
    var apiKey: String

    public var redacted: String { "\(backend.rawValue) \(baseURL.absoluteString) model=\(model) key=<\(apiKey.count) chars>" }

    public struct ConfigError: LocalizedError {
        let message: String
        public var errorDescription: String? { message }
    }

    public static func load(_ backend: Backend, env: [String: String] = ProcessInfo.processInfo.environment) throws -> RemoteModelConfig {
        func value(_ key: String) -> String? { env[key].flatMap { $0.isEmpty ? nil : $0 } }
        switch backend {
        case .ark:
            guard let key = value("ARK_API_KEY") else { throw ConfigError(message: "ARK_API_KEY is not set") }
            var base = value("ARK_BASE_URL")
            var model = value("ARK_MODEL")
            if base == nil || model == nil {
                let echo = try echoActiveProvider()
                base = base ?? echo.baseURL
                model = model ?? echo.model
            }
            guard let base, let url = URL(string: base), let model else { throw ConfigError(message: "invalid Ark baseURL/model") }
            return RemoteModelConfig(backend: .ark, baseURL: url, model: model, apiKey: key)
        case .deepseek, .deepseekResponses:
            guard let base = value("DEEPSEEK_BASE_URL"), let url = URL(string: base),
                  let model = value("DEEPSEEK_MODEL"), let key = value("DEEPSEEK_API_KEY")
            else { throw ConfigError(message: "DEEPSEEK_BASE_URL / DEEPSEEK_MODEL / DEEPSEEK_API_KEY must all be set") }
            return RemoteModelConfig(backend: backend, baseURL: url, model: model, apiKey: key)
        }
    }

    /// 只读 Echo settings.json 中当前 provider 的 baseURL / model（非密钥），不读 Keychain、不写回。
    private static func echoActiveProvider() throws -> (baseURL: String, model: String) {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.chiyan.desktop-pet/settings.json")
        struct Settings: Decodable {
            struct Provider: Decodable {
                struct Model: Decodable { let baseURL: String; let model: String }
                let model: Model
            }
            let activeProvider: String
            let providers: [String: Provider]
        }
        let settings = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: url))
        guard let provider = settings.providers[settings.activeProvider] else {
            throw ConfigError(message: "Echo active provider \(settings.activeProvider) has no settings")
        }
        return (provider.model.baseURL, provider.model.model)
    }

    private func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 180
        if let path = ProcessInfo.processInfo.environment["WIRE_LOG"], !path.isEmpty {
            WireTap.install(into: configuration, path: path)
        }
        return configuration
    }

    /// 以闭包形式把具体模型类型交给调用方（两种 backend 的 `LanguageModel` 类型不同）。
    public func withModel<R>(_ body: (any LanguageModel) async throws -> R) async rethrows -> R {
        let headers = ["Authorization": "Bearer \(apiKey)"]
        switch backend {
        case .ark, .deepseekResponses:
            return try await body(ArkResponsesLanguageModel(
                name: model, url: baseURL, additionalHeaders: headers, urlSessionConfiguration: sessionConfiguration()
            ))
        case .deepseek:
            return try await body(ChatCompletionsLanguageModel(
                name: model, url: baseURL, additionalHeaders: headers,
                supportsGuidedGeneration: false, urlSessionConfiguration: sessionConfiguration()
            ))
        }
    }
}

// MARK: - Request recording

/// Foundation Models 每调用一次 executor（= 一次模型生成 = 一次 HTTP 请求）记录一条。
public final class RequestRecorder: Sendable, Hashable {
    public struct Request: Sendable {
        public var entryCount: Int
        public var at: ContinuousClock.Instant
        public var outcome: String?
    }

    private let requests = Mutex<[Request]>([])

    public init() {}

    func begin(_ request: LanguageModelExecutorGenerationRequest) -> Int {
        requests.withLock { $0.append(Request(entryCount: request.transcript.count, at: .now)); return $0.count - 1 }
    }

    func end(_ index: Int, _ outcome: String) { requests.withLock { $0[index].outcome = outcome } }

    public var all: [Request] { requests.withLock { $0 } }

    public static func == (lhs: RequestRecorder, rhs: RequestRecorder) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// 包一层任意 `LanguageModel`，不改变行为，只记录框架发起的每次生成请求。
public struct RecordingModel<Base: LanguageModel>: LanguageModel {
    public typealias Executor = RecordingExecutor<Base>

    public let base: Base
    public let recorder: RequestRecorder

    public init(_ base: Base, recorder: RequestRecorder) {
        self.base = base
        self.recorder = recorder
    }

    public var capabilities: LanguageModelCapabilities { base.capabilities }
    public var executorConfiguration: RecordingExecutor<Base>.Configuration {
        .init(base: base.executorConfiguration, recorder: recorder)
    }
}

public struct RecordingExecutor<Base: LanguageModel>: LanguageModelExecutor {
    public typealias Model = RecordingModel<Base>

    public struct Configuration: Hashable, Sendable {
        let base: Base.Executor.Configuration
        let recorder: RequestRecorder
    }

    let base: Base.Executor
    let recorder: RequestRecorder

    public init(configuration: Configuration) throws {
        base = try Base.Executor(configuration: configuration.base)
        recorder = configuration.recorder
    }

    public func prewarm(model: RecordingModel<Base>, transcript: Transcript) {
        base.prewarm(model: model.base, transcript: transcript)
    }

    nonisolated(nonsending) public func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: RecordingModel<Base>,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        let index = recorder.begin(request)
        do {
            try await base.respond(to: request, model: model.base, streamingInto: channel)
            recorder.end(index, "ok")
        } catch {
            recorder.end(index, "threw \(type(of: error))")
            throw error
        }
    }
}
