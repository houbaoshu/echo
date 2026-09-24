import AppKit
import Testing
import Foundation

@MainActor final class ScriptedVoiceAgent: AgentSessionSource {
    var receive: ((AgentBatch) -> Void)?
    var sessionID = ""
    var generation = ""
    var commands: [(String, String?)] = []
    var cancels = 0
    /// Refuses admissions the way a core that rejects `send_message` does.
    var rejectSends = false
    private var entries: [AgentDisplayEntry] = []
    private var receipts: [AgentInputReceipt] = []
    private var turnID: UInt64 = 0
    private var nextID: UInt64 = 1
    private var revision: UInt64 = 0
    private var finalID: UInt64?
    private var newTurn = false
    private var streamReceiver: ((AgentStream) -> Void)?
    var currentTurn: UInt64 { turnID }
    func observeStream(_ receive: @escaping (AgentStream) -> Void) { streamReceiver = receive }
    /// A coalesced stream snapshot, as the bridge delivers it between polls.
    func observeStreamForTest(_ stream: AgentStream) { streamReceiver?(stream) }
    func stream(operation: UInt64, _ text: String, toolCall: Bool = false) {
        streamReceiver?(AgentStream(turn_id: turnID, operation_id: operation, text: text, tool_call: toolCall))
    }
    func emit(operation: UInt64, _ kind: AgentEvent.Kind) {
        receive?(AgentBatch(session_id: sessionID, generation: generation, turn_id: turnID,
            kind: .init(type: .update),
            events: [AgentEvent(version: 1, session_id: sessionID, turn_id: turnID, operation_id: operation, kind: kind)]))
    }
    func start(messages: [ConversationMessage], receive: @escaping @MainActor (TaskEvent) -> Void) {
        Issue.record("Voice must use the unified Agent session")
    }
    func open(sessionID: String, generation: String, restore: AgentRestore,
              receive: @escaping (AgentBatch) -> Void, failure: @escaping (String) -> Void) throws {
        self.sessionID = sessionID; self.generation = generation; self.receive = receive
        revision = 0; newTurn = true
    }
    func control(_ command: AgentCommand) throws {
        if command.isControl { return }
        switch command {
        case .sendMessage(let input):
            if rejectSends { throw SettingsError("核心拒绝了这次输入。") }
            commands.append(("send_message", input.text))
            if newTurn { turnID = nextID; nextID += 1; finalID = nil; newTurn = false }
            let id = nextID; nextID += 1
            receipts.append(.init(client_message_id: input.client_message_id, message_id: id, turn_id: turnID))
            entries.append(.init(type: .message, message_id: id, turn_id: turnID, role: .user, text: input.text))
        case .continue:
            commands.append(("continue", nil)); turnID = nextID; nextID += 1; finalID = nil
        default: break
        }
    }
    func cancel() { cancels += 1 }
    func close(afterCleanup: @escaping () -> Void) { afterCleanup() }
    func emit(_ kind: AgentEvent.Kind, cancelled: Bool = false) {
        receive?(AgentBatch(session_id: sessionID, generation: generation, turn_id: turnID,
            kind: .init(type: cancelled ? .cancelled : .update),
            events: [AgentEvent(version: 1, session_id: sessionID, turn_id: turnID, kind: kind)]))
    }
    func complete(_ text: String, rawReply: String? = nil, operation: UInt64? = nil) {
        if finalID == nil {
            finalID = nextID; nextID += 1
            entries.append(.init(type: .message, message_id: finalID!, turn_id: turnID,
                                 role: .assistant, text: text, final_reply: true))
        }
        revision += 1
        let kinds: [AgentEvent.Kind] = [
            .init(type: .assistant, message_id: finalID!, content: text, final_reply: true),
            .init(type: .finished, outcome: AgentOutcome(status: .completed, reply: rawReply ?? text))
        ]
        receive?(AgentBatch(session_id: sessionID, generation: generation, turn_id: turnID,
            kind: .init(type: .update),
            events: kinds.map { AgentEvent(version: 1, session_id: sessionID, turn_id: turnID, operation_id: operation, kind: $0) },
            checkpoint: AgentCheckpoint(id: .init(generation: generation, revision: revision), history: "{}",
                                        input_receipts: receipts, projection: entries)))
    }
}

@MainActor final class AgentVoiceFixture {
    let audio = FakeAudio()
    let source: any TaskSource
    var sourceFactory: () -> (any TaskSource)? = { ScriptedVoiceAgent() }
    var recognizers: [FakeRecognizer] = []
    var synths: [FakeSynthesizer] = []
    var finishDrain: CheckedContinuation<Void, Never>?
    var permission: @MainActor () async -> Bool = { true }
    lazy var store = TaskStore(source: source)
    lazy var voice = VoiceSessionController(audio: audio, recognizer: { [unowned self] in
        let client = FakeRecognizer(); recognizers.append(client); return client
    }, synthesizer: { [unowned self] in
        let client = FakeSynthesizer(); client.emitsAudio = true; synths.append(client); return client
    }, tailProtectionDuration: .milliseconds(40), bargeInTimeout: .milliseconds(200),
       permission: { [unowned self] in await permission() })
    lazy var workspace = WorkspaceStore(initialStore: store, voice: voice, sourceFactory: { [unowned self] in sourceFactory() })
    lazy var conversation = workspace.selected!
    lazy var settings = SettingsStore(secrets: FakeSecrets())
    init(source: any TaskSource = ScriptedVoiceAgent()) { self.source = source }
    func start() async {
        voice.attach(workspace: workspace, settings: settings)
        voice.start(conversation: conversation, configuration: .init(), key: "fake")
        await VoiceFixtureSupport.tick()
        audio.input?.yield(.init(data: Data(repeating: 0, count: 640), epoch: audio.captureEpoch))
        await VoiceFixtureSupport.tick()
    }
    func speak(_ text: String, start: Int = 0, final: Bool = true) {
        recognizers.last?.emit(text, start: start, end: start + 200, final: final)
    }
    func holdPlayback() { audio.onDrain = { [unowned self] in await withCheckedContinuation { finishDrain = $0 } } }
    func releasePlayback() { finishDrain?.resume(); finishDrain = nil; audio.onDrain = nil }
    func frames(_ count: Int) async {
        for _ in 0..<count { audio.input?.yield(.init(data: VoiceFixtureSupport.activityPCM(), epoch: audio.captureEpoch)) }
        await VoiceFixtureSupport.tick()
    }
    func probe() async {
        await frames(5) // Sustained activity pauses playback.
        await frames(12) // Discard the acoustic tail.
        await frames(5) // Independent activity opens clean ASR.
    }
    func shutdown() { releasePlayback(); workspace.shutdown() }
}

