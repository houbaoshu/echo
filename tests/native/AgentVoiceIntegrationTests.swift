import AppKit
import Testing

extension EchoIntegrationScenarios {
  @Suite(.serialized) @MainActor struct AgentVoiceIntegrationTests {
    /// Voice input while the model request is held: follow-ups steer the turn, or voice Stop
    /// ends it, and ASR keeps listening throughout.
    @Test(arguments: [ModelAPIProtocol.chatCompletions, .responses], ["model", "stop"])
    static func voiceRouting(apiProtocol: ModelAPIProtocol, scenario: String) async throws {
      try await withSession { session in
        let makeHarness = { AgentFixture.harness(server: session.server, protocol: apiProtocol) }
        let f = AgentVoiceFixture(harness: makeHarness())
        f.harnessFactory = makeHarness
        defer { f.shutdown() }
        let project = session.root.appendingPathComponent("\(apiProtocol)-\(scenario)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try await f.start()
        let owner = f.conversation.id
        f.workspace.associateProject(f.workspace.addProject(url: project), conversationID: owner)
        f.speak("slow-model tool")
        let run = f.store.task!.runID
        // The fixture holds the request until it is released: the model request is under way.
        try await eventually("the model request is held", timeout: .seconds(8)) { session.server.slowModel.arrivals == 1 }
        #expect(
          f.voice.snapshot.recognition == .listening,
          "ASR remains active through \(scenario) / \(apiProtocol)")
        if scenario == "stop" {
          f.workspace.stop(conversationID: owner)
          #expect(
            f.store.task?.status == .stopping && !f.store.canSubmit
              && f.voice.snapshot.recognition == .off(.stopping),
            "voice Stop gates the turn's end")
          try await eventually("voice Stop acknowledged", timeout: .seconds(8)) {
            !f.store.isGenerating && f.voice.snapshot.recognition == .listening
          }
          #expect(
            f.store.task?.status == .stopped && f.synths.isEmpty && f.store.tools.isEmpty,
            "a stopped turn never produces a spoken final")
        } else {
          f.speak("skip old proposal; keep existing results", start: 300)
          f.speak("skip; also explain the result", start: 600)
          #expect(
            f.store.task?.runID == run && f.store.task?.status == .running,
            "voice steering does not cancel/restart the turn")
          session.server.slowModel.release()
          try await eventually("voice final", timeout: .seconds(8)) {
            !f.store.isGenerating && f.synths.first?.chunks.isEmpty == false
          }
          let users = f.store.messages.filter { $0.role == .user }
          #expect(
            users.count == 3 && users.suffix(2).allSatisfy { $0.steering == nil },
            "Core receives both voice follow-ups in order and clears their queued caption")
          #expect(
            f.store.task?.status == .completed && f.synths.count == 1
              && f.synths[0].chunks == [
                f.store.messages.last(where: { $0.role == .assistant })!.content
              ],
            "real Core speaks exactly the final reply for \(scenario) / \(apiProtocol)")
          #expect(
            f.store.tools.first?.state == .notExecuted,
            "voice steering prevents the obsolete tool proposal")
        }
      }
    }
    @Test(arguments: [ModelAPIProtocol.chatCompletions, .responses])
    static func streamedMarkdown(apiProtocol: ModelAPIProtocol) async throws {
      try await withSession { session in
        let makeHarness = { AgentFixture.harness(server: session.server, protocol: apiProtocol) }
        let f = AgentVoiceFixture(harness: makeHarness())
        f.harnessFactory = makeHarness
        defer { f.shutdown() }
        try await f.start()
        f.voice.toggleSpeakerMute()
        let final = "## 结果\n\n- **第一项**通过\n- 运行 `swift test`\n- 第三项\n- 第四项完成"
        // Every text the reply passes through while the turn runs, as each change is written.
        var seen: [String] = []
        let store = f.store
        let watch = observeChanges({ store.replyStream.text }) { text in
          if store.isGenerating, !text.isEmpty { seen.append(text) }
        }
        defer { watch.cancel() }
        f.speak("slow-stream markdown-stream 汇报结果")
        try await eventually("streamed reply completes for \(apiProtocol)", timeout: .seconds(8)) { !f.store.isGenerating }
        #expect(
          seen.filter { $0 != final }.count >= 2 && seen.allSatisfy { final.hasPrefix($0) },
          "real SSE deltas grow the reply before the turn completes (\(apiProtocol): \(seen.count) updates)"
        )
        #expect(
          f.store.replyStream.text == final && f.store.task?.status == .completed,
          "the completed Markdown reply is kept after streaming (\(apiProtocol))")
      }
    }
  }
}
