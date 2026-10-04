import AppKit
import SwiftUI
import Testing

@MainActor @Suite(.serialized, .tags(.fast)) enum PresentationRules {
    @Test static func testPetSurfacePresentationAndLayout() throws {
        typealias Surface = PetSurfacePresentation
        let owner = VoiceSessionSnapshot.Owner(sessionID: UUID(), conversationID: UUID())
        func surface(hovered: Bool = false, composer: Bool = false, draft: String = "", count: Int = 0,
                     collapsed: Bool = false, unseen: Int = 0, voice: VoiceSessionSnapshot = .init(),
                     canStart: Bool = true, running: Int = 0, sent: Bool = false, connected: UUID? = nil,
                     keptExpanded: Bool = false, peeks: Bool = true) -> Surface {
            Surface(hovered: hovered, composerOpen: composer, draft: draft, activityCount: count,
                    activitiesCollapsed: collapsed, unseenCompleted: unseen, voice: voice, canStartVoice: canStart,
                    runningTasks: running, composerSent: sent, connectedVoiceSession: connected,
                    keepsExpanded: keptExpanded, peeksDraft: peeks)
        }
        #expect(surface().mode == .compact && !surface().showsActions && surface().width == Surface.collapsedSize.width,
                     "Idle pet shows only the light collapsed bar")
        let hovered = surface(hovered: true)
        #expect(hovered.mode == .compact && hovered.showsActions && hovered.tray == .none, "Hover shows ✎ and voice")
        #expect(surface(count: 1).mode == .compact && !surface(count: 1).showsActions
                     && surface(count: 1).tray == .collapse && surface(count: 1).width == Surface.collapsedSize.width,
                     "Without hover an activity still collapses to the light bar")
        #expect(surface(count: 1, collapsed: true, unseen: 3).tray == .bell(unseen: 3), "The bell counts unseen completed tasks")
        #expect(surface(count: 1, collapsed: true).tray == .bell(unseen: 0))
        #expect(surface(unseen: 2).tray == .bell(unseen: 2), "Unseen completions keep the bell without a current activity")
        #expect(surface(count: 1, unseen: 1, running: 2).badge == .completed(1)
                     && surface(count: 1, running: 2).badge == .running(2)
                     && surface(count: 1, collapsed: true, unseen: 1).badge == .completed(1)
                     && surface(count: 1).badge == .none, "The bell reports unseen completions first, running tasks otherwise")
        #expect(surface(count: 1, unseen: 2).tray == .collapse && surface(count: 1, collapsed: true, unseen: 2).tray == .bell(unseen: 2),
                     "An expanded card shows ⌃; a collapsed one shows the bell with its count")
        let running = surface(count: 1, running: 1)
        #expect(running.showsStatus && running.width == 2 * Surface.circle + Surface.gap,
                     "Without hover, running tasks keep Live Voice and the bell")
        #expect(!surface(count: 1, collapsed: true, unseen: 1).showsStatus, "Finished tasks collapse to the light bar")
        let kept = surface(count: 1, unseen: 1, keptExpanded: true)
        #expect(kept.showsActions && !kept.isCollapsedBar && kept.tray == .collapse,
                "A showing card keeps the controls and the collapse action without hover")
        #expect(kept == surface(hovered: true, count: 1, unseen: 1, keptExpanded: true),
                "Pointer enter and exit cannot change the kept presentation")
        #expect(surface(count: 1, collapsed: true, unseen: 1).isCollapsedBar,
                "With only the bell left the controls follow hover again")
        #expect(!surface(composer: true, count: 1, running: 1).showsStatus
                     && surface(composer: true, count: 1, running: 1).width == Surface.composerWidth,
                     "A freshly opened composer stays in focus mode")
        let sentComposer = surface(composer: true, count: 1, running: 1, sent: true)
        #expect(sentComposer.showsStatus && sentComposer.width == Surface.composerWidth + 2 * (Surface.gap + Surface.circle),
                     "After a send the composer shows Live Voice and the bell beside it")
        #expect(surface(hovered: true, unseen: 2).width == 2 * Surface.pillPadding + 3 * Surface.segment,
                     "Hover strip holds text entry, Live Voice and the bell")
        let drafted = surface(draft: "  第一行草稿\n第二行")
        #expect(drafted.isCollapsedBar && drafted.showsDraftLine && drafted.draftPreview == "第一行草稿"
                && drafted.collapsedSize == Surface.draftLineSize && drafted.width == Surface.draftLineSize.width,
                "A closed composer's draft collapses to one line of its start")
        #expect(surface(draft: " \n第二行").draftPreview == "第二行", "The line starts at the draft's first text")
        #expect(Surface.draftLineSize.height == ceil(NSFont.preferredFont(forTextStyle: .caption2).defaultLineHeight)
                + 2 * Surface.draftLinePadding.height && Surface.draftLineSize.height <= Surface.circle,
                "The line is just tall enough for the smallest text style and fits the strip's row")
        for blank in ["", " ", " \n\t"] {
            let collapsed = surface(draft: blank)
            #expect(!collapsed.showsDraftLine && collapsed.collapsedSize == Surface.collapsedSize
                    && collapsed.width == Surface.collapsedSize.width, "A blank draft keeps the hairline: \(blank.debugDescription)")
        }
        #expect(!surface(hovered: true, draft: "草稿").showsDraftLine && surface(composer: true, draft: "草稿").draftPreview == nil
                && !surface(draft: "草稿", count: 1, running: 1).showsDraftLine,
                "Hover, an open composer and the status circles replace the line")
        let peek = surface(hovered: true, draft: "草稿", unseen: 1)
        #expect(peek.peeksComposer && peek.mode == .composer && !peek.showsStatus && peek.width == Surface.composerWidth,
                "Hovering the draft's line opens the composer, not the pill")
        #expect(!surface(draft: "草稿").peeksComposer && !surface(composer: true, draft: "草稿").peeksComposer,
                "Only hover peeks; an open composer is simply open")
        let blankHover = surface(hovered: true, draft: " \n")
        #expect(!blankHover.peeksComposer && blankHover.mode == .compact && blankHover.showsActions,
                "A blank draft still hovers to the pill")
        let waiting = surface(hovered: true, draft: "草稿", peeks: false)
        #expect(waiting.showsDraftLine && !waiting.showsActions && waiting.width == Surface.draftLineSize.width,
                "Closed under the pointer, the line waits for the pointer to leave before it opens again")
        let busy = surface(hovered: true, draft: "草稿", count: 1, running: 1)
        #expect(!busy.peeksComposer && busy.mode == .compact && busy.showsActions,
                "Where the strip does not rest on the line, hover keeps the pill")
        #expect(surface(draft: "草稿", unseen: 1).showsDraftLine, "The line keeps the completion green")
        let composer = surface(composer: true, draft: " \n")
        #expect(composer.mode == .composer && !composer.canSend, "Whitespace cannot be sent")
        #expect(surface(composer: true, draft: "你好").canSend)
        var voice = VoiceSessionSnapshot()
        voice.session = .starting(owner)
        let starting = surface(voice: voice)
        #expect(starting.mode == .compact && starting.voiceConnecting && !starting.muteEnabled
                     && starting.showsStatus && starting.tray == .none && starting.width == Surface.circle,
                     "Starting Live Voice is shown by its own button, not the voice bar")
        #expect(surface(hovered: true, count: 1, collapsed: true, unseen: 2, voice: voice).width
                     == 2 * Surface.pillPadding + 2 * Surface.segment, "The hover strip swaps Live Voice for the connecting button")
        voice.session = .active(owner)
        #expect(surface(voice: voice).voiceConnecting && surface(voice: voice).mode == .compact,
                     "Audio has started but recognition has not connected yet")
        voice.recognition = .connecting
        #expect(surface(voice: voice).voiceConnecting && surface(voice: voice).mode == .compact)
        voice.recognition = .listening
        #expect(!surface(voice: voice).voiceConnecting && surface(voice: voice).mode == .voice
                     && surface(voice: voice).voice == .listening && surface(voice: voice).muteEnabled,
                     "Once connected the formal voice bar appears")
        voice.recognition = .connecting
        #expect(surface(voice: voice, connected: owner.sessionID).mode == .voice
                     && !surface(voice: voice, connected: owner.sessionID).voiceConnecting,
                     "A session that connected keeps the voice bar while recognition reconnects")
        #expect(surface(voice: voice, connected: UUID()).voiceConnecting, "Another session's connection does not count")
        voice.recognition = .listening
        #expect(surface(count: 1, collapsed: true, unseen: 2, voice: voice, running: 1).tray == .none
                     && surface(hovered: true, count: 1, unseen: 2, voice: voice).tray == .collapse,
                     "Live Voice shows no bell; an expanded card keeps its ⌃")
        voice.agentActivity = "正在请求模型…"
        #expect(surface(voice: voice).voice == .thinking)
        voice.replyAudio = .playing(UUID())
        #expect(surface(voice: voice).voice == .speaking)
        voice.microphone = .muted; voice.speakerMuted = true
        #expect(surface(voice: voice).micMuted && surface(voice: voice).speakerMuted)
        #expect(surface(composer: true, voice: voice).mode == .composer, "Composing takes precedence over the voice bar")
        #expect(surface(composer: true, count: 1, collapsed: true, unseen: 1, voice: voice).width == Surface.composerWidth
                     && surface(composer: true).width == Surface.composerWidth, "Composing hides voice and tray controls")
        voice.session = .ending(owner)
        #expect(surface(voice: voice).voice == .ending && surface(voice: voice).mode == .voice)
        let widths = [surface(hovered: true), surface(hovered: true, count: 1), surface(composer: true, count: 1, sent: true),
                      surface(count: 1, voice: { var active = VoiceSessionSnapshot(); active.session = .active(owner); return active }())]
        #expect(widths.allSatisfy { $0.width <= Surface.canvasWidth }, "Every mode fits the fixed controls canvas")

        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let petSize = CGSize(width: 112, height: 112)
        for origin in [CGPoint(x: -50, y: -50), CGPoint(x: 1400, y: -50), CGPoint(x: -50, y: 880), CGPoint(x: 1400, y: 880), CGPoint(x: 660, y: 400)] {
            let frames = CompanionLayout.place(pet: CGRect(origin: origin, size: petSize), in: screen, expanded: false)
            let inset = screen.insetBy(dx: 8, dy: 8)
            #expect(inset.contains(frames.pet) && inset.contains(frames.controls), "Pet and controls stay on screen at \(origin)")
            #expect(frames.controls.maxY == frames.pet.minY, "Controls sit directly below the pet")
            let line = frames.collapsedBar(size: Surface.draftLineSize)
            #expect(line.size == Surface.draftLineSize && frames.controlsContent(width: line.width).minX == line.minX
                    && line.maxY == frames.controls.maxY - Surface.collapsedTop && frames.controls.contains(line),
                    "The draft's line is where the strip draws it, inside the controls canvas")
            for width in widths.map({ $0.width }) {
                let content = frames.controlsContent(width: width)
                let inset = PetSurfacePresentation.canvasInset
                #expect(frames.controls.insetBy(dx: inset, dy: 0).contains(content), "Controls keep room for their glow in the canvas")
                #expect(abs(content.midX - frames.pet.midX) < 0.5 || abs(content.minX - frames.controls.minX - inset) < 0.5
                             || abs(frames.controls.maxX - inset - content.maxX) < 0.5, "Content centers under the pet unless clamped")
            }
            // The activity frame includes 12 pt of transparent padding around the visible capsule.
            let capsule = frames.activity.insetBy(dx: 12, dy: 12)
            #expect(frames.activityCanvas.insetBy(dx: CompanionLayout.activityPadding,
                                                  dy: CompanionLayout.activityPadding) == capsule,
                    "Larger shadow padding preserves the visible card's position")
            #expect(!capsule.intersects(frames.pet) && !capsule.intersects(frames.controls),
                         "The activity never covers the pet or its controls")
        }

        let panel = CompanionSurface(title: "Activity padding", content: Color.clear)
        defer { panel.close() }
        panel.setFrame(CGRect(x: 400, y: 300, width: 426, height: 152), display: false)
        #expect(!panel.isOpaque && panel.backgroundColor == .clear && !panel.hasShadow)
        #expect(panel.contentView?.isOpaque == false, "The hosting view cannot paint a rectangular background")
        let content = panel.frame.insetBy(dx: CompanionLayout.activityPadding, dy: CompanionLayout.activityPadding)
        let closeFrames = [CGRect(x: content.minX - 4, y: content.maxY - 16, width: 20, height: 20)]
        for point in [CGPoint(x: panel.frame.minX + 1, y: content.midY),
                      CGPoint(x: panel.frame.maxX - 1, y: content.midY),
                      CGPoint(x: content.midX, y: panel.frame.minY + 1),
                      CGPoint(x: content.midX, y: panel.frame.maxY - 1)] {
            panel.updateMousePassthrough(at: point, contentInset: CompanionLayout.activityPadding, closeButtonFrames: closeFrames)
            #expect(panel.ignoresMouseEvents, "The transparent margins pass mouse events to the desktop")
        }
        panel.updateMousePassthrough(at: CGPoint(x: content.midX, y: content.midY),
                                     contentInset: CompanionLayout.activityPadding, closeButtonFrames: closeFrames)
        #expect(!panel.ignoresMouseEvents, "The card still accepts clicks")
        let closePoint = CGPoint(x: content.minX - 2, y: content.maxY + 2)
        panel.updateMousePassthrough(at: closePoint, contentInset: CompanionLayout.activityPadding, closeButtonFrames: closeFrames)
        #expect(!panel.ignoresMouseEvents, "The protruding close button still accepts clicks")
        panel.updateMousePassthrough(at: closePoint, contentInset: CompanionLayout.activityPadding, closeButtonFrames: [])
        #expect(panel.ignoresMouseEvents, "An absent close button does not leave an invisible hit target")
    }

    @Test static func testCompanionBubblePresentationAndLayout() throws {
        typealias Bubble = CompanionBubbleContent
        let owner = VoiceSessionSnapshot.Owner(sessionID: UUID(), conversationID: UUID())
        let words: [VoiceSubtitle.Word] = [("今", 0.0), ("天", 0.2), ("天", 0.4), ("气", 0.6), ("好。", 0.8)]
            .map { .init(word: $0.0, startTime: $0.1) }
        let spoken = SpokenReply(runID: UUID(), source: "今天**天气**好。", words: words)
        func bubble(_ voice: VoiceSessionSnapshot, spoken: SpokenReply? = spoken, at position: TimeInterval = 10,
                    notice: String? = nil) -> Bubble {
            Bubble(voice: voice, spoken: spoken, position: position, notice: notice)
        }
        func shown(_ voice: VoiceSessionSnapshot, spoken: SpokenReply? = spoken, notice: String? = nil) -> Bool {
            Bubble.isShown(voice: voice, spoken: spoken, notice: notice)
        }
        var voice = VoiceSessionSnapshot()
        #expect(bubble(voice) == .none && bubble(voice, notice: "语音失败") == .notice("语音失败")
                     && !shown(voice) && shown(voice, notice: "语音失败"), "Without a session only errors appear")
        voice.session = .starting(owner); voice.speakerMuted = true
        #expect(bubble(voice) == .none && !shown(voice), "Connecting shows no bubble; the Live Voice button reports it")
        voice.session = .active(owner); voice.recognition = .listening
        #expect(bubble(voice, spoken: nil) == .none && !shown(voice, spoken: nil),
                     "Listening, the user's speech and the model request show nothing until speech is played")
        voice.subtitle = "我在说话"; voice.agentActivity = "正在请求模型…"; voice.replyAudio = .preparing(UUID())
        #expect(bubble(voice, spoken: nil) == .none && !shown(voice, spoken: nil), "Transcript, request and preparation never show")
        let silent = SpokenReply(runID: UUID(), source: "回复")
        #expect(bubble(voice, spoken: silent) == .none && !shown(voice, spoken: silent),
                     "Audio without subtitles yet shows nothing")

        // With the speaker muted the bubble follows what playback has reached.
        voice.replyAudio = .playing(UUID())
        #expect(bubble(voice, at: 0) == .reply("今天**天气**好。", heard: "今") && shown(voice),
                     "The first played character opens the bubble")
        #expect(bubble(voice, at: 0.5) == .reply("今天**天气**好。", heard: "今天天"),
                     "Text follows the subtitle timeline: only words started by 0.5s are shown")
        #expect(bubble(voice, at: 0.75) == .reply("今天**天气**好。", heard: "今天天气"),
                     "The word at 0.6s appears when playback reaches it, not 1.5× earlier")
        #expect(bubble(voice, at: 10) == .reply("今天**天气**好。", heard: "今天天气好。"), "All words once played")
        var stopped = spoken; stopped.stoppedAt = 0.3
        #expect(bubble(voice, spoken: stopped, at: 10) == .reply("今天**天气**好。", heard: "今天"),
                     "An interrupted reply keeps what was shown, up to where the audio stopped")
        stopped.stoppedAt = .infinity
        #expect(bubble(voice, spoken: stopped, at: 0) == .reply("今天**天气**好。", heard: nil) && shown(voice, spoken: stopped),
                     "A finished reply stays whole")
        voice.speakerMuted = false
        #expect(bubble(voice) == .none && !shown(voice), "An audible reply shows no text")
        #expect(bubble(voice, notice: "麦克风不可用") == .notice("麦克风不可用"), "Errors show while the reply is audible")
        voice.speakerMuted = true
        #expect(bubble(voice, notice: "麦克风不可用") == .notice("麦克风不可用"), "Errors outrank the muted reply")

        // Heard speech maps onto the rendered Markdown, skipping unvoiced markers.
        let heardRendered = CompanionBubble.renderedReply("## 结果\n\n- **构建**通过，运行 `swift test`：3 项")
        let plain = String(heardRendered.characters)
        #expect(plain == "结果\n• 构建通过，运行 swift test：3 项")
        #expect(SpokenReply.coveredCount(of: plain, heard: "") == 0, "Nothing heard covers nothing")
        #expect(SpokenReply.coveredCount(of: plain, heard: "##结果。-构建") == "结果\n• 构建".count,
                     "Markdown markers voiced as symbols are skipped")
        #expect(SpokenReply.coveredCount(of: plain, heard: "结果构建通过，") == "结果\n• 构建通过，".count,
                     "Punctuation right after a heard character is shown with it")
        #expect(SpokenReply.coveredCount(of: plain, heard: "结果构建通过运行swifttest三") == "结果\n• 构建通过，运行 swift test：".count
                     && SpokenReply.coveredCount(of: plain, heard: "结果构建通过运行swifttest三项") == plain.count,
                     "Speech that normalizes a character (3 read as 三) skips it; the next spoken character still matches")
        let prefix = AttributedString(heardRendered[heardRendered.startIndex..<heardRendered.characters.index(heardRendered.startIndex, offsetBy: "结果\n• 构建".count)])
        #expect(prefix.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
                                             && String(prefix[$0.range].characters) == "构建" }, "The heard prefix keeps Markdown styling")

        // The reply stream: rounds, withdrawn tool steps and late snapshots.
        let stream = AssistantReplyStream()
        #expect(stream.live == nil, "Nothing is being written before the first delta")
        stream.receive(operationID: 3, text: "第一轮", toolCall: false)
        stream.receive(operationID: 3, text: "第一轮回复", toolCall: false)
        #expect(stream.live == "第一轮回复", "Live text follows the step being written")
        stream.complete(operationID: 3, text: "第一轮回复完成")
        #expect(stream.text == "第一轮回复完成", "The final reply settles the round")
        #expect(stream.live == nil, "A settled step leaves its text to the conversation")
        stream.receive(operationID: 5, text: "\n ", toolCall: false)
        #expect(stream.text == "第一轮回复完成" && stream.live == nil, "Whitespace does not start the next round")
        stream.receive(operationID: 5, text: "先看看", toolCall: false)
        #expect(stream.text == "先看看" && stream.live == "先看看",
                     "The next round's first real delta clears the previous reply")
        stream.receive(operationID: 5, text: "先看看", toolCall: true)
        #expect(stream.text == "第一轮回复完成" && stream.live == nil,
                     "A tool call withdraws its step and restores the previous reply")
        stream.receive(operationID: 7, text: "结果", toolCall: false)
        stream.withdraw(7)
        stream.receive(operationID: 7, text: "结果更多", toolCall: false)
        #expect(stream.text == "第一轮回复完成" && stream.live == nil, "A withdrawn step never returns")
        stream.receive(operationID: 9, text: "下一步", toolCall: false)
        stream.withdraw(11)
        #expect(stream.live == nil, "Settling past the written step also retires its live text")
        stream.complete(operationID: 13, text: "未流式的最终回复")
        #expect(stream.text == "未流式的最终回复" && stream.live == nil,
                     "A reply without deltas still arrives when it completes")
        stream.receive(operationID: 15, text: "半截", toolCall: false)
        #expect(stream.live == "半截", "A new round writes again")
        stream.abandon()
        #expect(stream.text == "未流式的最终回复" && stream.live == nil, "A stopped round keeps no partial reply")

        // The reply renders Markdown through the chat's parser instead of showing its syntax.
        let rendered = CompanionBubble.renderedReply("先看 **重点**，运行 `ls -la`：\n\n- 第一项\n- 第二项")
        #expect(String(rendered.characters) == "先看 重点，运行 ls -la：\n• 第一项\n• 第二项",
                     "Reply Markdown drops its syntax and keeps list markers")
        #expect(rendered.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
                                              && String(rendered[$0.range].characters) == "重点" }, "Bold renders as strong emphasis")
        #expect(rendered.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true && $0.font != nil
                                              && String(rendered[$0.range].characters) == "ls -la" }, "Inline code renders monospaced")

        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let inset = screen.insetBy(dx: 8, dy: 8)
        let petSize = CGSize(width: 112, height: 112)
        for origin in [CGPoint(x: -50, y: -50), CGPoint(x: 1400, y: -50), CGPoint(x: -50, y: 880), CGPoint(x: 1400, y: 880), CGPoint(x: 660, y: 400)] {
            for expanded in [false, true] {
                let pet = CGRect(origin: origin, size: petSize)
                let plain = CompanionLayout.place(pet: pet, in: screen, expanded: expanded)
                #expect(plain.bubble == .zero, "No bubble room is reserved without a voice session or notice")
                let frames = CompanionLayout.place(pet: pet, in: screen, expanded: expanded, bubble: true)
                let capsule = frames.activity.insetBy(dx: 12, dy: 12)
                #expect(frames.pet == plain.pet && frames.controls == plain.controls, "The bubble never moves the pet or its controls")
                #expect(inset.contains(frames.bubble) && inset.contains(capsule), "Bubble and card stay on screen at \(origin)")
                #expect(!frames.bubble.intersects(frames.pet) && !frames.bubble.intersects(frames.controls)
                             && !frames.bubble.intersects(capsule), "The bubble overlaps neither the pet, its controls nor the card")
                #expect(frames.isActivityBelowPet == plain.isActivityBelowPet
                             && (frames.isActivityBelowPet ? capsule.maxY <= frames.bubble.minY && frames.bubble.maxY <= frames.controls.minY
                                                           : frames.pet.maxY <= frames.bubble.minY && frames.bubble.maxY <= capsule.minY),
                             "The bubble sits between the pet and its card")
            }
        }
    }
}
