import Foundation
import FoundationModels
import Synchronization

/// A deterministic, in-process model for the native Agent engine. Each model request runs the
/// script's step with the request and its index; the step streams into the channel through a
/// `ScriptedEmitter`. Like `EchoLanguageModel`, the executor spends the turn's budget first and
/// records the entries it finished in the ledger.
final class ScriptedAgentModel: Sendable, Hashable {
    typealias Step = @Sendable (_ request: LanguageModelExecutorGenerationRequest, _ emit: ScriptedEmitter, _ index: Int) async throws -> Void
    private let step: Step
    private let recorded = Mutex<[LanguageModelExecutorGenerationRequest]>([])
    private let finished = Mutex(0)

    init(step: @escaping Step) { self.step = step }

    var factory: AgentHarness.ModelFactory {
        { ledger, budget in ScriptedLanguageModel(script: self, ledger: ledger, budget: budget) }
    }
    var requests: [LanguageModelExecutorGenerationRequest] { recorded.withLock { $0 } }
    /// Requests whose step returned without throwing.
    var completedCount: Int { finished.withLock { $0 } }

    fileprivate func run(_ request: LanguageModelExecutorGenerationRequest, _ channel: LanguageModelExecutorGenerationChannel,
                         ledger: GenerationLedger, budget: GenerationBudget) async throws {
        try budget.spend()
        let index = recorded.withLock { $0.append(request); return $0.count - 1 }
        let emitter = ScriptedEmitter(channel: channel)
        try await step(request, emitter, index)
        ledger.markComplete(emitter.entryIDs, reply: emitter.reply)
        finished.withLock { $0 += 1 }
    }

    static func == (lhs: ScriptedAgentModel, rhs: ScriptedAgentModel) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

final class ScriptedEmitter: Sendable {
    let channel: LanguageModelExecutorGenerationChannel
    private let ids = Mutex<[String]>([])
    private let texts = Mutex<(id: String?, text: String, calls: Bool)>((nil, "", false))
    init(channel: LanguageModelExecutorGenerationChannel) { self.channel = channel }
    var entryIDs: [String] { ids.withLock { $0 } }
    /// Like the adapters: the text a generation ended with, when it made no tool call.
    var reply: GenerationLedger.Reply? {
        texts.withLock { state in
            guard !state.calls, let id = state.id, !state.text.isEmpty else { return nil }
            return GenerationLedger.Reply(id: id, text: state.text)
        }
    }
    private func note(_ id: String) { ids.withLock { if !$0.contains(id) { $0.append(id) } } }

    /// Streams text as one response entry; waits `gap` between chunks (cancellable).
    func text(_ chunks: [String], gap: Duration = .zero, entryID: String = "reply-" + UUID().uuidString) async throws {
        for (index, chunk) in chunks.enumerated() {
            if index > 0, gap > .zero { try await Task.sleep(for: gap) }
            note(entryID)
            texts.withLock { if $0.id != entryID { $0.id = entryID; $0.text = "" }; $0.text += chunk }
            await channel.send(.response(entryID: entryID, action: .appendText(chunk, tokenCount: 1)))
        }
    }
    func text(_ text: String) async throws { try await self.text([text]) }

    /// One tool-calls entry holding every call, as the adapters send them.
    func calls(_ calls: [(name: String, arguments: String, id: String)], entryID: String = "calls-" + UUID().uuidString) async {
        note(entryID)
        texts.withLock { $0.calls = true }
        for call in calls {
            await channel.send(.toolCalls(entryID: entryID, action: .toolCall(
                id: call.id, name: call.name, action: .appendArguments(call.arguments, tokenCount: 1))))
        }
    }
    func call(_ name: String, _ arguments: String, id: String = "call-1") async {
        await calls([(name, arguments, id)])
    }
}

struct ScriptedLanguageModel: LanguageModel {
    typealias Executor = ScriptedExecutor
    let script: ScriptedAgentModel
    let ledger: GenerationLedger
    let budget: GenerationBudget
    var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([.toolCalling]) }
    var executorConfiguration: ScriptedExecutor.Configuration { .init(script: script, ledger: ledger, budget: budget) }
}

struct ScriptedExecutor: LanguageModelExecutor {
    typealias Model = ScriptedLanguageModel
    struct Configuration: Hashable, Sendable {
        let script: ScriptedAgentModel
        let ledger: GenerationLedger
        let budget: GenerationBudget
    }
    let configuration: Configuration
    init(configuration: Configuration) { self.configuration = configuration }

    nonisolated(nonsending) func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: ScriptedLanguageModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        try await configuration.script.run(request, channel, ledger: configuration.ledger, budget: configuration.budget)
    }
}

/// Holds a step until the test opens it. Cancelling the waiter ends the wait with CancellationError.
final class ScriptGate: Sendable {
    private struct State {
        var open = false
        var arrived = 0
        var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    }
    private let state = Mutex(State())
    init() {}
    var arrivals: Int { state.withLock { $0.arrived } }
    func open() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
            state.open = true
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        waiters.forEach { $0.resume() }
    }
    func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let resumeNow = state.withLock { state -> Bool in
                    state.arrived += 1
                    if state.open { return true }
                    state.waiters[id] = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }
            waiter?.resume(throwing: CancellationError())
        }
    }
}

extension LanguageModelExecutorGenerationRequest {
    /// The request's transcript in the harness's terms, for assertions.
    var kinds: [String] {
        transcript.map { entry in
            switch entry {
            case .instructions: "instructions"
            case .prompt(let prompt):
                prompt.metadata[AgentPromptMarker.continueKey] != nil ? "continue"
                    : prompt.metadata[AgentPromptKey.feedback] != nil ? "feedback" : "prompt"
            case .response: "response"
            case .reasoning: "reasoning"
            case .toolCalls: "toolCalls"
            case .toolOutput: "toolOutput"
            @unknown default: "unknown"
            }
        }
    }
    /// Text of the user prompts the model sees, in order.
    var userTexts: [String] {
        transcript.compactMap { entry in
            guard case .prompt(let prompt) = entry, prompt.metadata[AgentPromptMarker.continueKey] == nil,
                  prompt.metadata[AgentPromptKey.feedback] == nil else { return nil }
            return AgentHarness.text(prompt.segments)
        }
    }
    var toolOutputs: [String] { transcript.toolOutputs }
    /// Text of the model's earlier replies the request carries, in order.
    var replies: [String] {
        transcript.compactMap { entry in
            guard case .response(let response) = entry else { return nil }
            let text = AgentHarness.text(response.segments)
            return text.isEmpty ? nil : text
        }
    }
    var feedback: [String] {
        transcript.compactMap { entry in
            guard case .prompt(let prompt) = entry, prompt.metadata[AgentPromptKey.feedback] != nil else { return nil }
            return AgentHarness.text(prompt.segments)
        }
    }
}

extension Sequence where Element == Transcript.Entry {
    /// The text of every tool result, in order.
    var toolOutputs: [String] {
        compactMap { entry in
            guard case .toolOutput(let output) = entry else { return nil }
            return AgentHarness.text(output.segments)
        }
    }
}

/// A model the test answers request by request: every model request waits until the test says
/// what the model returns. Stop cancels a waiting request, as it cancels a real one.
final class PuppetModel: Sendable {
    enum Answer: Sendable {
        case text(String)
        case call(name: String, arguments: String)
        case fail(AgentModelError)
        /// Text and calls pushed live by the test until it finishes the stream.
        case stream(PuppetStream)
    }
    private final class Queue: Sendable {
        let waiting = Mutex<[(id: UUID, continuation: CheckedContinuation<Answer, any Error>)]>([])
        let cancelled = Mutex(0)
        func next() async throws -> Answer {
            let id = UUID()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                    waiting.withLock { $0.append((id, continuation)) }
                }
            } onCancel: {
                let waiter = waiting.withLock { list -> CheckedContinuation<Answer, any Error>? in
                    guard let index = list.firstIndex(where: { $0.id == id }) else { return nil }
                    return list.remove(at: index).continuation
                }
                waiter?.resume(throwing: CancellationError())
            }
        }
    }
    private let queue = Queue()
    let model: ScriptedAgentModel

    init() {
        let queue = queue
        model = ScriptedAgentModel { _, emit, index in
            defer { if Task.isCancelled { queue.cancelled.withLock { $0 += 1 } } }
            switch try await queue.next() {
            case .text(let text): try await emit.text(text)
            case .call(let name, let arguments): await emit.call(name, arguments, id: "call-\(index)")
            case .fail(let error): throw error
            case .stream(let stream):
                for await event in stream.events {
                    switch event {
                    case .text(let text): try await emit.text([text], entryID: stream.entryID)
                    case .call(let name, let arguments): await emit.call(name, arguments, id: "call-\(index)")
                    case .fail(let error): throw error
                    }
                }
                // A cancelled stream ends the loop quietly; a real model request throws instead.
                try Task.checkCancellation()
            }
        }
    }

    var factory: AgentHarness.ModelFactory { model.factory }
    var requests: [LanguageModelExecutorGenerationRequest] { model.requests }
    var waiting: Int { queue.waiting.withLock { $0.count } }
    /// Requests cancelled before they ended, as Stop cancels them: waiting for an answer or
    /// writing one.
    var cancelledCount: Int { queue.cancelled.withLock { $0 } }

    /// Waits until a request is waiting, then answers the oldest one.
    @MainActor func answer(_ answer: Answer, timeout: Duration = .seconds(5)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while waiting == 0 {
            guard ContinuousClock.now < deadline else { throw SettingsError("No model request to answer") }
            try await Task.sleep(for: .milliseconds(2))
        }
        let waiter = queue.waiting.withLock { $0.removeFirst() }
        waiter.continuation.resume(returning: answer)
    }
    @MainActor func reply(_ text: String) async throws { try await answer(.text(text)) }
    /// Waits until `count` requests reached the model.
    @MainActor func waitForRequests(_ count: Int, timeout: Duration = .seconds(5)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while requests.count < count {
            guard ContinuousClock.now < deadline else { throw SettingsError("Model request \(count) never arrived") }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

/// A native Agent session whose model never answers: stores that only need to be Agent sessions.
@MainActor func idleAgent() -> AgentHarness {
    let puppet = PuppetModel()
    return AgentHarness(resolveModel: { puppet.factory })
}

/// Native Agent sessions for a workspace's conversations, each answered by its own puppet model,
/// in the order the workspace made them.
@MainActor final class PuppetSessions {
    private(set) var models: [PuppetModel] = []
    var last: PuppetModel? { models.last }
    var factory: () -> (any TaskSource)? {
        { [self] in
            let model = PuppetModel()
            models.append(model)
            return AgentHarness(resolveModel: { model.factory })
        }
    }
    /// Model requests across every conversation.
    var requestCount: Int { models.reduce(0) { $0 + $1.requests.count } }
    /// The model of the conversation whose latest request ends with the user message `text`.
    func model(asked text: String, timeout: Duration = .seconds(5)) async throws -> PuppetModel {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            if let model = models.first(where: { $0.requests.last?.userTexts.last == text }) { return model }
            guard ContinuousClock.now < deadline else { throw SettingsError("No model request for \(text)") }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

/// Live output of one puppet generation.
final class PuppetStream: Sendable {
    enum Event: Sendable { case text(String), call(name: String, arguments: String), fail(AgentModelError) }
    let entryID = "reply-" + UUID().uuidString
    let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    init() { (events, continuation) = AsyncStream.makeStream() }
    func send(_ text: String) { continuation.yield(.text(text)) }
    /// Sends chunks a gap apart, as a model streams them. Snapshots trail the model by up to two
    /// chunks, and chunks sent back to back can reach one snapshot together and be held with it.
    func send(_ chunks: [String], gap: Duration = .milliseconds(40)) async throws {
        for chunk in chunks { send(chunk); try await Task.sleep(for: gap) }
    }
    func call(_ name: String, _ arguments: String) { continuation.yield(.call(name: name, arguments: arguments)) }
    /// Ends the generation with a model error, after what it already streamed.
    func fail(_ error: AgentModelError) { continuation.yield(.fail(error)) }
    func finish() { continuation.finish() }
}
