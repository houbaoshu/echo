import AppKit
import Testing
import Foundation

extension VoiceTests {
    @MainActor private static func waitForAgentVoice(_ label: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition() {
            guard Date() < deadline else { throw SettingsError("Timed out: \(label)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test(.tags(.fast)) @MainActor static func agentVoiceTests() async throws {
        _ = NSApplication.shared
        do {
            let source = ScriptedVoiceAgent(), f = AgentVoiceFixture(source: source)
            defer { f.shutdown() }
            await f.start()
            f.store.mainDraft = "保留草稿"
            f.speak("开始检查")
            let run = f.store.task!.runID, recognizer = f.recognizers[0]
            check(source.commands.map(\.0) == ["send_message"] && f.voice.snapshot.recognition == .listening,
                  "Agent voice submits once and keeps recognition during the model request")
            f.speak("补充一", start: 300); f.speak("补充二", start: 600); f.speak("补充二", start: 600)
            check(source.commands.map(\.0) == ["send_message", "send_message", "send_message"] && source.cancels == 0,
                  "ordered voice follow-ups steer without cancellation or duplicate ASR finals")
            check(f.store.task?.runID == run && f.store.messages.suffix(2).allSatisfy { $0.steering == "待处理" },
                  "voice follow-ups retain the active run and pending markers")
            source.emit(.init(type: .directory_required))
            check(f.voice.status == "等待选择项目文件夹 · 可补充语音" && f.store.needsDirectory,
                  "directory wait remains visible while voice input stays enabled")
            f.speak("先回答问题", start: 900)
            check(!f.store.needsDirectory && source.commands.last?.0 == "send_message" && !recognizer.cancelled,
                  "directory-wait follow-up uses the same Core steering path")
            f.voice.toggleMute()
            f.speak("静音不能提交", start: 1200)
            check(source.commands.count == 4 && f.audio.capturePaused && source.cancels == 0,
                  "mute closes only input during an active Agent task")
            f.voice.toggleMute(); await tick()
            check(f.voice.snapshot.recognition == .listening && f.recognizers.count == 2,
                  "unmute resumes input while the Agent is still running")

            let other = f.workspace.newConversation(), owner = f.voice.snapshot.session.owner!
            f.workspace.send("其他会话", conversationID: other.id)
            f.speak("原会话补充")
            check(f.workspace.selectedID == other.id && f.voice.snapshot.session.owner == owner
                  && source.commands.last?.1 == "原会话补充" && other.store.messages.count == 1,
                  "navigation and parallel conversation activity do not move voice ownership")
            check(f.workspace.send("文字补充", conversationID: f.conversation.id) && f.store.task?.runID == run
                  && source.commands.last?.0 == "send_message" && source.cancels == 0,
                  "workspace text uses steering even when Live Voice owns the conversation")
            await tick()
            check(f.voice.snapshot.recognition == .listening && f.store.mainDraft == "保留草稿",
                  "text follow-up reopens listening and preserves drafts")
            f.workspace.stop(conversationID: f.conversation.id)
            check(f.store.task?.status == .stopping && f.voice.status == "正在停止…"
                  && f.voice.snapshot.recognition == .off(.stopping) && source.cancels == 1,
                  "explicit Stop waits for cleanup with voice submission paused")
            let stopping = f.voice.snapshot, interruptions = f.audio.stops
            f.workspace.stop(conversationID: f.conversation.id)
            check(f.voice.snapshot == stopping && f.audio.stops == interruptions && source.cancels == 1,
                  "repeated Stop during cleanup leaves voice state and cancellation unchanged")
            let commandCount = source.commands.count
            f.speak("停止期间的迟到定稿")
            check(!f.workspace.send("等待清理", conversationID: f.conversation.id) && source.commands.count == commandCount,
                  "late voice and text cannot start a run during cleanup")
            source.complete("停止后旧回复")
            check(f.synths.isEmpty && f.store.task?.status == .stopping, "Stop suppresses an unconfirmed old completion")
            source.emit(.init(type: .finished, outcome: .init(status: .interrupted)), cancelled: true)
            await tick()
            check(f.voice.isActive && f.voice.snapshot.recognition == .listening && f.store.canSubmit,
                  "cleanup acknowledgement restores listening without ending the call")
            let users = f.store.messages.count
            check(f.workspace.retry(conversationID: f.conversation.id) && source.commands.last?.0 == "continue"
                  && f.store.messages.count == users, "voice Continue neither replays nor appends the original request")
            f.voice.end()
            check(source.cancels == 1 && f.store.isGenerating && !f.audio.capturing,
                  "ending Live Voice releases audio without cancelling the Agent")
        }
    }

    /// A finished utterance stops being a pending partial whatever becomes of it. `sendAgent`
    /// appends the user message before it can fail, so a refused admission that kept the
    /// partial would show the same sentence twice — once as the message, once as speech still
    /// being recognised — and a refusal before any message would show one that was never sent.
    @Test(.tags(.fast)) @MainActor static func agentRefusedFinalTests() async throws {
        _ = NSApplication.shared
        let source = ScriptedVoiceAgent(), f = AgentVoiceFixture(source: source)
        defer { f.shutdown() }
        await f.start(); f.holdPlayback(); f.speak("第一个问题")
        check(f.store.isGenerating, "the first utterance opened a turn")

        // Refused while the turn runs: the message is already appended, the partial is not kept.
        source.rejectSends = true
        let settled = f.store.messages.count
        f.speak("追加一句", start: 400)
        check(f.store.messages.count == settled + 1 && f.store.messages.last?.content == "追加一句",
              "the refused follow-up still left its own message: \(f.store.messages.map(\.content))")
        check(f.voice.subtitle.isEmpty, "a refused follow-up is not also a pending partial: \(f.voice.subtitle)")
        check(f.store.notice != nil, "the chat says why it was refused")

        // Refused before submission is even allowed: nothing is left standing in for a message.
        // A session whose Agent failed to load keeps listening — `activate` does not check
        // `canSubmit` — so this is the one refusal ASR keeps running through.
        source.rejectSends = false
        f.store.agentLoadError = "Agent 会话无法加载。"
        check(!f.store.canSubmit, "a chat whose Agent failed to load admits nothing")
        let stopped = f.store.messages.count
        f.recognizers.last?.callback?(.init(result: .init(text: "发不出去的一句", utterances: [
            .init(text: "发不出去的一句", start_time: 800, end_time: 1000, definite: true)
        ])))
        check(f.store.messages.count == stopped && f.voice.subtitle.isEmpty,
              "an unsubmittable final becomes neither a message nor a leftover partial: \(f.voice.subtitle)")
    }

    @Test(.tags(.fast)) @MainActor static func agentVoiceRecoveryTests() async throws {
        _ = NSApplication.shared
        let source = ScriptedVoiceAgent(), f = AgentVoiceFixture(source: source)
        defer { f.shutdown() }
        await f.start(); f.holdPlayback(); f.speak("第一次问题")
        source.complete("第一次回答"); await tick()
        check(f.workspace.send("第二次问题", conversationID: f.conversation.id), "text can interrupt completed audio")
        let run = f.store.task!.runID
        check(f.voice.snapshot.recognition == .off(.recovery) && f.audio.capturePaused,
              "text interruption keeps acoustic tail protection during the next Agent request")
        check(f.workspace.send("紧接着补充", conversationID: f.conversation.id) && f.store.task?.runID == run,
              "a second text message steers the same round")
        check(f.voice.snapshot.recognition == .off(.recovery) && f.audio.capturePaused,
              "another submission cannot bypass the existing acoustic tail timer")
        f.releasePlayback()
        await waitUntil { f.voice.snapshot.recognition == .listening }
        check(!f.audio.capturePaused && f.store.isGenerating, "tail expiry restores listening during model work")
        f.voice.end()
        await f.start(); f.holdPlayback()
        source.complete("新的最终回答"); await tick()
        check(f.voice.error == nil && f.synths.count == 2 && f.synths[1].chunks == ["新的最终回答"],
              "rejoining a running Agent resets old TTS text and speaks the new final")
        f.releasePlayback()
        await waitUntil { f.voice.snapshot.recognition == .listening }
        f.recognizers.last?.callback?(.init(result: .init(text: "下一句仍在讲话", utterances: [
            .init(text: "已经定稿", start_time: 0, end_time: 200, definite: true),
            .init(text: "下一句仍在讲话", start_time: 300, end_time: 500, definite: false)
        ])))
        check(source.commands.last?.1 == "已经定稿" && f.voice.subtitle == "下一句仍在讲话",
              "a mixed ASR batch submits finals while retaining the next utterance's partial")
    }

    /// The streamed reply follows real deltas per model step, keeps the last reply between
    /// turns and never reaches speech before the final reply.
    @Test(.tags(.fast)) @MainActor static func agentReplyStreamTests() async throws {
        _ = NSApplication.shared
        let source = ScriptedVoiceAgent(), f = AgentVoiceFixture(source: source)
        defer { f.shutdown() }
        await f.start(); f.holdPlayback()
        f.voice.toggleSpeakerMute(); f.speak("第一个问题")
        source.emit(.init(type: .turn_started)); source.emit(.init(type: .model_started))
        let stream = f.store.replyStream
        check(stream.text.isEmpty && stream.live == nil, "requesting the model has no reply text")
        source.stream(operation: 10, "今天")
        check(stream.text == "今天" && stream.live == "今天" && f.synths.isEmpty,
              "the first real delta arrives without starting speech")
        source.stream(operation: 10, "今天**天气**不错，")
        check(stream.text == "今天**天气**不错，" && f.synths.isEmpty, "each delta grows the same reply")
        source.complete("今天**天气**不错，适合散步。", operation: 10)
        await tick()
        check(stream.text == "今天**天气**不错，适合散步。" && stream.live == nil && f.synths.count == 1
              && f.synths[0].chunks == ["今天**天气**不错，适合散步。"], "speech still receives only the final reply")
        check(f.store.messages.last?.content == "今天**天气**不错，适合散步。",
              "the settled reply is the conversation's own message, so nothing streams beside it")
        source.stream(operation: 10, "今天**天气**不错，适合")
        check(stream.text == "今天**天气**不错，适合散步。", "a late snapshot of a finished step is ignored")
        f.releasePlayback(); await tick()
        check(stream.text == "今天**天气**不错，适合散步。", "the reply stays after playback ends")

        let recognizers = f.recognizers.count
        try await waitForAgentVoice("listening resumes after the reply") {
            f.voice.snapshot.recognition == .listening && f.recognizers.count > recognizers
        }
        f.speak("第二个问题", start: 400)
        source.emit(.init(type: .turn_started)); source.emit(.init(type: .model_started))
        check(f.store.isGenerating && stream.text == "今天**天气**不错，适合散步。" && stream.live == nil,
              "a new request keeps the previous reply and streams nothing yet")
        source.stream(operation: 12, " \n")
        check(stream.text == "今天**天气**不错，适合散步。", "whitespace is not the first real text")
        source.stream(operation: 12, "我先看看目录。")
        check(stream.text == "我先看看目录。", "the next turn's first real delta replaces the previous reply")
        source.stream(operation: 12, "我先看看目录。", toolCall: true)
        check(stream.text == "今天**天气**不错，适合散步。" && stream.live == nil,
              "text that turns into a tool call is withdrawn")
        source.emit(operation: 12, .init(type: .assistant, message_id: 90, content: "我先看看目录。", final_reply: false))
        source.stream(operation: 12, "我先看看目录。补充")
        check(stream.text == "今天**天气**不错，适合散步。", "a withdrawn step never returns")
        source.stream(operation: 14, "目录里有三个文件")
        check(stream.text == "目录里有三个文件" && stream.live == "目录里有三个文件",
              "the final step streams from a blank bubble")
        source.emit(operation: 14, .init(type: .stopping))
        check(stream.text == "今天**天气**不错，适合散步。" && stream.live == nil,
              "a stopped step keeps no partial reply")

        let otherTurn = AgentStream(turn_id: source.currentTurn + 5, operation_id: 20, text: "别的轮次", tool_call: false)
        source.observeStreamForTest(otherTurn)
        check(stream.text == "今天**天气**不错，适合散步。", "snapshots of another turn are ignored")
    }

    /// The muted bubble follows what speech has actually played: subtitles time each character,
    /// playback frames say how far the audio got, and the text is shown on that same timeline.
    @Test(.tags(.fast)) @MainActor static func agentSpokenReplyTests() async throws {
        _ = NSApplication.shared
        let source = ScriptedVoiceAgent(), f = AgentVoiceFixture(source: source)
        defer { f.shutdown() }
        await f.start(); f.holdPlayback()
        f.voice.toggleSpeakerMute()
        func bubble() -> CompanionBubbleContent {
            CompanionBubbleContent(voice: f.voice.snapshot, spoken: f.voice.spoken, position: f.voice.spokenPosition, notice: nil)
        }
        func shown() -> Bool { CompanionBubbleContent.isShown(voice: f.voice.snapshot, spoken: f.voice.spoken, notice: nil) }
        check(bubble() == .none && !shown(), "listening shows no bubble")
        f.speak("介绍一下")
        source.emit(.init(type: .turn_started)); source.emit(.init(type: .model_started))
        let reply = "## 天气\n\n今天**天气**很好，适合散步。"
        check(bubble() == .none && !shown(), "requesting the model shows no bubble")
        f.audio.playbackFrames = 4800
        source.complete(reply)
        await tick()
        check(f.synths.count == 1 && f.voice.spoken == nil && !shown(),
              "audio that starts before its subtitles shows nothing yet")
        let synth = f.synths[0]
        synth.subtitle([("##", 0), ("天", 0.1), ("气。", 0.3), ("今", 0.9), ("天", 1.1), ("天", 1.3), ("气", 1.5), ("很", 1.7), ("好，", 1.9)])
        check(shown() && f.voice.spoken?.source == reply, "the first subtitle makes the bubble take its place")
        f.audio.playbackFrames = 4800 + 21600
        check(bubble() == .reply(reply, heard: "##天气。今"), "0.9 seconds in, the bubble shows 0.9 seconds of text")
        f.audio.playbackFrames = 4800 + 28800
        check(bubble() == .reply(reply, heard: "##天气。今天"), "1.2 seconds in, the text still tracks the audio, not ahead of it")
        synth.subtitle([("适", 2.3), ("合", 2.5), ("散", 2.7), ("步。", 2.9)])
        f.audio.playbackFrames = 4800 + 43200
        check(bubble() == .reply(reply, heard: "##天气。今天天气很"), "1.8 seconds in, the reply is still within its first sentence")
        f.audio.playbackFrames = 4800 + 64800
        check(bubble() == .reply(reply, heard: "##天气。今天天气很好，适合散"), "later sentences extend the timeline")
        f.releasePlayback(); await tick()
        check(f.voice.spoken?.stoppedAt == .infinity && bubble() == .reply(reply, heard: nil) && shown(),
              "finished playback shows the whole reply and keeps it")

        let recognizers = f.recognizers.count
        try await waitForAgentVoice("listening resumes after the reply") {
            f.voice.snapshot.recognition == .listening && f.recognizers.count > recognizers
        }
        f.holdPlayback()
        f.speak("再说一个", start: 400)
        source.emit(.init(type: .turn_started)); source.emit(.init(type: .model_started))
        check(bubble() == .reply(reply, heard: nil), "the next request keeps the previous reply")
        source.complete("好的，下午见。")
        await tick()
        check(f.synths.count == 2 && bubble() == .reply(reply, heard: nil), "new audio without subtitles keeps the previous reply")
        f.synths[1].subtitle([("好", 0), ("的，", 0.2), ("下", 0.6), ("午", 0.8), ("见。", 1.0)])
        f.audio.playbackFrames += 7200
        check(bubble() == .reply("好的，下午见。", heard: "好的，"), "the next reply's first subtitle replaces the previous one")
        f.audio.playbackFrames += 7200
        check(bubble() == .reply("好的，下午见。", heard: "好的，下"), "the new reply is timed from its own audio, on its own timeline")
        f.audio.playbackFrames -= 7200
        f.voice.stopReply()
        await tick()
        f.audio.playbackFrames = 96000
        check(f.voice.spoken?.stoppedAt == 0.3 && bubble() == .reply("好的，下午见。", heard: "好的，"),
              "an interrupted reply keeps what was heard")
        f.voice.toggleSpeakerMute()
        check(bubble() == .none && !shown(), "an audible reply shows no bubble")
        f.voice.toggleSpeakerMute()

        // A voice that sends no subtitles shows its reply once playback has finished.
        let recovered = f.recognizers.count
        try await waitForAgentVoice("listening resumes after the stop") {
            f.voice.snapshot.recognition == .listening && f.recognizers.count > recovered
        }
        f.speak("第三个问题", start: 800)
        source.emit(.init(type: .turn_started))
        source.complete("没有字幕的回复。")
        await tick()
        check(bubble() == .reply("好的，下午见。", heard: "好的，"), "until playback finishes the previous reply stays")
        f.releasePlayback(); await tick()
        check(bubble() == .reply("没有字幕的回复。", heard: nil) && shown(), "a reply without subtitles appears whole after playback")
        f.voice.end(); await tick()
        check(f.voice.spoken == nil, "ending Live Voice forgets the spoken reply")
    }

    /// While Live Voice runs its conversation is in progress; ending the session makes it unseen.
    @Test(.tags(.fast)) @MainActor static func agentVoiceUnseenTests() async throws {
        _ = NSApplication.shared
        for viewed in [false, true] {
            let source = ScriptedVoiceAgent(), f = AgentVoiceFixture(source: source)
            defer { f.shutdown() }
            f.workspace.isMainWindowVisible = viewed
            await f.start(); f.holdPlayback()
            f.speak("第一轮")
            check(f.store.isGenerating && !f.store.isActivityVisible, "a Live Voice turn keeps its task card folded")
            source.emit(.init(type: .turn_started))
            source.complete("第一轮回复")
            f.releasePlayback()
            let recognizers = f.recognizers.count
            try await waitForAgentVoice("listening resumes") {
                f.voice.snapshot.recognition == .listening && f.recognizers.count > recognizers
            }
            f.speak("第二轮", start: 400)
            source.emit(.init(type: .turn_started))
            source.complete("第二轮回复")
            f.releasePlayback(); await tick()
            let surface = PetSurfacePresentation(hovered: true, composerOpen: false, draft: "",
                activityCount: f.store.activityCount, activitiesCollapsed: f.store.activitiesCollapsed,
                unseenCompleted: f.workspace.unseenCompletedCount, voice: f.voice.snapshot, canStartVoice: false,
                runningTasks: f.workspace.runningTaskCount)
            check(f.workspace.unseenCompletedCount == 0 && !f.store.hasUnseenCompletion && surface.tray != .bell(unseen: 0)
                  && surface.tray != .bell(unseen: 1), "completed Live Voice turns are neither unseen nor shown as a bell")
            f.voice.end(); await tick()
            if viewed {
                check(f.workspace.unseenCompletedCount == 0, "a Live Voice conversation viewed in the main window ends seen")
            } else {
                check(f.workspace.unseenCompletedCount == 1 && f.store.hasUnseenCompletion && f.store.activitiesCollapsed,
                      "ending Live Voice turns its conversation into one unseen completion")
                let bell = PetSurfacePresentation(hovered: true, composerOpen: false, draft: "",
                    activityCount: f.store.activityCount, activitiesCollapsed: f.store.activitiesCollapsed,
                    unseenCompleted: f.workspace.unseenCompletedCount, voice: f.voice.snapshot, canStartVoice: true)
                check(bell.tray == .bell(unseen: 1), "the bell appears with its count once the voice session ends")
                f.workspace.isMainWindowVisible = true
                check(f.workspace.unseenCompletedCount == 0, "viewing the conversation clears it by the existing rule")
            }
        }
        // A session with no completed reply leaves nothing unseen.
        let f = AgentVoiceFixture(source: ScriptedVoiceAgent())
        defer { f.shutdown() }
        await f.start(); f.voice.end(); await tick()
        check(f.workspace.unseenCompletedCount == 0, "an empty Live Voice session creates no unseen item")
    }

    @Test(.tags(.fast)) @MainActor static func agentFinalAudioTests() async throws {
        _ = NSApplication.shared
        for finalFirst in [false, true] {
            let source = ScriptedVoiceAgent(), f = AgentVoiceFixture(source: source)
            defer { f.shutdown() }
            await f.start(); f.holdPlayback(); f.speak("最初的问题")
            let run = f.store.task!.runID
            f.store.lifecycle.send(.reply(run, .progress("中间说明和命令输出")))
            await tick()
            check(f.synths.isEmpty && f.voice.snapshot.recognition == .listening,
                  "intermediate assistant text never starts synthesis or closes ASR")
            var completions: [String] = []
            let subscription = f.store.lifecycle.sink {
                if case .reply(_, .completed(let text)) = $0 { completions.append(text) }
            }
            defer { subscription.cancel() }
            source.complete("今天的天气非常晴朗，适合出门散步。", rawReply: "transport-only final output")
            await tick()
            check(f.synths.count == 1 && f.synths[0].chunks == ["今天的天气非常晴朗，适合出门散步。"]
                  && f.voice.snapshot.replyAudio == .draining(run), "only the final reply is spoken as one synthesis input")
            let finalMessage = f.store.responseMessage!
            check(finalMessage.role == .assistant && f.store.messages.filter { $0.role == .assistant }.count == 1
                  && completions == [finalMessage.content] && f.store.task?.summary == "已完成",
                  "history owns the only final message; completion and speech use its content, summary contains only status")
            source.complete("今天的天气非常晴朗，适合出门散步。")
            await tick()
            check(f.synths.count == 1 && f.synths[0].chunks.count == 1, "duplicate terminal delivery never replays the final")
            check(f.store.messages.filter { $0.role == .assistant } == [finalMessage] && completions.count == 1,
                  "replayed history and finished events preserve message identity and notify completion only once")
            let oldAudio = f.synths[0].callback!, oldRecognizer = f.recognizers[0]
            await f.probe()
            check(f.voice.snapshot.bargeIn == .checking(run) && f.recognizers.count == 2,
                  "final playback retains acoustic barge-in confirmation")
            f.speak("今天的天气非常晴朗", final: true)
            oldRecognizer.emit("迟到的定稿", start: 900, end: 1000, final: true)
            check(source.commands.count == 1 && !f.synths[0].cancelled, "echo and old ASR cannot interrupt or submit")
            f.speak("再看看明天", final: finalFirst)
            check(f.synths[0].cancelled && source.cancels == 0 && f.store.task?.status != .stopped,
                  "confirmed barge-in interrupts only TTS and preserves the completed task")
            if !finalFirst {
                check(source.commands.count == 1 && f.voice.subtitle == "再看看明天", "partial speech is not submitted")
                f.speak("再看看明天")
            }
            f.speak("再看看明天")
            check(source.commands.map(\.0) == ["send_message", "send_message"] && f.store.task?.runID != run
                  && f.voice.snapshot.recognition == .listening, "one final starts the next round after completed playback")
            do { try await oldAudio(Data([1, 2])); check(false, "old audio must be rejected") }
            catch is CancellationError {  }
            f.releasePlayback(); await tick()
            check(f.voice.snapshot.recognition == .listening && f.synths.count == 1,
                  "old playback drain cannot change the new round or replay its predecessor")
        }
        // A final arriving while the user has a partial must preserve that utterance.
        let source = ScriptedVoiceAgent(), f = AgentVoiceFixture(source: source)
        defer { f.shutdown() }
        await f.start(); f.speak("问题"); f.speak("正在补充", start: 300, final: false)
        source.complete("刚返回的最终结果"); await tick()
        check(f.synths.isEmpty && f.voice.subtitle == "正在补充", "a final cannot cut off a follow-up already being spoken")
        f.speak("正在补充", start: 300)
        check(source.commands.count == 2 && source.cancels == 0, "the preserved utterance can start the next round")
    }

    @Test(.tags(.fast)) @MainActor static func agentVoiceStartupAndFailureTests() async throws {
        _ = NSApplication.shared
        do {
            let source = ScriptedVoiceAgent(), f = AgentVoiceFixture(source: source)
            var allowed: CheckedContinuation<Bool, Never>?
            f.permission = { await withCheckedContinuation { allowed = $0 } }
            defer { allowed?.resume(returning: false); f.shutdown() }
            _ = f.conversation
            check(f.store.send("通话前开始的任务"), "the Agent run starts before Live Voice")
            let run = f.store.task!.runID
            await f.start()
            check(allowed != nil && f.voice.snapshot.session == .starting(f.voice.snapshot.session.owner!),
                  "the call waits for microphone permission while the Agent runs")

            source.complete("启动期间完成的最终回复")
            await tick()
            check(f.store.task?.status == .completed && f.synths.isEmpty,
                  "a final received during startup waits for audio activation")
            allowed?.resume(returning: true); allowed = nil
            try await waitForAgentVoice("startup final is spoken") {
                f.synths.first?.chunks == ["启动期间完成的最终回复"]
            }
            f.store.lifecycle.send(.reply(run, .completed("启动期间完成的最终回复")))
            await tick()
            check(f.synths.count == 1,
                  "the deferred final is spoken once after activation")
        }
        for failure in [false, true] {
            let source = ScriptedVoiceAgent(), f = AgentVoiceFixture(source: source)
            var allowed: CheckedContinuation<Bool, Never>?
            f.permission = { await withCheckedContinuation { allowed = $0 } }
            defer { allowed?.resume(returning: false); f.shutdown() }
            _ = f.conversation // Workspace assigns the session ID before the source opens.
            f.store.send("已经运行的任务")
            let run = f.store.task?.runID
            await f.start()
            check(f.workspace.send("权限等待期间补充", conversationID: f.conversation.id)
                  && source.commands.last?.0 == "send_message" && source.cancels == 0,
                  "voice startup preserves an existing task and allows text steering")
            allowed?.resume(returning: true); allowed = nil; await tick()
            check(f.voice.snapshot.recognition == .listening && f.store.task?.runID == run,
                  "activation begins listening during the existing Agent round")
            if failure {
                f.audio.onFailure?("测试录音故障", .deviceChange)
                check(!f.voice.isActive && source.cancels == 0 && f.store.isGenerating
                      && f.voice.snapshot.error?.conversationID == f.conversation.id,
                      "audio failure ends voice and reports its owner without cancelling tools")
            } else {
                f.voice.toggleMute(); f.workspace.stop(conversationID: f.conversation.id)
                source.emit(.init(type: .finished, outcome: .init(status: .interrupted)), cancelled: true)
                await tick()
                check(f.voice.isMuted && f.voice.snapshot.recognition == .off(.muted), "cleanup preserves microphone mute")
                f.voice.toggleMute(); await tick()
                check(f.voice.snapshot.recognition == .listening, "unmute after cleanup restarts recognition")
            }
        }
    }
}

extension VoiceTests {
    /// The Live Voice contract on the native engine, with the real harness and a scripted model:
    /// speech while the Agent works steers the same run, only the final reply is spoken and
    /// exactly once, Stop pauses submission until cleanup, and Continue appends nothing.
    @Test(.tags(.fast)) @MainActor static func nativeAgentVoiceTests() async throws {
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
        let f = AgentVoiceFixture(source: AgentHarness(resolveModel: { model.factory }))
        defer { f.shutdown() }
        var completions: [String] = []
        let subscription = f.store.lifecycle.sink { if case .reply(_, .completed(let text)) = $0 { completions.append(text) } }
        defer { subscription.cancel() }
        await f.start()
        #expect(f.store.usesAgent)
        f.speak("开始检查")
        let run = try #require(f.store.task?.runID)
        try await waitForAgentVoice("model request") { gate.arrivals == 1 }
        #expect(f.voice.snapshot.recognition == .listening, "Recognition stays open during the model request")
        f.speak("补充一", start: 300)
        #expect(f.store.task?.runID == run && f.store.messages.last?.steering == "待处理", "Speech steers the same run")
        gate.open()
        try await waitForAgentVoice("final reply") { !f.store.isGenerating }
        await tick()
        #expect(completions == ["最终回复：开始检查，补充一"] && f.store.responseMessage?.content == completions.first)
        #expect(f.synths.count == 1 && f.synths.first?.chunks == ["最终回复：开始检查，补充一"],
                "Only the final reply is spoken, once; the text before the steering is not")
        #expect(f.store.messages.filter { $0.role == .assistant }.map(\.content) == ["先说一句中间话", "最终回复：开始检查，补充一"])

        // The reply is still being spoken; the next run starts from the composer, as text does during a call.
        #expect(f.workspace.send("再查一次", conversationID: f.conversation.id))
        try await waitForAgentVoice("second run") { f.store.isGenerating && stopGate.arrivals == 1 }
        f.workspace.stop(conversationID: f.conversation.id)
        #expect(f.store.task?.status == .stopping && !f.store.canSubmit)
        #expect(!f.workspace.send("停止期间", conversationID: f.conversation.id), "Nothing starts during cleanup")
        try await waitForAgentVoice("stopped") { f.store.task?.status == .stopped }
        await tick()
        #expect(f.voice.isActive && f.store.canSubmit && f.synths.count == 1, "A stopped turn is not spoken and the call goes on")
        let users = f.store.messages.filter { $0.role == .user }.count
        #expect(f.workspace.retry(conversationID: f.conversation.id))
        try await waitForAgentVoice("continued") { !f.store.isGenerating }
        #expect(f.store.messages.filter { $0.role == .user }.count == users && f.store.responseMessage?.content == "继续后的回复")
    }
}
