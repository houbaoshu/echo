import AppKit
import Testing

extension EchoIntegrationScenarios {
  @Suite(.serialized) @MainActor struct AgentVoiceIntegrationTests {
    private static func waitForAgentVoice(_ label: String, _ condition: () -> Bool) async throws {
      let deadline = ContinuousClock.now.advanced(by: .seconds(8))
      while !condition() {
        try #require(ContinuousClock.now < deadline, "Timed out: \(label)")
        try await Task.sleep(for: .milliseconds(10))
      }
    }
    @Test(arguments: [ModelAPIProtocol.chatCompletions, .responses], ["tool", "model", "directory", "queue", "stop"])
    static func voiceRouting(apiProtocol: ModelAPIProtocol, scenario: String) async throws {
      try await withSession { session in
        let makeSource = { AgentFixture.source(server: session.server, protocol: apiProtocol) }
        let f = AgentVoiceFixture(source: makeSource())
        f.sourceFactory = makeSource
        defer { f.shutdown() }
        let project = session.root.appendingPathComponent("\(apiProtocol)-\(scenario)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        await f.start()
        let owner = f.conversation.id
        var holder: WorkspaceConversation?
        if scenario != "directory" {
          let projectID = f.workspace.addProject(url: project)
          f.workspace.associateProject(projectID, conversationID: owner)
          if scenario == "queue" {
            holder = f.workspace.newConversation(projectID: projectID)
            holder!.store.send("cancel-tool")
            try await waitForAgentVoice("queue holder starts") {
              holder!.store.tools.first?.state == .running
            }
          }
        }
        f.speak(
          scenario == "model"
            ? "slow-model tool"
            : scenario == "tool" ? "slow-tool" : scenario == "stop" ? "cancel-tool" : "tool")
        let run = f.store.task!.runID
        switch scenario {
        case "model":
          // The fixture records a request before it answers slowly.
          try await waitForAgentVoice("model request started") {
            session.server.requests.contains { String(decoding: $0, as: UTF8.self).contains("slow-model") }
          }
          try await Task.sleep(for: .milliseconds(120))
        case "directory":
          try await waitForAgentVoice("voice waits for directory") { f.store.needsDirectory }
          #expect(
            f.voice.status.contains("等待选择项目文件夹") && f.synths.isEmpty,
            "directory pause does not speak assistant explanation")
        case "queue":
          try await waitForAgentVoice("voice waits for project") { f.store.waitingForProject }
          #expect(f.voice.status == "等待项目空闲… · 可补充语音", "project queue exposes live voice input")
        default:
          try await waitForAgentVoice("voice command starts") {
            f.store.tools.first?.state == .running
          }
          #expect(
            f.voice.status.contains("正在运行命令") && f.synths.isEmpty,
            "running command remains audible-input only")
        }
        #expect(
          f.voice.snapshot.recognition == .listening,
          "ASR remains active through \(scenario) / \(apiProtocol)")
        if scenario == "stop" {
          f.workspace.stop(conversationID: owner)
          #expect(
            f.store.task?.status == .stopping && !f.store.canSubmit
              && f.voice.snapshot.recognition == .off(.stopping),
            "voice Stop gates the real command cleanup")
          try await waitForAgentVoice("voice Stop acknowledged") {
            !f.store.isGenerating && f.voice.snapshot.recognition == .listening
          }
          #expect(
            f.store.task?.status == .stopped && f.synths.isEmpty,
            "cancelled tools never produce spoken finals")
          // A Stop can land before the command wrote its first line; either way it never finishes.
          let trace = (try? String(contentsOf: project.appendingPathComponent("trace"), encoding: .utf8)) ?? ""
          #expect(!trace.contains("forbidden"), "voice Stop cleans up the command process group")
        } else {
          f.speak("skip old proposal; keep existing execution results", start: 300)
          f.speak("skip; also explain the result", start: 600)
          #expect(
            f.store.task?.runID == run && f.store.task?.status == .running,
            "voice steering does not cancel/restart the turn")
          try await waitForAgentVoice("voice final") {
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
          if scenario == "tool" {
            let trace = try String(
              contentsOf: project.appendingPathComponent("trace"), encoding: .utf8)
            #expect(
              trace == "started\ndone\n" && f.store.tools.first?.result?.contains("stdout") == true,
              "voice follow-up lets the running bash finish and preserves its real result")
          } else {
            #expect(
              f.store.tools.first?.state == .notExecuted,
              "voice steering prevents the obsolete tool proposal")
          }
          if scenario == "queue" {
            #expect(
              holder!.store.isGenerating && f.workspace.selectedID == holder!.id
                && f.voice.conversationID == owner,
              "queued voice stays with its owner while another session holds the project")
          }
        }
      }
    }
    @Test(arguments: [ModelAPIProtocol.chatCompletions, .responses])
    static func streamedMarkdown(apiProtocol: ModelAPIProtocol) async throws {
      try await withSession { session in
        let makeSource = { AgentFixture.source(server: session.server, protocol: apiProtocol) }
        let f = AgentVoiceFixture(source: makeSource())
        f.sourceFactory = makeSource
        defer { f.shutdown() }
        await f.start()
        f.voice.toggleSpeakerMute()
        f.speak("slow-stream markdown-stream 汇报结果")
        let final = "## 结果\n\n- **第一项**通过\n- 运行 `swift test`\n- 第三项\n- 第四项完成"
        var seen: [String] = []
        try await waitForAgentVoice("streamed reply completes for \(apiProtocol)") {
          let text = f.store.replyStream.text
          if f.store.isGenerating, !text.isEmpty, seen.last != text {
            seen.append(text)
          }
          return !f.store.isGenerating
        }
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
