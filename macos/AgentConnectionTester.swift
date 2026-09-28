import Foundation
import FoundationModels

/// The Agent connection test: Echo's own adapter, one required call to a probe tool
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
