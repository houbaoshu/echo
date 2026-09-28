import Foundation
import FoundationModels

/// Uses the production Rust model adapter and parser. A fresh session has no
/// directory. Checkpoints live only for this disposable probe; tools are never authorized.
struct ModelConnectionTester: ConnectionTesting {
    var resources: URL? = Bundle.main.resourceURL

    @MainActor func test(configuration: ModelConfiguration, key: String) async throws {
        let configuration = try configuration.validated()
        guard !key.contains("\r"), !key.contains("\n") else { throw SettingsError("API Key 不能包含换行。") }
        try Task.checkCancellation()
        let bridge = try AgentBridge(sessionID: UUID().uuidString, model: AgentModel(configuration, key: key),
                                     resources: resources)
        defer { bridge.cancel(); bridge.close() }
        var result: Result<Void, Error>?
        bridge.onFailure = { _ in result = .failure(SettingsError("Agent 连接测试失败，请检查应用资源与模型配置。")) }
        bridge.onClosed = {
            if result == nil { result = .failure(SettingsError("Agent 连接测试意外结束。")) }
        }
        bridge.onBatch = { [weak bridge] batch in
            guard let bridge, result == nil else { return }
            do {
                if let cp = batch.checkpoint { try bridge.send(.acknowledgeCheckpoint(cp.id)) }
                if batch.kind.type == .ready {
                    try bridge.send(.sendMessage(AgentInput(client_message_id: UUID().uuidString, text:
                        "This is a tool capability test. Return exactly one bash tool call with command: printf 'ECHO_TOOL_PROBE'. Do not answer with text. The host will inspect the call without executing it.")))
                }
            } catch { result = .failure(error); return }
            if batch.error != nil {
                // Provider errors can contain arbitrary response bodies; do not
                // show them or accidentally echo credentials in a settings probe.
                result = .failure(SettingsError("模型请求失败，请检查服务地址、密钥、模型及 \(configuration.apiProtocol.title) 工具调用支持。"))
                return
            }
            for event in batch.events {
                switch event.kind.type {
                case .directory_required: result = .success(())
                case .finished:
                    result = .failure(SettingsError("未收到有效的 bash 工具调用，请检查模型、额度及 \(configuration.apiProtocol.title) 工具调用支持。"))
                default: break
                }
            }
        }
        bridge.startPolling()
        let deadline = ContinuousClock.now.advanced(by: .seconds(65))
        while result == nil {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw SettingsError("Agent 工具调用测试超时。") }
            try await Task.sleep(for: .milliseconds(25))
        }
        try Task.checkCancellation()
        try result!.get()
    }
}

/// The native engine's connection test: Echo's own adapter, one required call to a probe tool
/// with bash's name and schema. The call itself is the result; the probe never runs anything.
struct NativeConnectionTester: ConnectionTesting {
    var transport: (@Sendable (AgentEndpoint) -> AgentTransport)?

    @MainActor func test(configuration: ModelConfiguration, key: String) async throws {
        let configuration = try configuration.validated()
        guard !key.contains("\r"), !key.contains("\n") else { throw SettingsError("API Key 不能包含换行。") }
        try Task.checkCancellation()
        let endpoint = AgentEndpoint(configuration, key: key)
        let model = EchoLanguageModel(endpoint: endpoint, transport: transport?(endpoint) ?? AgentTransport.make(for: endpoint),
                                      ledger: GenerationLedger(), budget: GenerationBudget(limit: 1))
        let session = LanguageModelSession(profile: ProbeProfile(model: model), history: [])
        let title = configuration.apiProtocol.title
        do {
            _ = try await Self.respond(session)
            throw SettingsError("未收到有效的 bash 工具调用，请检查模型、额度及 \(title) 工具调用支持。")
        } catch let error as LanguageModelSession.ToolCallError {
            guard let outcome = error.underlyingError as? ProbeTool.Outcome else { throw error }
            if outcome == .invalid { throw SettingsError("未收到有效的 bash 工具调用，请检查模型、额度及 \(title) 工具调用支持。") }
        } catch let error as SettingsError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch is GeneratedContent.ParsingError {
            throw SettingsError("未收到有效的 bash 工具调用，请检查模型、额度及 \(title) 工具调用支持。")
        } catch {
            try Task.checkCancellation()
            // Provider errors can contain arbitrary response bodies; do not show them.
            throw SettingsError("模型请求失败，请检查服务地址、密钥、模型及 \(title) 工具调用支持。")
        }
    }

    @concurrent private static func respond(_ session: LanguageModelSession) async throws -> String {
        try await session.respond(to: "This is a tool capability test. Return exactly one bash tool call with command: printf 'ECHO_TOOL_PROBE'. Do not answer with text. The host will inspect the call without executing it.").content
    }

    struct ProbeProfile: LanguageModelSession.DynamicProfile {
        let model: EchoLanguageModel
        var body: some DynamicProfile {
            Profile {
                Instructions("You are a helpful assistant.")
                ProbeTool()
            }
            .model(model)
            .toolCallingMode(.required)
        }
    }

    /// Named and shaped like bash; ends the probe as soon as it is called.
    struct ProbeTool: Tool {
        enum Outcome: Error, Equatable { case called, invalid }
        let name = "bash"
        let description = "Execute a command in a fresh bash process"
        @Generable struct Input {
            var command: String
        }
        var parameters: GenerationSchema { Input.generationSchema }
        func call(arguments: GeneratedContent) async throws -> String {
            guard let input = try? Input(arguments), !input.command.isEmpty else { throw Outcome.invalid }
            throw Outcome.called
        }
    }
}
