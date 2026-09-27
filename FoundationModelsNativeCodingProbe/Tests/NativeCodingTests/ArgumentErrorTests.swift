import Foundation
import FoundationModels
import Testing
@testable import NativeCoding

/// 假模型：按 transcript 中已有的 tool output 数量决定下一步——依次发出脚本里的 tool call，脚本用完后回复最后一条 tool output。
/// 与真实 adapter 同层（executor），tool 调度与写回完全由 Foundation Models 完成。
struct ScriptedModel: LanguageModel {
    let calls: [ScriptedCall]
    var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([.toolCalling]) }
    var executorConfiguration: Executor.Configuration { .init(calls: calls) }

    struct Executor: LanguageModelExecutor {
        typealias Model = ScriptedModel
        struct Configuration: Hashable, Sendable { let calls: [ScriptedCall] }
        let configuration: Configuration
        init(configuration: Configuration) { self.configuration = configuration }

        func respond(
            to request: LanguageModelExecutorGenerationRequest, model: ScriptedModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            let outputs = request.transcript.compactMap { entry -> String? in
                if case .toolOutput(let output) = entry { return TranscriptReport.text(output.segments) }
                return nil
            }
            if outputs.count < configuration.calls.count {
                let call = configuration.calls[outputs.count]
                await channel.send(.toolCalls(
                    entryID: UUID().uuidString,
                    action: .toolCall(id: "call_\(outputs.count)", name: call.tool, action: .appendArguments(call.json, tokenCount: 1))
                ))
            } else {
                await channel.send(.response(entryID: UUID().uuidString, action: .appendText("last output: \(outputs.last ?? "")", tokenCount: 1)))
            }
        }
    }
}

struct ScriptedCall: Hashable, Sendable {
    let tool: String
    let json: String
}

/// 与 WriteFileTool 同名同 schema，但使用 typed `Arguments`（框架默认写法），用来固定框架的默认行为。
struct TypedWriteFileTool: Tool {
    let name = "write_file"
    let description = "Write a file"
    @Generable struct Arguments {
        var path: String
        var content: String
    }
    @concurrent func call(arguments: Arguments) async throws -> String { "wrote \(arguments.path)" }
}

@Suite struct ArgumentErrorTests {
    static let objectContent = ScriptedCall(tool: "write_file", json: #"{"path": "data.json", "content": {"books": 0.1, "toys": 0}}"#)
    static let stringContent = ScriptedCall(tool: "write_file", json: #"{"path": "data.json", "content": "{\"books\": 10}\n"}"#)

    /// 框架默认行为：typed Arguments 解码失败 → respond 抛 ToolCallError(ParsingError)，模型没有机会改正。
    @Test func typedArgumentsAbortRespond() async throws {
        let session = LanguageModelSession(model: ScriptedModel(calls: [Self.objectContent, Self.stringContent]), tools: [TypedWriteFileTool()])
        await #expect(throws: LanguageModelSession.ToolCallError.self) { try await session.respond(to: "go") }
    }

    /// 本 probe 的写法：错误作为 tool output 回到模型，同一次 respond 内模型改正后继续。
    @Test func selfDecodedArgumentsReturnErrorToModel() async throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("native-args-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let workspace = try Workspace(root: root)
        let log = ToolLog(echo: false)
        let session = LanguageModelSession(
            model: ScriptedModel(calls: [Self.objectContent, Self.stringContent]),
            tools: [WriteFileTool(workspace: workspace, log: log)]
        )
        let response = try await session.respond(to: "go")
        #expect(response.content.contains("created data.json"))
        #expect(log.all.map(\.argumentError) == [true, false])
        #expect(log.all.first?.output?.text.hasPrefix("error: invalid arguments for write_file") == true)
        #expect(try String(contentsOfFile: root + "/data.json", encoding: .utf8) == "{\"books\": 10}\n")
        #expect(TranscriptReport.kinds(session.transcript) == ["instructions", "prompt", "toolCalls", "toolOutput", "toolCalls", "toolOutput", "response"])
    }

    /// 对模型公布的 schema 不变：仍是 typed Input 的字段与类型。
    @Test func advertisedSchemaIsTyped() throws {
        let log = ToolLog(echo: false)
        let workspace = try Workspace(root: NSTemporaryDirectory())
        let json = try String(decoding: JSONEncoder().encode(WriteFileTool(workspace: workspace, log: log).parameters), as: UTF8.self)
        #expect(json.contains("\"content\"") && json.contains("\"path\"") && json.contains("\"string\""))
    }
}
