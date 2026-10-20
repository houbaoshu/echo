import AppKit
import SwiftUI

struct WorkspaceConversationView: View {
    var workspace: WorkspaceStore
    /// Observed here, not in `ConversationView`: a planet swap republishes `active`, and this is
    /// the view that has to notice and pass the new sprite down.
    var planets: PlanetStore
    var body: some View {
        VStack(spacing: 0) {
            if let notice = workspace.persistenceNotice {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(notice).textSelection(.enabled)
                    Spacer()
                    Button("重试保存") { workspace.persistenceNotice = nil; workspace.flush() }
                    Button(role: .close) { workspace.persistenceNotice = nil } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("关闭保存提示")
                }.font(WorkspaceStyle.body).padding(12).background(WorkspaceStyle.warningFill)
            }
            if let conversation = workspace.selected {
                ConversationView(store: conversation.store, workspace: workspace, voice: workspace.voice, dictation: workspace.dictation,
                    planet: planets.active,
                    startDictation: { workspace.dictation.start(conversation: conversation) },
                    focusRequest: workspace.composerFocusID == conversation.id ? workspace.composerFocusRequest : 0,
                    startVoice: { workspace.startVoice(conversationID: conversation.id) },
                    conversationID: conversation.id,
                    send: { workspace.sendMainMessage(conversationID: conversation.id) },
                    stop: { workspace.stop(conversationID: conversation.id) },
                    retry: { workspace.retry(conversationID: conversation.id) }).id(conversation.id)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
    }
}

struct ConversationView: View {
    var store: TaskStore
    var workspace: WorkspaceStore? = nil
    var voice: VoiceSessionController
    var dictation: DictationController
    /// The Live Voice planet, resolved by `PlanetStore`; nil outside a voice session.
    var planet: PetStore?
    var startDictation: () -> Void
    var focusRequest = 0
    var startVoice: () -> Void
    let conversationID: UUID
    let send: () -> Void
    let stop: () -> Void
    let retry: () -> Void
    @State private var followTail = true
    @State private var userScrolling = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The transcript is one of the window's focus stops, so it carries the state a
    /// focused scroll area needs: where it is, and how to move.
    @State private var scrollPosition = ScrollPosition()
    @State private var transcriptGeometry = TranscriptGeometry()
    /// Where the toolbar and the composer bar float over the transcript, and the heights the
    /// fade under them is cut to.
    @State private var transcriptInsets = EdgeInsets()
    /// The column a legacy scroller takes beside the chat, which centres in what is left. The
    /// bar under it has no scroller, so it leaves the same column, or the card would sit half
    /// a scroller to the right of the chat.
    @State private var scrollerWidth: CGFloat = 0
    @State private var cardHeight: CGFloat = 0
    /// The text column's width and the transcript's height, which is the window's: the room a
    /// generated image has.
    @State private var columnWidth: CGFloat = 760
    @State private var transcriptHeight: CGFloat = 600
    /// The captions between the bar's top and the card's: the bar is 8pt of padding on either
    /// side of the card, and 8pt of spacing above it once there is anything to space from.
    private var captionsHeight: CGFloat { max(0, transcriptInsets.bottom - cardHeight - 16 - 8) }
    /// The planet's sprite frame. The reference draws its orb 91pt across above the composer;
    /// `scaledToFit` on a 192x208 frame whose planet spans 175x173 shows ~0.83 of the frame, so
    /// the frame is sized up to land the visible disc there.
    private static let planetSize: CGFloat = 110
    /// What the transcript's key handling needs to know about the scroll area. Read from a
    /// second geometry observer so the tail-following one above stays exactly as it was.
    struct TranscriptGeometry: Equatable {
        var visible: CGRect = .zero
        var contentHeight: CGFloat = 0
        /// Where the scroll view is, and how far it can go, in the coordinates
        /// `ScrollPosition.scrollTo(y:)` takes. Those start at the top of the content with
        /// the toolbar's inset already cleared, while `visibleRect` and `contentOffset`
        /// start above it, under the toolbar: mixing the two misses by the inset.
        var offset: CGFloat = 0
        var maxOffset: CGFloat = 0
        init() {}
        init(_ geometry: ScrollGeometry) {
            // Less the composer bar floating over the bottom inset, which hides what is under it.
            visible = geometry.visibleRect
            visible.size.height -= geometry.contentInsets.bottom
            contentHeight = geometry.contentSize.height
            offset = geometry.contentOffset.y + geometry.contentInsets.top
            maxOffset = max(0, geometry.contentSize.height - geometry.containerSize.height)
        }
        func target(by delta: CGFloat) -> CGFloat { min(max(0, offset + delta), maxOffset) }
    }
    var body: some View {
        // Grouped once, rather than filtering every tool for each realized row.
        let tools = Dictionary(grouping: store.tools, by: \.afterMessageID)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                ForEach(store.messages) { message in
                    HStack(alignment: .top) {
                        if message.role == .user { Spacer(minLength: 44) }
                        ConversationMessageView(message: message,
                            retry: message.id == store.messages.last?.id && store.canRetry ? retry : nil,
                            showsProgress: !isVoiceOwner)
                        if message.role == .assistant { Spacer(minLength: 0) }
                    }.id(message.id)
                    ForEach(tools[message.id] ?? []) { tool in
                        toolCard(tool).id("tool.\(tool.turnID).\(tool.id)")
                    }
                }
                ForEach(tools[nil] ?? []) { tool in toolCard(tool) }
                // What is being said, in the place what was said will keep. A spoken
                // follow-up becomes a message in `store.messages`, which is drawn above
                // the stream, so the words wait here rather than below the reply — being
                // committed then moves nothing.
                SpokenDraftView(text: isVoiceOwner ? voice.subtitle : "")
                // The reply as it is written, until the projected message carries the text.
                StreamingReplyView(stream: store.replyStream, showsProgress: !isVoiceOwner)
                // The planet floats over the bottom of the transcript, and the spoken draft
                // forms at the very tail. Reserving its height here is what keeps the words
                // being said from sitting underneath it.
                if isVoiceOwner { Color.clear.frame(height: Self.planetSize + 16) }
            }.frame(maxWidth: 760)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { columnWidth = $0 }
                .padding(.horizontal, 28).padding(.top, 32).padding(.bottom, 20)
                .frame(maxWidth: .infinity)
        }
        // Leave short conversations at the top; .alignment would pin them to the composer.
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .onScrollPhaseChange { _, phase in
            userScrolling = phase != .idle
            // A user gesture disarms the native anchor. Returning near the bottom
            // must re-arm it once the gesture ends, without fighting the finger.
            if phase == .idle && followTail { returnToTail() }
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            // The visible rect runs on under the composer bar, which is the bottom inset.
            geometry.contentSize.height + geometry.contentInsets.bottom - geometry.visibleRect.maxY < 60
        } action: { _, nearBottom in
            if userScrolling { followTail = nearBottom }
        }
        .onScrollGeometryChange(for: TranscriptGeometry.self) { geometry in
            TranscriptGeometry(geometry)
        } action: { previous, value in
            transcriptGeometry = value
            // macOS 27 misses the first growth from fitting content to overflow;
            // later growth follows normally. Re-arm at that boundary only, so a
            // one-shot reply reaches the tail without pulling someone out of history.
            if followTail && !userScrolling,
               previous.contentHeight <= previous.visible.height,
               value.contentHeight > value.visible.height { returnToTail() }
        }
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: EdgeInsets.self) { $0.contentInsets } action: { transcriptInsets = $1 }
        // The window's height: the transcript runs on under the toolbar and the composer bar.
        .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.height + $0.contentInsets.top + $0.contentInsets.bottom } action: {
            transcriptHeight = $1
        }
        .onScrollGeometryChange(for: CGFloat.self) { max(0, $0.containerSize.width - $0.contentSize.width) } action: {
            scrollerWidth = $1
        }
        .mask { transcriptFade }
        // The chat is focusable the way a control is, not the way a text field is: it
        // takes focus only through macOS Keyboard Navigation, so a click leaves the
        // composer's focus alone, and with Keyboard Navigation off Tab passes it by.
        // SwiftUI builds a real key view for it and AppKit places it geometrically,
        // with no traversal code of Echo's own.
        .focusable(interactions: .activate)
        // That key view is NOT inside the scroll view, so scrollPageDown: and
        // friends reach nobody. SwiftUI's own path is the one that works.
        .onKeyPress(keys: [.upArrow, .downArrow, .pageUp, .pageDown, .home, .end]) { transcriptKey($0) }
        .accessibilityIdentifier("conversation.transcript")
        .accessibilityLabel("聊天记录")
        .overlay(alignment: .bottom) {
            if isVoiceOwner {
                VoicePlanet(store: planet, indicator: PetSurfacePresentation.indicator(for: voice.snapshot),
                            muted: voice.isMuted, size: Self.planetSize)
                    // No padding below: the block below already opens with 8pt, and the sprite
                    // carries ~10pt of its own transparent skirt, which together make the reference's 16pt.
                    // On the card's centre line, clear of a legacy scroller's column.
                    .padding(.trailing, scrollerWidth)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if !followTail {
                // The arrow alone on a glass circle, as other chat apps draw it: the labelled
                // bordered pill, with almost no fill, laid its words over the chat's.
                Button { returnToTail() } label: {
                    Image(systemName: "arrow.down").font(.body.weight(.semibold)).frame(width: 20, height: 20)
                }.buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large)
                    .help("回到最新消息").accessibilityLabel("回到最新消息").padding(8)
                    // Clear the planet rather than landing on top of it.
                    .padding(.bottom, isVoiceOwner ? Self.planetSize + 12 : 0)
                    .padding(.trailing, scrollerWidth)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isVoiceOwner)
        // The block floats over the chat, which scrolls on underneath it: the bar's height is
        // the transcript's bottom inset, so the tail still comes to rest above the composer.
        // An inset, not a safe area bar: a bar's scroll edge effect frosts the whole bar and
        // rules a line along its top under anything not on glass, even over a short chat, and
        // the fade below already does what the edge effect was for.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                // The running summary is what the transcript cannot show: which step the
                // task is on, why it stopped, what failed. A completed task has already
                // said so with its reply, so the row goes away instead of reading 已完成.
                // Live Voice narrates its own turn, so while it owns the chat the row
                // keeps only what the voice cannot say: why a task stopped, and how to
                // continue it.
                if let task = store.task, task.status != .completed,
                   !(isVoiceOwner && store.isGenerating) {
                    HStack {
                        if store.isGenerating { ProgressView().controlSize(.small) }
                        Text(task.summary).font(WorkspaceStyle.caption).textSelection(.enabled)
                        Spacer()
                        if store.canRetry { Button("继续处理", action: retry) }
                    }
                }
                if let notice = store.notice ?? store.agentLoadError {
                    Text(notice).font(WorkspaceStyle.caption).foregroundStyle(WorkspaceStyle.warning).textSelection(.enabled)
                }
                if let workspace, workspace.canAssociateProject(conversationID: conversationID) {
                    ConversationProjectPicker(workspace: workspace, conversationID: conversationID)
                }
                ConversationComposer(store: store, workspace: workspace, voice: voice, dictation: dictation,
                                     focusRequest: focusRequest, conversationID: conversationID, startDictation: startDictation,
                                     startVoice: startVoice, send: send, stop: stop, retry: retry)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardHeight = $0 }
            }
            // 16pt wider than the chat on either side, the card's own inset, so the draft lines
            // up with the chat and what scrolls behind the card never shows past its edges.
            .frame(maxWidth: 792).padding(.horizontal, 12).padding(.bottom, 8).padding(.top, 8)
            .padding(.trailing, scrollerWidth)
            .frame(maxWidth: .infinity)
        }
    }
    /// The transcript's mask. The chat fades where things float over it rather than running
    /// sharp into them: under the toolbar (the titlebar is transparent, which leaves AppKit no
    /// pocket to frost it, and an opaque one rules a line under the toolbar), behind the
    /// captions above the card, and through the gap under the card. No system edge effect does
    /// this here: `.soft` changed nothing at the top, and a bottom bar's is a frosted strip.
    private var transcriptFade: some View {
        let behindCaptions = 0.05
        return VStack(spacing: 0) {
            // Gone behind the title and buttons, back by 12pt under the toolbar, which the
            // first message clears by 32pt at the top of the chat.
            LinearGradient(stops: [.init(color: .clear, location: 0.55), .init(color: .black, location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: transcriptInsets.top + 12)
            Color.black
            if captionsHeight > 0 {
                // From 12pt above the bar, clear of where the tail comes to rest 20pt above it,
                // down to the captions; back in under the card's glass, which hides the seam.
                LinearGradient(colors: [.black, .black.opacity(behindCaptions)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 20)
                Color.black.opacity(behindCaptions).frame(height: captionsHeight + 8)
                LinearGradient(colors: [.black.opacity(behindCaptions), .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: 24)
                Color.black.frame(height: max(0, cardHeight - 40))
            } else {
                // The card stands 8pt above the window's edge, and the fade starts 16pt up inside it.
                Color.black.frame(height: max(0, cardHeight - 16))
            }
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 24)
        }.ignoresSafeArea()
    }
    /// The keys a focused scroll area answers on macOS: arrows by a line, Page Up / Page
    /// Down by a screenful, Home / End and ⌘↑ / ⌘↓ to the ends.
    private func transcriptKey(_ press: KeyPress) -> KeyPress.Result {
        let page = max(40, transcriptGeometry.visible.height - 40)
        // One comfortable line of chat, matching the transcript's own body metrics.
        let line = WorkspaceStyle.bodySize * 3
        switch press.key {
        case .home: scrollTranscript(toBottom: false)
        case .end: scrollTranscript(toBottom: true)
        case .upArrow where press.modifiers.contains(.command): scrollTranscript(toBottom: false)
        case .downArrow where press.modifiers.contains(.command): scrollTranscript(toBottom: true)
        case .upArrow: scrollTranscript(by: -line)
        case .downArrow: scrollTranscript(by: line)
        case .pageUp: scrollTranscript(by: -page)
        case .pageDown: scrollTranscript(by: page)
        default: return .ignored
        }
        return .handled
    }
    private func scrollTranscript(by delta: CGFloat) {
        let target = transcriptGeometry.target(by: delta)
        // A keyboard move to the bottom re-arms the native anchor too.
        if target >= transcriptGeometry.maxOffset - 1 { returnToTail() }
        else {
            followTail = false
            scrollPosition.scrollTo(y: target)
        }
    }
    private func scrollTranscript(toBottom: Bool) {
        if toBottom { returnToTail() }
        else {
            followTail = false
            scrollPosition.scrollTo(edge: .top)
        }
    }
    private func returnToTail() {
        followTail = true
        scrollPosition.scrollTo(edge: .bottom)
    }
    private var isVoiceOwner: Bool { voice.conversationID == conversationID }
    /// A tool's card; a generated image follows its card, shown in the chat rather than on it.
    @ViewBuilder private func toolCard(_ tool: AgentToolRecord) -> some View {
        let card = AgentToolView(tool: tool, undo: store.offersUndo(tool) ? { store.undo(tool.id) } : nil, canUndo: store.canUndo(tool))
        let image = AgentImageCard(tool: tool)
        if AgentImageCard.applies(to: tool), let file = image.file {
            VStack(alignment: .leading, spacing: 10) {
                card
                AgentImageView(url: file, pixels: image.pixels,
                               bounds: AgentImageView.bounds(column: columnWidth, window: transcriptHeight))
            }
        } else {
            card
        }
    }
}

/// The card under the chat: the draft, its files and the row of actions. A view of its own, so
/// that typing and a recording redraw the card rather than the whole chat.
private struct ConversationComposer: View {
    @Bindable var store: TaskStore
    var workspace: WorkspaceStore?
    var voice: VoiceSessionController
    var dictation: DictationController
    var focusRequest: Int
    let conversationID: UUID
    let startDictation: () -> Void
    let startVoice: () -> Void
    let send: () -> Void
    let stop: () -> Void
    let retry: () -> Void
    /// The card's shape, named once so its glass, its edge and the container shape its contents
    /// round against are all literally the same shape.
    private static let card = RoundedRectangle(cornerRadius: 22)
    private var voiceOwner: VoiceSessionSnapshot.Owner? { voice.snapshot.session.owner }
    private var presentation: ComposerPresentation {
        ComposerPresentation(store: store, voice: voice, dictation: dictation, conversationID: conversationID)
    }
    private func sendText() {
        guard presentation.canSend else { return }
        send()
    }
    private func escape() -> Bool {
        if dictation.cancelForEscape() { return true }
        if presentation.stopsOnEscape { stop(); return true }
        return false
    }
    var body: some View {
        // Built once per render: each build trims the draft and evaluates `canRetry`.
        let presentation = presentation
        return VStack(alignment: .leading, spacing: 10) {
            if !store.mainAttachments.isEmpty {
                ChipFlow {
                    ForEach(Array(zip(store.mainAttachments, store.mainAttachmentNames)), id: \.0.id) { attachment, name in
                        DraftAttachmentChip(attachment: attachment, name: name) {
                            store.removeMainAttachment(attachment.id)
                            workspace?.requestComposerFocus(conversationID: conversationID)
                        }
                    }
                }.font(WorkspaceStyle.caption).accessibilityIdentifier("conversation.attachments")
            }
            if let notice = store.attachmentNotice {
                Text(notice).font(WorkspaceStyle.caption).foregroundStyle(WorkspaceStyle.secondary)
                    .accessibilityIdentifier("conversation.attachments.notice")
            }
            NativeComposer(text: $store.mainDraft, focusRequest: focusRequest,
                           isSuspended: presentation.isDictating,
                           diagnostics: !voice.isActive && !voice.testing && dictation.diagnosticTrace?.conversationID == conversationID
                               ? dictation.diagnosticTrace : nil,
                           onEscape: escape, onDropFiles: canAttach ? { store.attachToMainDraft($0) } : nil, onSend: sendText)
                .opacity(presentation.isDictating ? 0 : 1)
                .allowsHitTesting(!presentation.isDictating)
                // The editor keeps the keyboard under the recording preview, so it stays in the
                // accessibility tree too, or the key window would report nothing focused at all.
                // That takes saying: SwiftUI leaves a view at opacity 0 out of the tree by itself.
                .accessibilityHidden(false)
                .overlay(alignment: .topLeading) {
                    if presentation.isDictating {
                        DictationCaption(dictation: dictation, mode: presentation.mode)
                    } else if store.mainDraft.isEmpty {
                        Text("随心输入").font(WorkspaceStyle.body).foregroundStyle(WorkspaceStyle.tertiary)
                            .padding(.top, 4).allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
            // Live Voice's transcript is not a draft being prepared here: it forms in the
            // chat, in the place it will keep. The composer stays what it is for typing.
            if let error = voice.snapshot.error, error.conversationID == nil || error.conversationID == conversationID {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(WorkspaceStyle.warning)
                    Text(error.message).font(WorkspaceStyle.caption).foregroundStyle(WorkspaceStyle.primary).textSelection(.enabled)
                    Spacer()
                    Button {
                        voice.clearError(conversationID: conversationID)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("关闭语音提示")
                    .accessibilityIdentifier("voice.error.close")
                }
                // Concentric with the composer card this sits inside: the card publishes
                // its shape as the container shape, so this radius follows the card's
                // instead of being a second number to keep in step by hand. The floor is
                // the 8pt it was drawn at, for the inset that would otherwise round it
                // tighter than the box reads well at.
                .padding(8).background(WorkspaceStyle.warningFill,
                                       in: ConcentricRectangle(corners: .concentric(minimum: .fixed(8)), isUniform: true))
            }
            if let error = dictation.error {
                HStack(alignment: .top) {
                    Text(error).font(WorkspaceStyle.caption).textSelection(.enabled)
                    Spacer()
                    Button { dictation.clearError() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                        .accessibilityLabel("关闭转写提示")
                }
            }
            HStack(spacing: 12) {
                if presentation.isDictating {
                    Button { dictation.cancel(discard: true) } label: {
                        Image(systemName: "xmark").composerSecondaryLabel()
                    }.composerSecondaryControl().help("取消转写").accessibilityLabel("取消转写")
                        .accessibilityIdentifier("dictation.cancel")
                    DictationWaveform(dictation: dictation, active: presentation.mode == .dictationRecording)
                        .frame(maxWidth: .infinity).frame(height: 32)
                    Button { dictation.finishRecording() } label: {
                        Image(systemName: "stop.fill").composerSecondaryLabel()
                    }.composerSecondaryControl().disabled(presentation.mode != .dictationRecording)
                        .help("结束录音").accessibilityLabel("结束录音")
                        .accessibilityIdentifier("dictation.finish")
                } else {
                    Button(action: chooseFiles) {
                        Image(systemName: "plus").composerSecondaryLabel()
                    }.composerSecondaryControl().disabled(!canAttach)
                        .help(Self.addFilesLabel).accessibilityLabel(Self.addFilesLabel).accessibilityIdentifier("conversation.addFiles")
                    if let owner = voiceOwner, owner.conversationID != conversationID, let ws = workspace {
                        Button { ws.revealVoice(owner: owner) } label: {
                            HStack(spacing: 4) {
                                VoiceWaveform().frame(width: 14, height: 14)
                                // Includes drafts: a pet-started session owns one until it speaks.
                                Text("\(ws.conversation(id: owner.conversationID)?.displayTitle ?? String(localized: "聊天|Live Voice 所属", defaultValue: "聊天")) 的 Live Voice")
                                    .font(WorkspaceStyle.caption).lineLimit(1).truncationMode(.middle)
                                Image(systemName: "arrow.right").font(.caption2)
                            }
                        }.buttonStyle(.borderless).help("返回语音会话")
                            .accessibilityLabel("返回语音会话").accessibilityIdentifier("voice.reveal")
                    }
                    if presentation.mode == .voice, let owner = voiceOwner {
                        // The mark alone says Live Voice is on; its controls and what is
                        // heard say the rest, so the running commentary is left to
                        // assistive technology instead of being spelled out in the row.
                        VoiceWaveform().frame(width: 14, height: 14)
                            .foregroundStyle(voice.isMuted ? WorkspaceStyle.warning : Color.accentColor)
                            .accessibilityElement()
                            .accessibilityAddTraits(.isImage)
                            .accessibilityLabel("Live Voice")
                            .accessibilityValue(voice.status)
                            .accessibilityIdentifier("voice.status")
                        Spacer(minLength: 0)
                        Button {
                            if let ws = workspace { ws.toggleVoiceSpeakerMute(owner: owner) } else { voice.toggleSpeakerMute() }
                        } label: {
                            ComposerTintedIcon(systemName: voice.snapshot.speakerMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                               color: voice.snapshot.speakerMuted ? WorkspaceStyle.warning : WorkspaceStyle.secondary)
                                .composerSecondaryLabel()
                        }.composerSecondaryControl().disabled(!presentation.muteEnabled)
                            .help(voice.snapshot.speakerMuted ? "开启扬声器" : "静音扬声器")
                            .accessibilityLabel(voice.snapshot.speakerMuted ? "开启扬声器" : "静音扬声器")
                            .accessibilityIdentifier("voice.speaker")
                        Button {
                            if let ws = workspace { ws.toggleVoiceMute(owner: owner) } else { voice.toggleMute() }
                        } label: {
                            ComposerTintedIcon(systemName: voice.isMuted ? "mic.slash.fill" : "mic.fill",
                                               color: voice.isMuted ? WorkspaceStyle.warning : WorkspaceStyle.secondary)
                                .composerSecondaryLabel()
                        }.composerSecondaryControl().disabled(!presentation.muteEnabled)
                            .help(voice.isMuted ? "开启麦克风" : "关闭麦克风")
                            .accessibilityLabel(voice.isMuted ? "开启麦克风" : "关闭麦克风")
                            .accessibilityIdentifier("voice.mute")
                    } else {
                        Spacer(minLength: 0)
                        Button(action: startDictation) {
                            Image(systemName: "mic").composerSecondaryLabel()
                        }.composerSecondaryControl().disabled(!presentation.microphoneEnabled)
                            .help(presentation.microphoneEnabled ? "语音转文字" : "麦克风正在被占用")
                            .accessibilityLabel("语音转文字").accessibilityIdentifier("dictation.start")
                    }
                    if let output = presentation.output {
                        Button { output == .stop ? stop() : retry() } label: {
                            Image(systemName: output == .stop ? "stop.fill" : "play.fill")
                                .offset(x: output == .stop ? 0 : 1)
                                .composerSecondaryLabel()
                        }.composerSecondaryControl().disabled(output == .stop && !presentation.stopEnabled)
                            .help(output.label).accessibilityLabel(output.label)
                            .accessibilityIdentifier(output.identifier)
                    }
                }
                Button(action: performPrimary) {
                    Group {
                        switch presentation.primary {
                        case .startVoice: VoiceWaveform().frame(width: 16, height: 16)
                        case .send, .sendRecording: Image(systemName: "arrow.up")
                        case .stop: Image(systemName: "stop.fill")
                        case .resume: Image(systemName: "play.fill").offset(x: 1)
                        case .endVoice: Image(systemName: "xmark")
                        }
                    }.font(.body.weight(.semibold))
                        // The system border adds 4 pt per side; the outer control stays 32 pt.
                        .frame(width: 24, height: 24)
                }.buttonStyle(.borderedProminent).buttonBorderShape(.circle).controlSize(.regular)
                    .disabled(!presentation.primaryEnabled)
                    .help(presentation.primary.label).accessibilityLabel(presentation.primary.label)
                    .accessibilityIdentifier(presentation.primary.identifier)
            }.accessibilityElement(children: .contain).accessibilityIdentifier("conversation.actions")
        }.padding(16)
            // Regular Liquid Glass, untinted, as Xcode's navigator filter field: the system
            // adapts it to light and dark, frosting the chat that passes behind, and its own lit
            // rim keeps the edge visible on a white window without a stroke. It is a layer
            // of its own behind the content, so it doesn't restyle what it holds: glass holding
            // the card lightened the draft's text from 37 to 74–77 and faded the + circle and
            // the Live Voice mark. In an inactive window the system flattens all glass to frost.
            .background { Color.clear.glassEffect(.regular, in: Self.card) }
            // Publishing the card's shape is what lets everything drawn inside it round
            // concentrically with it, instead of each inner box repeating a number that
            // has to be changed in step when the card's does.
            .containerShape(Self.card)
            // Files dropped anywhere on the card; the editor takes those dropped on it itself.
            .onDrop(of: [.fileURL], delegate: ChatFileDrop(add: { if canAttach { store.attachToMainDraft($0) } }))
            .onDisappear {
                if dictation.conversationID == conversationID { dictation.cancel() }
            }
    }
    /// A tooltip and the button's name; the pet's + menu has the same words as a menu item.
    private static var addFilesLabel: String { String(localized: "添加文件|悬停提示", defaultValue: "添加文件") }
    /// A blocked conversation takes no files, as it takes no messages.
    private var canAttach: Bool { store.agentLoadError == nil }
    private func chooseFiles() {
        WorkspaceActions.chooseFiles { urls in
            store.attachToMainDraft(urls)
            workspace?.requestComposerFocus(conversationID: conversationID)
        }
    }
    private func performPrimary() {
        guard presentation.primaryEnabled else { return }
        switch presentation.primary {
        case .send: sendText()
        case .stop: stop()
        case .resume: retry()
        case .startVoice: startVoice()
        case .sendRecording: dictation.finishRecording(thenSend: sendText)
        case .endVoice:
            guard let owner = voiceOwner else { return }
            if let workspace { workspace.endVoice(owner: owner) } else { voice.end(reason: .user, origin: "\(#fileID):\(#line)") }
        }
    }
}

/// Quiet native controls share a 28 pt circle, centered in the primary action's 32 pt row.
/// Compensate for the system style's 4 pt inset rather than expanding the hit area.
private extension View {
    func composerSecondaryLabel() -> some View {
        font(.body.weight(.medium))
            .frame(width: 20, height: 20)
    }
    func composerSecondaryControl() -> some View {
        buttonStyle(.bordered).buttonBorderShape(.circle).controlSize(.regular)
            .frame(height: 32)
    }
}

/// A composer circle's symbol in a colour of its own. The colour goes on the symbol, not the button:
/// a bordered button derives its fill from a concrete foreground, which drew it a step darker than the
/// circles beside it, or orange (measured on macOS 27). A coloured symbol keeps its colour when the
/// button is disabled, so it takes the disabled text colour itself, as the API Key field's icons do.
private struct ComposerTintedIcon: View {
    let systemName: String
    let color: Color
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Image(systemName: systemName).foregroundStyle(enabled ? color : Color(nsColor: .disabledControlTextColor))
    }
}

/// The recording's waveform. It reads the levels itself: they change several times a second while
/// recording, and only the waveform has to redraw for them.
private struct DictationWaveform: View {
    let dictation: DictationController
    let active: Bool
    var body: some View {
        RecordingWaveform(levels: dictation.levels, active: active)
    }
}

/// What the recording has heard so far, or what it is waiting for. It reads the transcript itself,
/// for the same reason as the waveform: the recognizer revises it several times a second.
private struct DictationCaption: View {
    let dictation: DictationController
    let mode: ComposerPresentation.Mode
    private var text: String {
        switch mode {
        case .dictationFinalizing: String(localized: "正在完成转写…")
        case .dictationPreparing: dictation.isDownloadingModel ? String(localized: "正在下载语音模型…") : String(localized: "正在准备麦克风…")
        default: dictation.subtitle.isEmpty ? String(localized: "正在聆听…") : dictation.subtitle
        }
    }
    var body: some View {
        Text(text).font(WorkspaceStyle.body).foregroundStyle(WorkspaceStyle.secondary)
            .lineLimit(3).padding(.top, 4)
            .accessibilityIdentifier("dictation.subtitle")
    }
}

#Preview("聊天") {
    let store = TaskStore(snapshot: .init(
        task: nil,
        messages: [
            ConversationMessage(role: .user, content: "帮我总结一下这个项目。"),
            ConversationMessage(role: .assistant, content: "这是一个 macOS 桌面精灵应用，支持聊天和语音交互。")
        ],
        mainDraft: "",
        followUpDraft: "",
        activityDismissed: false,
        activitiesCollapsed: false
    ), harness: nil)
    let workspace = WorkspaceStore(initialStore: store)
    return WorkspaceConversationView(workspace: workspace, planets: PlanetStore())
        .frame(width: 700, height: 560)
}

#Preview("聊天 · 附件") {
    var sent = ConversationMessage(role: .user, content: "对比一下这两份需求，列出差异。")
    sent.attachments = zip(["/Users/someone/Desktop/需求说明.md", "/Users/someone/Documents/旧版/需求说明.md"], ["需求说明.md", "需求说明 2.md"])
        .map { path, name in
            var attachment = ChatAttachment(path: path)
            attachment.label = name
            return attachment
        }
    var snapshot = TaskStore.Snapshot(
        task: nil,
        messages: [sent, ConversationMessage(role: .assistant, content: "两份需求的主要差异在登录方式和导出格式。")],
        mainDraft: "再看看这两个文件",
        followUpDraft: "",
        activityDismissed: false,
        activitiesCollapsed: false)
    snapshot.mainAttachments = [ChatAttachment(path: "/Users/someone/Downloads/main.swift"),
                                ChatAttachment(path: "/Users/someone/Documents/config.json", problem: .denied)]
    let store = TaskStore(snapshot: snapshot, harness: nil)
    let workspace = WorkspaceStore(initialStore: store)
    return WorkspaceConversationView(workspace: workspace, planets: PlanetStore())
        .frame(width: 700, height: 460)
}
