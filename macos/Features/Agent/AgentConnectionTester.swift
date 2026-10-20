import Foundation
import FoundationModels

/// The Agent connection test: Echo's own adapter asks for one call to a probe tool with
/// list_files's name, description and schema. The call itself is the result; the probe never
/// reads anything. Like an ordinary turn it leaves the choice to the model: a forced call is not
/// something Echo uses, and some services reject it (DeepSeek in thinking mode answers HTTP 400).
struct NativeConnectionTester: ConnectionTesting {
    @MainActor func test(configuration: ModelConfiguration, key: String) async throws {
        let configuration = try configuration.validated()
        guard !key.hasLineBreak else { throw SettingsError(localized: "API Key 不能包含换行。") }
        try Task.checkCancellation()
        let endpoint = AgentEndpoint(configuration, key: key)
        let model = EchoLanguageModel(endpoint: endpoint, transport: AgentTransport.make(for: endpoint),
                                      ledger: GenerationLedger(), budget: GenerationBudget(limit: 1))
        let session = LanguageModelSession(profile: ProbeProfile(model: model), history: [])
        let title = configuration.apiProtocol.title
        let noValidCall = SettingsError(localized: "未收到有效的工具调用，请检查模型、额度及 \(title) 工具调用支持。")
        do {
            _ = try await Self.respond(session)
            throw noValidCall
        } catch let error as LanguageModelSession.ToolCallError {
            guard let outcome = error.underlyingError as? ProbeTool.Outcome else { throw error }
            if outcome == .invalid { throw noValidCall }
        } catch let error as SettingsError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch is GeneratedContent.ParsingError {
            throw noValidCall
        } catch {
            try Task.checkCancellation()
            // Provider errors can contain arbitrary response bodies; do not show them.
            throw SettingsError(localized: "模型请求失败，请检查服务地址、密钥、模型及 \(title) 工具调用支持。")
        }
    }

    @concurrent private static func respond(_ session: LanguageModelSession) async throws -> String {
        try await session.respond(to: "This is a tool capability test. Return exactly one list_files tool call with path: \".\". Do not answer with text. The host will inspect the call without executing it.").content
    }

    struct ProbeProfile: LanguageModelSession.DynamicProfile {
        let model: EchoLanguageModel
        var body: some DynamicProfile {
            Profile {
                Instructions("You are a helpful assistant.")
                ProbeTool()
            }
            .model(model)
        }
    }

    /// Named and shaped like list_files; ends the probe as soon as it is called.
    struct ProbeTool: Tool {
        enum Outcome: Error, Equatable { case called, invalid }
        let name = "list_files"
        let description = ListFilesTool.toolDescription
        var parameters: GenerationSchema { ListFilesTool.Input.generationSchema }
        func call(arguments: GeneratedContent) async throws -> String {
            guard let input = try? ListFilesTool.Input(arguments), !input.path.isEmpty else { throw Outcome.invalid }
            throw Outcome.called
        }
    }
}
