import AgentProbe
import Foundation
import FoundationModels
import Synchronization
import Testing

// Phase 2 spike S11: `Tool.call` receives no call ID. Does the arguments' `GenerationID` identify
// the call — the same value in `onToolCall` and in `Tool.call`, and distinct for calls whose
// arguments are identical (plan §10 constraint 2)?

private final class IdentityLog: Sendable {
    let hooked = Mutex<[(call: String, generation: GenerationID?)]>([])
    let called = Mutex<[GenerationID?]>([])
}

private struct IdentityTool: Tool {
    let name = "echo"
    let description = "Echo the note back."
    let log: IdentityLog
    @Generable struct Input { @Guide(description: "The note") var note: String }
    var parameters: GenerationSchema { Input.generationSchema }
    func call(arguments: GeneratedContent) async throws -> String {
        log.called.withLock { $0.append(arguments.id) }
        try await Task.sleep(for: .milliseconds(20))
        return "echo"
    }
}

private struct IdentityProfile: LanguageModelSession.DynamicProfile {
    let log: IdentityLog
    let model: StepModel
    var body: some DynamicProfile {
        Profile {
            Instructions("probe")
            IdentityTool(log: log)
        }
        .model(model)
        .transcriptErrorHandlingPolicy(.preserveTranscript)
        .onToolCall { [log] call in log.hooked.withLock { $0.append((call.id, call.arguments.id)) } }
    }
}

@Suite struct S11CallIdentityTests {
    @Test func `arguments carry the call's identity into Tool.call`() async throws {
        let log = IdentityLog()
        let script = StepScript { _, channel, index in
            switch index {
            case 0:
                let entry = UUID().uuidString
                await Emit.toolCall("echo", #"{"note":"same"}"#, id: "call-a", entryID: entry, into: channel)
                await Emit.toolCall("echo", #"{"note":"same"}"#, id: "call-b", entryID: entry, into: channel)
            case 1:
                await Emit.toolCall("echo", #"{"note":"same"}"#, id: "call-a", into: channel)
            default:
                try await Emit.text(["done"], into: channel)
            }
        }
        let session = LanguageModelSession(profile: IdentityProfile(log: log, model: StepModel(script: script)), history: [])
        _ = try await session.respond(to: "go")
        let hooked = log.hooked.withLock { $0 }, called = log.called.withLock { $0 }
        print("REPORT S11 hooked=\(hooked.map { "\($0.call)=\(String(describing: $0.generation))" }) called=\(called.map { String(describing: $0) })")
        #expect(hooked.count == 3 && called.count == 3)
        #expect(hooked.allSatisfy { $0.generation != nil } && called.allSatisfy { $0 != nil })
        // The identity follows the call ID: distinct within one batch even for identical arguments,
        // and equal when a later generation reuses the ID (batches never overlap).
        #expect(hooked[0].generation != hooked[1].generation, "Identical arguments in one batch stay distinct")
        #expect(hooked[0].generation == hooked[2].generation, "A reused call ID in a later generation reuses the identity")
        #expect(called == hooked.map(\.generation) || Set(called.prefix(2).compactMap { $0 }) == Set(hooked.prefix(2).compactMap(\.generation)),
                "Tool.call sees the identity the hook saw")
        #expect(called.last == hooked.last?.generation)
        let transcriptIDs = session.transcript.compactMap { entry -> [GenerationID?]? in
            if case .toolCalls(let calls) = entry { return calls.map(\.arguments.id) } else { return nil }
        }.flatMap { $0 }
        #expect(Set(transcriptIDs.compactMap { $0 }) == Set(hooked.compactMap(\.generation)), "The transcript's calls carry the same identity")
    }
}
