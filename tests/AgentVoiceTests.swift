import AppKit
import Testing
import Foundation

extension EchoVoiceScenarios {
@Suite(.serialized) enum AgentVoiceTests {
    /// Speech while the Agent works steers the same run; a call waiting for Finder and a project
    /// queue keep voice input open; mute closes only input; Stop pauses submission until cleanup; Continue
    /// appends nothing; ending the call leaves the Agent running.
    @Test @MainActor static func agentVoiceTests() async throws {
        _ = NSApplication.shared
        let finder = HeldFinder()
        let f = AgentVoiceFixture(finder: finder)
        defer { finder.gate.open(); f.shutdown() }
        try await f.start()
        f.store.mainDraft = "保留草稿"
        f.speak("开始检查")
        let run = try #require(f.store.task?.runID)
        let recognizer = f.recognizers[0]
        try await f.puppet.waitForRequests(1)
        #expect(f.userTexts == ["开始检查"] && f.voice.snapshot.recognition == .listening,
              "Agent voice submits once and keeps recognition during the model request")
        // The model asks Finder where the person is, and Finder has not answered yet.
        try await f.puppet.answer(.call(name: "finder_location", arguments: "{}"))
        try await eventually("Finder is asked", timeout: .seconds(8)) { finder.gate.arrivals == 1 }
        #expect(f.voice.status == "正在查看访达位置 · 可补充语音", "a waiting call stays visible while voice input stays enabled")
        f.speak("先回答问题", start: 300)
        #expect(f.userTexts.last == "先回答问题" && !recognizer.cancelled && f.store.task?.runID == run,
              "a follow-up to a waiting call steers the same run")
        f.speak("补充一", start: 600); f.speak("补充二", start: 900); f.speak("补充二", start: 900)
        #expect(f.userTexts == ["开始检查", "先回答问题", "补充一", "补充二"] && f.store.task?.status == .running,
              "ordered voice follow-ups steer without cancellation or duplicate ASR finals")
        #expect(f.store.messages.suffix(2).allSatisfy { $0.steering == .queued }, "queued follow-ups keep their pending marker")
        f.voice.toggleMute()
        f.speak("静音不能提交", start: 1200)
        #expect(f.userTexts.count == 4 && f.audio.capturePaused && f.store.task?.status == .running,
              "mute closes only input during an active Agent task")
        f.voice.toggleMute()
        try await eventually("the unmuted call listens on a new recognizer") { f.voice.snapshot.recognition == .listening && f.recognizers.count == 2 }
        #expect(f.voice.snapshot.recognition == .listening && f.recognizers.count == 2,
              "unmute resumes input while the Agent is still running")
        // Request 1 asked Finder; the generation the follow-up superseded never reached
        // the model. Request 2 takes the follow-ups so far and waits at the model; until then a
        // follow-up sent below could still join it, leaving nothing queued for Continue.
        try await eventually("request 2 has taken the earlier follow-ups and waits at the model") {
            f.puppet.requests.count == 2 && f.puppet.waiting == 1
                && f.puppet.requests.last?.userTexts.suffix(3) == ["先回答问题", "补充一", "补充二"]
                && !f.store.messages.contains { $0.steering == .queued }
        }

        let other = f.workspace.newConversation(), owner = try #require(f.voice.snapshot.session.owner)
        f.workspace.send("其他会话", conversationID: other.id)
        f.speak("原会话补充", start: 1500)
        #expect(f.workspace.selectedID == other.id && f.voice.snapshot.session.owner == owner
              && f.userTexts.last == "原会话补充" && other.store.messages.count == 1,
              "navigation and parallel conversation activity do not move voice ownership")
        #expect(f.workspace.send("文字补充", conversationID: f.conversation.id) && f.store.task?.runID == run
              && f.store.task?.status == .running, "workspace text uses steering even when Live Voice owns the conversation")
        try await eventually("listening reopens after the text follow-up") { f.voice.snapshot.recognition == .listening }
        #expect(f.voice.snapshot.recognition == .listening && f.store.mainDraft == "保留草稿",
              "text follow-up reopens listening and preserves drafts")
        // What the Continue check below relies on: these two are still queued when Stop lands.
        #expect(f.store.messages.filter { $0.steering == .queued }.map(\.content) == ["原会话补充", "文字补充"],
                "the two latest follow-ups wait for the next request")
        f.workspace.stop(conversationID: f.conversation.id)
        #expect(f.store.task?.status == .stopping && f.voice.status == "正在停止…" && f.voice.snapshot.recognition == .off(.stopping),
              "explicit Stop waits for cleanup with voice submission paused")
        let stopping = f.voice.snapshot, interruptions = f.audio.stops
        f.workspace.stop(conversationID: f.conversation.id)
        #expect(f.voice.snapshot == stopping && f.audio.stops == interruptions, "repeated Stop during cleanup changes nothing")
        let users = f.userTexts.count
        f.speak("停止期间的迟到定稿", start: 1800)
        #expect(!f.workspace.send("等待清理", conversationID: f.conversation.id) && f.userTexts.count == users,
              "late voice and text cannot start a run during cleanup")
        try await eventually("cleanup restores listening", timeout: .seconds(8)) {
            f.store.task?.status == .stopped && f.voice.snapshot.recognition == .listening
        }
        #expect(f.voice.isActive && f.store.canSubmit && f.synths.isEmpty, "cleanup restores listening without ending the call")
        #expect(f.userTexts.count == users - 2 && f.store.mainDraft == "保留草稿\n原会话补充\n文字补充",
                "the follow-ups the stopped turn never took go back to the draft, spoken or typed, in order")
        let requests = f.puppet.requests.count, kept = f.userTexts.count
        #expect(f.workspace.retry(conversationID: f.conversation.id) && f.userTexts.count == kept,
              "voice Continue neither replays nor appends the original request")
        try await f.puppet.waitForRequests(requests + 1)
        #expect(f.puppet.requests.last?.kinds.last == "continue" && f.store.mainDraft == "保留草稿\n原会话补充\n文字补充",
                "Continue resumes the stopped turn; the follow-ups wait in the draft")
        f.voice.end()
        #expect(f.store.isGenerating && !f.audio.capturing, "ending Live Voice releases audio without cancelling the Agent")
    }

    /// Live Voice talks to the same Agent: a spoken "记住…" reaches remember, and the next spoken
    /// question's request carries the memory.
    @Test @MainActor static func agentVoiceMemoryTests() async throws {
        _ = NSApplication.shared
        let memory = AgentMemoryFile(folder: FileManager.default.temporaryDirectory.appendingPathComponent("echo-voice-memory-\(UUID())"))
        defer { try? FileManager.default.removeItem(at: memory.folder) }
        let model = ScriptedAgentModel { _, emit, index in
            if index == 0 { await emit.call("remember", #"{"text":"喜欢喝美式"}"#) }
            else { try await emit.text(index == 1 ? "记住了" : "你喜欢喝美式") }
        }
        let f = AgentVoiceFixture(harness: AgentHarness(resolveModel: { model.factory }, finder: NoFinder(), memory: memory))
        defer { f.shutdown() }
        try await f.start()
        f.speak("记住我喜欢喝美式")
        try await eventually("the reply is spoken", timeout: .seconds(8)) { f.synths.first?.chunks == ["记住了"] }
        #expect((try? String(contentsOf: memory.url, encoding: .utf8)) == "- 喜欢喝美式\n")
        #expect(f.store.tools.map(\.tool) == ["remember"] && f.store.tools.first?.state == .finished)
        try await eventually("the call listens again", timeout: .seconds(8)) {
            !f.store.isGenerating && f.voice.snapshot.recognition == .listening
        }
        f.speak("我喜欢喝什么", start: 3000)
        try await eventually("the second reply is spoken", timeout: .seconds(8)) { f.synths.last?.chunks == ["你喜欢喝美式"] }
        let instructions = try #require(model.requests.last).transcript.compactMap { entry -> String? in
            if case .instructions(let instructions) = entry { AgentHarness.text(instructions.segments) } else { nil }
        }.joined()
        #expect(instructions.hasSuffix("<memory>\n- 喜欢喝美式\n</memory>"), "\(instructions.suffix(200))")
    }

    /// A finished utterance stops being a pending partial whatever becomes of it, including when
    /// the conversation refuses it (its save failed) or cannot take input at all.
    @Test @MainActor static func agentRefusedFinalTests() async throws {
        _ = NSApplication.shared
        let f = AgentVoiceFixture()
        defer { f.shutdown() }
        try await f.start(); f.holdPlayback(); f.speak("第一个问题")
        #expect(f.store.isGenerating, "the first utterance opened a turn")

        // Refused while the turn runs: the message is appended, the partial is not kept.
        f.store.checkpoint = { _ in throw CocoaError(.fileWriteNoPermission) }
        let settled = f.store.messages.count
        f.speak("追加一句", start: 400)
        #expect(f.store.messages.count == settled + 1 && f.store.messages.last?.content == "追加一句",
              "the refused follow-up still left its own message: \(f.store.messages.map(\.content))")
        #expect(f.voice.subtitle.isEmpty, "a refused follow-up is not also a pending partial: \(f.voice.subtitle)")
        #expect(f.store.notice != nil, "the chat says why it was refused")
        try await eventually("refused turn ends", timeout: .seconds(8)) { !f.store.isGenerating }

        // Refused before submission is even allowed: nothing is left standing in for a message.
        f.store.agentLoadError = "Agent 会话无法加载。"
        #expect(!f.store.canSubmit, "a chat whose Agent failed to load admits nothing")
        let stopped = f.store.messages.count
        f.recognizers.last?.callback?(.init(result: .init(text: "发不出去的一句", utterances: [
            .init(text: "发不出去的一句", start_time: 800, end_time: 1000, definite: true)
        ])))
        #expect(f.store.messages.count == stopped && f.voice.subtitle.isEmpty,
              "an unsubmittable final becomes neither a message nor a leftover partial: \(f.voice.subtitle)")
    }

    /// Input that would start a turn is refused when its save fails. The call stopped listening as
    /// the turn started, so it ends with the save's failure, as when a follow-up is refused during a
    /// turn, rather than stay on without listening. A message typed during the call ends it alike.
    @Test @MainActor static func agentFirstSaveFailureEndsTheCallTests() async throws {
        _ = NSApplication.shared
        for typed in [false, true] {
            let f = AgentVoiceFixture()
            defer { f.shutdown() }
            try await f.start()
            f.store.checkpoint = { _ in throw CocoaError(.fileWriteNoPermission) }
            if typed { #expect(!f.workspace.send("打字的第一句", conversationID: f.conversation.id)) }
            else { f.speak("第一个问题") }
            #expect(f.store.task?.status == .failed && !f.store.isGenerating, "typed=\(typed): the turn never began")
            try await eventually("typed=\(typed): the call ends") { f.voice.snapshot.session == .inactive }
            #expect(f.voice.error?.contains("聊天保存失败") == true, "typed=\(typed): \(f.voice.error ?? "no error")")
        }
    }

    @Test @MainActor static func agentVoiceRecoveryTests() async throws {
        _ = NSApplication.shared
        let f = AgentVoiceFixture()
        defer { f.shutdown() }
        try await f.start(); f.holdPlayback(); f.speak("第一次问题")
        try await f.puppet.reply("第一次回答")
        try await eventually("first reply", timeout: .seconds(8)) {
            f.store.task?.status == .completed && f.synths.count == 1 && f.audio.played.count == 1
        }
        #expect(f.workspace.send("第二次问题", conversationID: f.conversation.id), "text can interrupt completed audio")
        let run = try #require(f.store.task?.runID)
        #expect(f.voice.snapshot.recognition == .off(.recovery) && f.audio.capturePaused,
              "text interruption keeps acoustic tail protection during the next Agent request")
        // The follow-up arrives while that request is with the model, not before it was made.
        try await f.puppet.waitForRequests(2)
        #expect(f.workspace.send("紧接着补充", conversationID: f.conversation.id) && f.store.task?.runID == run,
              "a second text message steers the same round")
        #expect(f.voice.snapshot.recognition == .off(.recovery) && f.audio.capturePaused,
              "another submission cannot bypass the existing acoustic tail timer")
        f.releasePlayback()
        try await eventually("f.voice.snapshot.recognition == .listening") { f.voice.snapshot.recognition == .listening }
        #expect(!f.audio.capturePaused && f.store.isGenerating, "tail expiry restores listening during model work")
        f.voice.end()
        try await f.start(); f.holdPlayback()
        // The request that was running when the follow-up arrived answers first; that text is not the reply.
        try await f.puppet.reply("先说第二次")
        try await f.puppet.reply("新的最终回答")
        try await eventually("rejoined final", timeout: .seconds(8)) { f.synths.count == 2 && !f.synths[1].chunks.isEmpty }
        #expect(f.voice.error == nil, "rejoining a running Agent resets old TTS text and speaks the new final")
        #expect(f.synths[1].chunks == ["新的最终回答"], "rejoining a running Agent resets old TTS text and speaks the new final")
        f.releasePlayback()
        try await eventually("f.voice.snapshot.recognition == .listening") { f.voice.snapshot.recognition == .listening }
        f.recognizers.last?.callback?(.init(result: .init(text: "下一句仍在讲话", utterances: [
            .init(text: "已经定稿", start_time: 0, end_time: 200, definite: true),
            .init(text: "下一句仍在讲话", start_time: 300, end_time: 500, definite: false)
        ])))
        #expect(f.userTexts.last == "已经定稿" && f.voice.subtitle == "下一句仍在讲话",
              "a mixed ASR batch submits finals while retaining the next utterance's partial")
    }

    /// The streamed reply follows the model's text per step, keeps the last reply between turns,
    /// withdraws text that turns into a tool call, and never reaches speech before the final reply.
    /// (Stream snapshots trail the model by two chunks, so each check sends past the text it
    /// expects and waits for it.)
    @Test @MainActor static func agentReplyStreamTests() async throws {
        _ = NSApplication.shared
        let f = AgentVoiceFixture()
        defer { f.shutdown() }
        try await f.start(); f.holdPlayback()
        f.voice.toggleSpeakerMute(); f.speak("第一个问题")
        try await f.puppet.waitForRequests(1)
        let stream = f.store.replyStream
        #expect(stream.text.isEmpty && stream.live == nil, "requesting the model has no reply text")
        let first = PuppetStream()
        try await f.puppet.answer(.stream(first))
        try await first.send(["今天", "**天气**不错，", "适合"])
        try await eventually("the first delta shows", timeout: .seconds(8)) { stream.live?.hasPrefix("今天") == true }
        #expect(f.synths.isEmpty, "streaming text never starts speech")
        first.send("散步。"); first.finish()
        try await eventually("final reply", timeout: .seconds(8)) { f.synths.count == 1 && !f.synths[0].chunks.isEmpty }
        #expect(stream.text == "今天**天气**不错，适合散步。", "speech receives only the final reply")
        #expect(stream.live == nil, "speech receives only the final reply")
        #expect(f.synths[0].chunks == ["今天**天气**不错，适合散步。"], "speech receives only the final reply")
        #expect(f.store.messages.last?.content == "今天**天气**不错，适合散步。",
              "the settled reply is the conversation's own message, so nothing streams beside it")
        f.releasePlayback()
        try await eventually("playback ends") { f.voice.snapshot.replyAudio == .none }
        #expect(stream.text == "今天**天气**不错，适合散步。", "the reply stays after playback ends")

        let recognizers = f.recognizers.count
        try await eventually("listening resumes after the reply", timeout: .seconds(8)) {
            f.voice.snapshot.recognition == .listening && f.recognizers.count > recognizers
        }
        f.speak("第二个问题", start: 400)
        try await f.puppet.waitForRequests(2)
        #expect(f.store.isGenerating && stream.text == "今天**天气**不错，适合散步。" && stream.live == nil,
              "a new request keeps the previous reply and streams nothing yet")
        let second = PuppetStream()
        try await f.puppet.answer(.stream(second))
        try await second.send([" \n", "我先看看目录。", "\n"])
        try await eventually("the next turn's text replaces the previous reply", timeout: .seconds(8)) { stream.text.contains("我先看看目录") }
        second.call("list_files", #"{"path":"."}"#); second.finish()
        try await eventually("text beside a call is withdrawn", timeout: .seconds(8)) {
            stream.text == "今天**天气**不错，适合散步。" && stream.live == nil
        }
        #expect(f.store.messages.contains { $0.role == .assistant && $0.content.contains("我先看看目录") },
              "the withdrawn text stays as a message of its own")
        f.workspace.stop(conversationID: f.conversation.id)
        try await eventually("stopped", timeout: .seconds(8)) { !f.store.isGenerating }
        #expect(stream.text == "今天**天气**不错，适合散步。" && stream.live == nil, "a stopped step keeps no partial reply")
    }

    /// The muted bubble follows what speech has actually played: subtitles time each character,
    /// playback frames say how far the audio got, and the text is shown on that same timeline.
    @Test @MainActor static func agentSpokenReplyTests() async throws {
        _ = NSApplication.shared
        let f = AgentVoiceFixture()
        defer { f.shutdown() }
        try await f.start(); f.holdPlayback()
        f.voice.toggleSpeakerMute()
        func bubble() -> CompanionBubbleContent {
            CompanionBubbleContent(voice: f.voice.snapshot, spoken: f.voice.spoken, position: f.voice.spokenPosition, notice: nil)
        }
        func shown() -> Bool { CompanionBubbleContent.isShown(voice: f.voice.snapshot, spoken: f.voice.spoken, notice: nil) }
        #expect(bubble() == .none && !shown(), "listening shows no bubble")
        f.speak("介绍一下")
        try await f.puppet.waitForRequests(1)
        let reply = "## 天气\n\n今天**天气**很好，适合散步。"
        #expect(bubble() == .status("正在思考…") && shown(), "requesting the model shows it thinking")
        f.audio.playbackFrames = 4800
        try await f.puppet.reply(reply)
        try await eventually("reply synthesized", timeout: .seconds(8)) { f.synths.count == 1 && f.audio.played.count == 1 }
        #expect(f.voice.spoken == nil, "audio that starts before its subtitles shows nothing yet")
        #expect(!shown(), "audio that starts before its subtitles shows nothing yet")
        let synth = f.synths[0]
        synth.subtitle([("##", 0), ("天", 0.1), ("气。", 0.3), ("今", 0.9), ("天", 1.1), ("天", 1.3), ("气", 1.5), ("很", 1.7), ("好，", 1.9)])
        #expect(shown() && f.voice.spoken?.source == reply, "the first subtitle makes the bubble take its place")
        f.audio.playbackFrames = 4800 + 21600
        #expect(bubble() == .reply(reply, heard: "##天气。今"), "0.9 seconds in, the bubble shows 0.9 seconds of text")
        f.audio.playbackFrames = 4800 + 28800
        #expect(bubble() == .reply(reply, heard: "##天气。今天"), "1.2 seconds in, the text still tracks the audio, not ahead of it")
        synth.subtitle([("适", 2.3), ("合", 2.5), ("散", 2.7), ("步。", 2.9)])
        f.audio.playbackFrames = 4800 + 43200
        #expect(bubble() == .reply(reply, heard: "##天气。今天天气很"), "1.8 seconds in, the reply is still within its first sentence")
        f.audio.playbackFrames = 4800 + 64800
        #expect(bubble() == .reply(reply, heard: "##天气。今天天气很好，适合散"), "later sentences extend the timeline")
        f.releasePlayback()
        try await eventually("the reply finishes playing") { f.voice.spoken?.stoppedAt == .infinity }
        #expect(f.voice.spoken?.stoppedAt == .infinity && bubble() == .reply(reply, heard: nil) && shown(),
              "finished playback shows the whole reply and keeps it")

        let recognizers = f.recognizers.count
        try await eventually("listening resumes after the reply", timeout: .seconds(8)) {
            f.voice.snapshot.recognition == .listening && f.recognizers.count > recognizers
        }
        f.holdPlayback()
        f.speak("再说一个", start: 400)
        try await f.puppet.waitForRequests(2)
        #expect(f.voice.spoken == nil && bubble() == .status("正在思考…"), "the next turn replaces the previous reply with its status")
        try await f.puppet.reply("好的，下午见。")
        try await eventually("second reply synthesized", timeout: .seconds(8)) { f.synths.count == 2 && f.audio.played.count == 2 }
        #expect(bubble() == .none && !shown(), "new audio without subtitles shows nothing yet")
        f.synths[1].subtitle([("好", 0), ("的，", 0.2), ("下", 0.6), ("午", 0.8), ("见。", 1.0)])
        f.audio.playbackFrames += 7200
        #expect(bubble() == .reply("好的，下午见。", heard: "好的，"), "the next reply's first subtitle replaces the previous one")
        f.audio.playbackFrames += 7200
        #expect(bubble() == .reply("好的，下午见。", heard: "好的，下"), "the new reply is timed from its own audio, on its own timeline")
        f.audio.playbackFrames -= 7200
        f.voice.stopReply()
        f.audio.playbackFrames = 96000
        #expect(f.voice.spoken?.stoppedAt == 0.3 && bubble() == .reply("好的，下午见。", heard: "好的，"),
              "an interrupted reply keeps what was heard")
        f.voice.toggleSpeakerMute()
        #expect(bubble() == .none && !shown(), "an audible reply shows no bubble")
        f.voice.toggleSpeakerMute()

        // A voice that sends no subtitles shows its reply once playback has finished.
        let recovered = f.recognizers.count
        try await eventually("listening resumes after the stop", timeout: .seconds(8)) {
            f.voice.snapshot.recognition == .listening && f.recognizers.count > recovered
        }
        f.speak("第三个问题", start: 800)
        try await f.puppet.reply("没有字幕的回复。")
        try await eventually("third reply synthesized", timeout: .seconds(8)) { f.synths.count == 3 && f.audio.played.count == 3 }
        #expect(bubble() == .none && !shown(), "the new turn took away the previous reply, and nothing of this one is heard yet")
        f.releasePlayback()
        try await eventually("the reply without subtitles finishes playing") { f.voice.spoken?.source == "没有字幕的回复。" }
        #expect(bubble() == .reply("没有字幕的回复。", heard: nil) && shown(), "a reply without subtitles appears whole after playback")
        f.voice.end()
        #expect(f.voice.spoken == nil, "ending Live Voice forgets the spoken reply")
    }

    /// The bubble says what the agent is doing in a call: thinking from the start of a turn, each
    /// tool as it runs, with the text changing in place from one to the next, and nothing a moment
    /// after the last tool, when the turn ends or when it is stopped.
    @Test @MainActor static func agentVoiceStatusTests() async throws {
        _ = NSApplication.shared
        let finder = HeldFinder()
        let f = AgentVoiceFixture(finder: finder)
        f.statusLinger = .milliseconds(500)
        defer { finder.gate.open(); f.shutdown() }
        try await f.start()
        func bubble() -> CompanionBubbleContent {
            CompanionBubbleContent(voice: f.voice.snapshot, spoken: f.voice.spoken, position: f.voice.spokenPosition, notice: nil)
        }
        var shownLog: [Bool] = []
        let shownObservation = observeChanges({
            CompanionBubbleContent.isShown(voice: f.voice.snapshot, spoken: f.voice.spoken, notice: nil)
        }) { shownLog.append($0) }
        defer { shownObservation.cancel() }
        #expect(bubble() == .none, "listening shows no status")

        f.speak("访达里有什么")
        try await f.puppet.waitForRequests(1)
        #expect(bubble() == .status("正在思考…"), "a turn starts out thinking")
        try await f.puppet.answer(.call(name: "finder_location", arguments: "{}"))
        try await eventually("Finder is asked", timeout: .seconds(8)) { finder.gate.arrivals == 1 }
        #expect(bubble() == .status("正在查看访达位置"), "a running tool names itself")
        finder.gate.open()
        try await f.puppet.waitForRequests(2)
        #expect(bubble() == .status("正在查看访达位置"), "a finished tool stays a moment")
        try await f.puppet.answer(.call(name: "list_files", arguments: #"{"path":"notes"}"#))
        try await eventually("the next tool replaces the text") { bubble() == .status("正在列出文件 · notes") }
        try await f.puppet.waitForRequests(3)
        try await eventually("the bubble closes a moment after the last tool", timeout: .seconds(3)) { bubble() == .none }
        #expect(shownLog == [true, false], "from thinking through both tools the bubble never closed: \(shownLog)")
        #expect(f.voice.snapshot.agentActivity == "正在列出文件 · notes", "the planet still thinks on the last tool")

        try await f.puppet.reply("访达里没有打开的文件夹。")
        try await eventually("listening resumes after the reply", timeout: .seconds(8)) {
            f.store.task?.status == .completed && f.voice.snapshot.recognition == .listening && f.voice.snapshot.replyAudio == .none
        }
        f.speak("再想想", start: 400)
        try await f.puppet.waitForRequests(4)
        #expect(bubble() == .status("正在思考…"), "the next turn thinks again")
        try await Task.sleep(for: .milliseconds(700))
        #expect(bubble() == .status("正在思考…"), "thinking lasts until something happens, however long")
        f.store.stopTask()
        #expect(bubble() == .none, "stopping closes the bubble at once")
        try await eventually("the stopped turn settles") { f.store.task?.status == .stopped }
        #expect(bubble() == .none, "a stopped turn shows no status")
    }

    /// While Live Voice runs its conversation is in progress; ending the session makes it unseen.
    @Test @MainActor static func agentVoiceUnseenTests() async throws {
        _ = NSApplication.shared
        for viewed in [false, true] {
            let f = AgentVoiceFixture()
            defer { f.shutdown() }
            f.workspace.isMainWindowVisible = viewed
            try await f.start(); f.holdPlayback()
            f.speak("第一轮")
            #expect(f.store.isGenerating && !f.store.isActivityVisible, "a Live Voice turn keeps its task card folded")
            try await f.puppet.reply("第一轮回复")
            try await eventually("first reply", timeout: .seconds(8)) { f.synths.count == 1 }
            f.releasePlayback()
            let recognizers = f.recognizers.count
            try await eventually("listening resumes", timeout: .seconds(8)) {
                f.voice.snapshot.recognition == .listening && f.recognizers.count > recognizers
            }
            f.holdPlayback()
            f.speak("第二轮", start: 400)
            try await f.puppet.reply("第二轮回复")
            try await eventually("second reply", timeout: .seconds(8)) { f.synths.count == 2 }
            f.releasePlayback()
            try await eventually("the second reply finishes playing") { f.voice.snapshot.replyAudio == .none }
            let surface = PetSurfacePresentation(hovered: true, composerOpen: false, draft: "",
                activityCount: f.store.activityCount, activitiesCollapsed: f.store.activitiesCollapsed,
                unseenCompleted: f.workspace.unseenCompletedCount, voice: f.voice.snapshot, canStartVoice: false,
                runningTasks: f.workspace.runningTaskCount)
            #expect(f.workspace.unseenCompletedCount == 0 && !f.store.hasUnseenCompletion && surface.tray != .bell(unseen: 0)
                  && surface.tray != .bell(unseen: 1), "completed Live Voice turns are neither unseen nor shown as a bell")
            f.voice.end()
            if viewed {
                #expect(f.workspace.unseenCompletedCount == 0, "a Live Voice conversation viewed in the main window ends seen")
            } else {
                #expect(f.workspace.unseenCompletedCount == 1 && f.store.hasUnseenCompletion && f.store.activitiesCollapsed,
                      "ending Live Voice turns its conversation into one unseen completion")
                let bell = PetSurfacePresentation(hovered: true, composerOpen: false, draft: "",
                    activityCount: f.store.activityCount, activitiesCollapsed: f.store.activitiesCollapsed,
                    unseenCompleted: f.workspace.unseenCompletedCount, voice: f.voice.snapshot, canStartVoice: true)
                #expect(bell.tray == .bell(unseen: 1), "the bell appears with its count once the voice session ends")
                f.workspace.isMainWindowVisible = true
                #expect(f.workspace.unseenCompletedCount == 0, "viewing the conversation clears it by the existing rule")
            }
        }
        // A session with no completed reply leaves nothing unseen.
        let f = AgentVoiceFixture()
        defer { f.shutdown() }
        try await f.start(); f.voice.end()
        #expect(f.workspace.unseenCompletedCount == 0, "an empty Live Voice session creates no unseen item")
    }

    /// The pet hears nothing of a call: not its turns, not another chat ending meanwhile, not the
    /// failed turn that ends it (this fixture has no planet, so the call lets go at once), and
    /// nothing once it is over. A call that starts on a running turn takes that turn along.
    /// Whether the call or the workspace hears that failure first changes from run to run (Combine
    /// keeps a subject's subscribers unordered), so the short case repeats to meet both orders.
    @Test @MainActor static func agentVoicePetHearsNothingOfACall() async throws {
        _ = NSApplication.shared
        for adopted in [false] + Array(repeating: true, count: 10) {
            let f = AgentVoiceFixture()
            let other = PuppetModel()
            f.harnessFactory = { AgentHarness(resolveModel: { other.factory }, finder: NoFinder()) }
            defer { f.shutdown() }
            _ = f.conversation
            var told: [String] = []
            f.workspace.onPetTaskEvent = { told.append(PetStore.taskAnimation(for: $0) ?? "-") }
            #expect(f.workspace.sendQuickMessage("通话前开始"))
            let chat = try #require(f.workspace.activity)
            if adopted { #expect(f.store.send("通话前开始的本会话任务")) }
            #expect(told == Array(repeating: "task-running", count: adopted ? 2 : 1), "\(told)")
            told = []
            try await f.start()
            if !adopted {
                f.holdPlayback(); f.speak("第一轮")
                try await f.puppet.reply("第一轮回复")
                try await eventually("the call's reply plays", timeout: .seconds(8)) { f.synths.count == 1 }
                let recognizers = f.recognizers.count
                f.releasePlayback()
                try await eventually("listening resumes", timeout: .seconds(8)) {
                    f.voice.snapshot.recognition == .listening && f.recognizers.count > recognizers
                }
                f.speak("第二轮", start: 400)
                try await eventually("the call's second turn runs") { f.store.isGenerating }
            }
            try await other.reply("通话期间完成")
            try await eventually("the other chat ends") { !chat.store.isGenerating }
            try await f.puppet.answer(.fail(AgentModelError(message: "通话里失败")))
            try await eventually("the failure ends the call", timeout: .seconds(8)) { f.voice.snapshot.session.owner == nil }
            #expect(told.isEmpty, "Nothing of the call reaches the pet: \(told)")
            await nextMainTurn()
            #expect(told.isEmpty, "Nor once it is over: \(told)")
            #expect(f.workspace.send("通话后", conversationID: chat.id))
            try await other.reply("通话后完成")
            try await eventually("the chat ends after the call") { !chat.store.isGenerating }
            #expect(told == ["task-running", "review"], "\(told)")
        }
    }

    @Test @MainActor static func agentFinalAudioTests() async throws {
        _ = NSApplication.shared
        for finalFirst in [false, true] {
            let f = AgentVoiceFixture()
            defer { f.shutdown() }
            try await f.start(); f.holdPlayback(); f.speak("最初的问题")
            let run = try #require(f.store.task?.runID)
            try await f.puppet.waitForRequests(1)
            #expect(f.synths.isEmpty && f.voice.snapshot.recognition == .listening,
                  "a question with no reply yet starts no synthesis and keeps ASR open")
            var completions: [String] = []
            let subscription = f.store.lifecycle.sink {
                if case .reply(_, .completed(let text)) = $0 { completions.append(text) }
            }
            defer { subscription.cancel() }
            try await f.puppet.reply("今天的天气非常晴朗，适合出门散步。")
            try await eventually("final reply", timeout: .seconds(8)) { f.synths.count == 1 && f.finishDrain != nil }
            #expect(f.synths[0].chunks == ["今天的天气非常晴朗，适合出门散步。"], "only the final reply is spoken as one synthesis input")
            #expect(f.voice.snapshot.replyAudio == .draining(run), "only the final reply is spoken as one synthesis input")
            let finalMessage = try #require(f.store.responseMessage)
            #expect(finalMessage.role == .assistant && f.store.messages.filter { $0.role == .assistant }.count == 1
                  && completions == [finalMessage.content] && f.store.task?.summary == "已完成",
                  "history owns the only final message; completion and speech use its content, summary contains only status")
            f.store.lifecycle.send(.reply(run, .completed(finalMessage.content)))
            #expect(f.synths.count == 1 && f.synths[0].chunks.count == 1, "a repeated completion never replays the final")
            let oldAudio = f.synths[0].callback!, oldRecognizer = f.recognizers[0]
            try await f.probe()
            #expect(f.voice.snapshot.bargeIn == .checking(run) && f.recognizers.count == 2,
                  "final playback retains acoustic barge-in confirmation")
            f.speak("今天的天气非常晴朗", final: true)
            oldRecognizer.emit("迟到的定稿", start: 900, end: 1000, final: true)
            #expect(f.userTexts.count == 1 && !f.synths[0].cancelled, "echo and old ASR cannot interrupt or submit")
            f.speak("再看看明天", final: finalFirst)
            #expect(f.synths[0].cancelled && ![.stopping, .stopped].contains(f.store.task?.status),
                  "confirmed barge-in interrupts only TTS and preserves the completed task")
            if !finalFirst {
                #expect(f.userTexts.count == 1 && f.voice.subtitle == "再看看明天", "partial speech is not submitted")
                f.speak("再看看明天")
            }
            f.speak("再看看明天")
            #expect(f.userTexts == ["最初的问题", "再看看明天"] && f.store.task?.runID != run
                  && f.voice.snapshot.recognition == .listening, "one final starts the next round after completed playback")
            do { try await oldAudio(Data([1, 2])); Issue.record("old audio must be rejected") }
            catch is CancellationError {  }
            let drains = f.audio.finishedDrains
            f.releasePlayback()
            try await eventually("the old playback drain returns") { f.audio.finishedDrains > drains }
            #expect(f.voice.snapshot.recognition == .listening && f.synths.count == 1,
                  "old playback drain cannot change the new round or replay its predecessor")
        }
        // A final arriving while the user has a partial must preserve that utterance.
        let f = AgentVoiceFixture()
        defer { f.shutdown() }
        try await f.start(); f.speak("问题"); f.speak("正在补充", start: 300, final: false)
        try await f.puppet.reply("刚返回的最终结果")
        try await eventually("final arrives", timeout: .seconds(8)) { f.store.task?.status == .completed }
        #expect(f.synths.isEmpty && f.voice.subtitle == "正在补充", "a final cannot cut off a follow-up already being spoken")
        f.speak("正在补充", start: 300)
        #expect(f.userTexts.count == 2 && f.store.isGenerating, "the preserved utterance can start the next round")
    }

    @Test @MainActor static func agentVoiceStartupAndFailureTests() async throws {
        _ = NSApplication.shared
        do {
            let f = AgentVoiceFixture()
            var allowed: CheckedContinuation<Bool, Never>?
            f.permission = { await withCheckedContinuation { allowed = $0 } }
            defer { allowed?.resume(returning: false); f.shutdown() }
            _ = f.conversation
            #expect(f.store.send("通话前开始的任务"), "the Agent run starts before Live Voice")
            let run = try #require(f.store.task?.runID)
            f.begin()
            try await eventually("the call asks for the microphone") { allowed != nil }
            #expect(allowed != nil && f.voice.snapshot.session == .starting(f.voice.snapshot.session.owner!),
                  "the call waits for microphone permission while the Agent runs")
            try await f.puppet.reply("启动期间完成的最终回复")
            try await eventually("final during startup", timeout: .seconds(8)) { f.store.task?.status == .completed }
            #expect(f.synths.isEmpty, "a final received during startup waits for audio activation")
            allowed?.resume(returning: true); allowed = nil
            try await eventually("startup final is spoken", timeout: .seconds(8)) {
                f.synths.first?.chunks == ["启动期间完成的最终回复"]
            }
            f.store.lifecycle.send(.reply(run, .completed("启动期间完成的最终回复")))
            #expect(f.synths.count == 1, "the deferred final is spoken once after activation")
        }
        for failure in [false, true] {
            let f = AgentVoiceFixture()
            var allowed: CheckedContinuation<Bool, Never>?
            f.permission = { await withCheckedContinuation { allowed = $0 } }
            defer { allowed?.resume(returning: false); f.shutdown() }
            _ = f.conversation
            f.store.send("已经运行的任务")
            let run = f.store.task?.runID
            f.begin()
            try await eventually("the call asks for the microphone") { allowed != nil }
            #expect(f.workspace.send("权限等待期间补充", conversationID: f.conversation.id)
                  && f.userTexts.last == "权限等待期间补充" && f.store.task?.status == .running,
                  "voice startup preserves an existing task and allows text steering")
            allowed?.resume(returning: true); allowed = nil
            try await eventually("activation listens") { f.voice.snapshot.recognition == .listening }
            #expect(f.voice.snapshot.recognition == .listening && f.store.task?.runID == run,
                  "activation begins listening during the existing Agent round")
            if failure {
                f.audio.onFailure?("测试录音故障", .deviceChange)
                #expect(!f.voice.isActive && f.store.isGenerating && f.voice.snapshot.error?.conversationID == f.conversation.id,
                      "audio failure ends voice and reports its owner without cancelling the Agent")
            } else {
                f.voice.toggleMute(); f.workspace.stop(conversationID: f.conversation.id)
                try await eventually("cleanup", timeout: .seconds(8)) { !f.store.isGenerating }
                #expect(f.voice.isMuted && f.voice.snapshot.recognition == .off(.muted), "cleanup preserves microphone mute")
                f.voice.toggleMute()
                try await eventually("unmuting restarts recognition") { f.voice.snapshot.recognition == .listening }
                #expect(f.voice.snapshot.recognition == .listening, "unmute after cleanup restarts recognition")
            }
        }
    }

    /// The Live Voice contract on the native engine, with the real harness and a scripted model:
    /// speech while the Agent works steers the same run, only the final reply is spoken and
    /// exactly once, Stop pauses submission until cleanup, and Continue appends nothing.
    @Test @MainActor static func nativeAgentVoiceTests() async throws {
        _ = NSApplication.shared
        let gate = ScriptGate(), stopGate = ScriptGate()
        let model = ScriptedAgentModel { request, emit, index in
            switch index {
            case 0:
                try await gate.wait()
                try await emit.text("先说一句中间话")
            case 1: try await emit.text("最终回复：\(request.userTexts.joined(separator: "，"))")
            case 2: try await stopGate.wait()   // held until Stop cancels it
            default: try await emit.text("继续后的回复")
            }
        }
        let f = AgentVoiceFixture(harness: AgentHarness(resolveModel: { model.factory }))
        defer { f.shutdown() }
        var completions: [String] = []
        let subscription = f.store.lifecycle.sink { if case .reply(_, .completed(let text)) = $0 { completions.append(text) } }
        defer { subscription.cancel() }
        try await f.start()
        f.speak("开始检查")
        let run = try #require(f.store.task?.runID)
        try await eventually("model request", timeout: .seconds(8)) { gate.arrivals == 1 }
        #expect(f.voice.snapshot.recognition == .listening, "Recognition stays open during the model request")
        f.speak("补充一", start: 300)
        #expect(f.store.task?.runID == run && f.store.messages.last?.steering == .queued, "Speech steers the same run")
        gate.open()
        try await eventually("final reply", timeout: .seconds(8)) { !f.store.isGenerating }
        try await eventually("the final reply is synthesized") { f.synths.first?.chunks == ["最终回复：开始检查，补充一"] }
        #expect(completions == ["最终回复：开始检查，补充一"] && f.store.responseMessage?.content == completions.first)
        #expect(f.synths.count == 1 && f.synths.first?.chunks == ["最终回复：开始检查，补充一"],
                "Only the final reply is spoken, once; the text before the steering is not")
        #expect(f.store.messages.filter { $0.role == .assistant }.map(\.content) == ["先说一句中间话", "最终回复：开始检查，补充一"])

        // The reply is still being spoken; the next run starts from the composer, as text does during a call.
        #expect(f.workspace.send("再查一次", conversationID: f.conversation.id))
        try await eventually("second run", timeout: .seconds(8)) { f.store.isGenerating && stopGate.arrivals == 1 }
        f.workspace.stop(conversationID: f.conversation.id)
        #expect(f.store.task?.status == .stopping && !f.store.canSubmit)
        #expect(!f.workspace.send("停止期间", conversationID: f.conversation.id), "Nothing starts during cleanup")
        try await eventually("stopped", timeout: .seconds(8)) { f.store.task?.status == .stopped }
        #expect(f.voice.isActive && f.store.canSubmit && f.synths.count == 1, "A stopped turn is not spoken and the call goes on")
        let users = f.store.messages.filter { $0.role == .user }.count
        #expect(f.workspace.retry(conversationID: f.conversation.id))
        try await eventually("continued", timeout: .seconds(8)) { !f.store.isGenerating }
        #expect(f.store.messages.filter { $0.role == .user }.count == users && f.store.responseMessage?.content == "继续后的回复")
    }
}

}

/// Answers finder_location only when the test opens the gate; no test asks the real Finder.
struct HeldFinder: FinderLocating {
    let gate = ScriptGate()
    func locate() async -> FinderLocation {
        try? await gate.wait()
        return .unavailable(.noFolder)
    }
}
