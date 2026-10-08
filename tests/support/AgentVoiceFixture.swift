import AppKit
import Testing
import Foundation

@MainActor final class AgentVoiceFixture {
    let audio = FakeAudio()
    /// Answers the model requests of the fixture's own conversation.
    let puppet = PuppetModel()
    let source: AgentHarness
    /// Other conversations get an Agent whose requests are never answered.
    var sourceFactory: () -> AgentHarness = { AgentHarness(resolveModel: { PuppetModel().factory }) }
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
    init(source: AgentHarness? = nil) {
        let puppet = puppet
        self.source = source ?? AgentHarness(resolveModel: { puppet.factory })
    }
    /// User messages of the fixture's conversation, in order.
    var userTexts: [String] { store.messages.filter { $0.role == .user }.map(\.content) }
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

