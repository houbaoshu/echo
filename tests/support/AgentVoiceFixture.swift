import AppKit
import Testing
import Foundation

@MainActor final class AgentVoiceFixture {
    let audio = FakeAudio()
    /// Answers the model requests of the fixture's own conversation.
    let puppet = PuppetModel()
    let harness: AgentHarness
    /// Other conversations get an Agent whose requests are never answered.
    var harnessFactory: () -> AgentHarness = { AgentHarness(resolveModel: { PuppetModel().factory }) }
    var recognizers: [FakeRecognizer] = []
    var synths: [FakeSynthesizer] = []
    var finishDrain: CheckedContinuation<Void, Never>?
    var permission: @MainActor () async -> Bool = { true }
    lazy var store = TaskStore(harness: harness)
    lazy var voice = VoiceSessionController(audio: audio, recognizer: { [unowned self] in
        let client = FakeRecognizer(); recognizers.append(client); return client
    }, synthesizer: { [unowned self] in
        let client = FakeSynthesizer(); client.emitsAudio = true; synths.append(client); return client
    }, tailProtectionDuration: .milliseconds(40), bargeInTimeout: .milliseconds(200),
       permission: { [unowned self] in await permission() })
    lazy var workspace = WorkspaceStore(initialStore: store, voice: voice, harnessFactory: { [unowned self] in harnessFactory() })
    lazy var conversation = workspace.selected!
    lazy var settings = SettingsStore(secrets: FakeSecrets())
    init(harness: AgentHarness? = nil) {
        let puppet = puppet
        self.harness = harness ?? AgentHarness(resolveModel: { puppet.factory })
    }
    /// User messages of the fixture's conversation, in order.
    var userTexts: [String] { store.messages.filter { $0.role == .user }.map(\.content) }
    /// Starts the call without waiting for it.
    func begin() {
        voice.attach(workspace: workspace, settings: settings)
        voice.start(conversation: conversation, configuration: .init(), key: "fake")
    }
    /// Starts the call and waits until recognition has heard its first packet.
    func start() async throws {
        begin()
        try await eventually("the call captures audio") { audio.capturing }
        audio.input?.yield(.init(data: Data(repeating: 0, count: 640), epoch: audio.captureEpoch))
        try await eventually("recognition receives the first packet") { recognizers.last?.packets == 1 }
    }
    func speak(_ text: String, start: Int = 0, final: Bool = true) {
        recognizers.last?.emit(text, start: start, end: start + 200, final: final)
    }
    func holdPlayback() { audio.onDrain = { [unowned self] in await withCheckedContinuation { finishDrain = $0 } } }
    func releasePlayback() { finishDrain?.resume(); finishDrain = nil; audio.onDrain = nil }
    /// Sends `count` loud packets and waits until the call has handled them all.
    func frames(_ count: Int) async throws {
        let handled = audio.handledPackets
        for _ in 0..<count { audio.input?.yield(.init(data: VoiceFixtureSupport.activityPCM(), epoch: audio.captureEpoch)) }
        try await eventually("the call handles \(count) captured packets") { audio.handledPackets >= handled + count }
    }
    /// Activity during the reply, through to the barge-in recognizer that confirms it.
    func probe() async throws {
        let recognizers = recognizers.count
        try await frames(5) // Sustained activity pauses playback.
        try await frames(12) // Discard the acoustic tail.
        try await frames(5) // Independent activity opens clean ASR.
        try await eventually("the barge-in recognizer runs") {
            self.recognizers.count == recognizers + 1 && self.recognizers.last?.callback != nil
        }
    }
    func shutdown() { releasePlayback(); workspace.shutdown() }
}

