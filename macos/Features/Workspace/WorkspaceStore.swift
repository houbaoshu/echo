import Foundation
import Combine
import Observation

struct WorkspaceProject: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var path: String
    var isAvailable: Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }
}

@MainActor @Observable final class WorkspaceConversation: Identifiable {
    let id: UUID
    fileprivate(set) var projectID: UUID?
    var title: String
    var manuallyNamed: Bool
    /// Still showing a default title, so its first message names it. `title` is what the archive
    /// holds; an untitled conversation shows `untitledTitle` instead, in the current language.
    var untitled: Bool
    var lastUsed: Date
    let store: TaskStore
    init(id: UUID = UUID(), projectID: UUID? = nil, title: String = "新会话",
         manuallyNamed: Bool = false, untitled: Bool = true, lastUsed: Date = Date(), store: TaskStore) {
        self.id = id; self.projectID = projectID; self.title = title
        self.manuallyNamed = manuallyNamed; self.untitled = untitled; self.lastUsed = lastUsed; self.store = store
    }
    /// A title, not the 新聊天 command, so the two can be translated apart.
    static var untitledTitle: String { String(localized: "新聊天|未命名聊天标题", defaultValue: "新聊天") }
    var displayTitle: String { untitled ? Self.untitledTitle : title }
}

@MainActor @Observable final class WorkspaceStore {
    let fileBrowser = ProjectFileBrowserStore()
    let voice: VoiceSessionController
    let dictation: DictationController
    private(set) var projects: [WorkspaceProject] = [] {
        didSet { synchronizeFileBrowser() }
    }
    private(set) var conversations: [WorkspaceConversation] = []
    private(set) var selectedID: UUID? {
        didSet {
            if oldValue != selectedID { fileBrowser.collapsePreview() }
            synchronizeFileBrowser()
            markViewedActivitySeen()
        }
    }
    private(set) var composerFocusRequest = 0
    private(set) var composerFocusID: UUID?
    private var drafts: [WorkspaceConversation] = []
    private(set) var activityID: UUID?
    /// Transient pet entries; removing an entry leaves its conversation in history.
    private(set) var petActivityIDs: [UUID] = []
    private(set) var isActivityListExpanded = false
    private(set) var petFollowUpID: UUID?
    private(set) var isPetTrayCollapsed = false
    /// The tray's three levels. More than one notification stacks; the stack opens into the list,
    /// and ⌃ steps back one level at a time. Follow-up sits on top of a level and returns to it.
    enum PetTrayLevel { case collapsed, stack, list }
    var petTrayLevel: PetTrayLevel { !isPetActivityVisible ? .collapsed : isActivityListExpanded ? .list : .stack }
    var petActivities: [WorkspaceConversation] { petActivityIDs.filter { $0 != voice.conversationID }.compactMap { conversation(id: $0) } }
    var visiblePetActivities: [WorkspaceConversation] { petActivities.filter { !$0.store.activitiesCollapsed } }
    var isPetActivityVisible: Bool { !visiblePetActivities.isEmpty && !isPetTrayCollapsed }
    /// The controls stay expanded without hover while any card shows, so ⌃ stays in reach.
    /// With only the bell left they follow hover.
    var keepsPetControlsExpanded: Bool { isPetActivityVisible }
    var petActivityHeight: CGFloat {
        if petFollowUpID != nil { return CompanionLayout.expandedHeight }
        if isActivityListExpanded { return max(0, CGFloat(min(3, visiblePetActivities.count)) * (CompanionLayout.collapsedHeight + 8) - 8) + 12 }
        return CompanionLayout.collapsedHeight + CGFloat(min(2, max(0, visiblePetActivities.count - 1))) * 7
    }
    /// Ignore this notification without opening its chat or stopping its task.
    /// Only a subsequent run can add this conversation back to the pet tray.
    func dismissPetActivity(conversationID: UUID) {
        guard !shuttingDown, petActivityIDs.contains(conversationID) else { return }
        removePetActivity(conversationID)
    }
    func openPetActivity(conversationID: UUID) {
        guard conversation(id: conversationID) != nil else { return }
        select(conversationID)
        isMainWindowVisible = true
        removePetActivity(conversationID)
        onOpenPetActivity?()
    }
    /// Opens a stack into the list. A single card has no stack and stays a card.
    func expandActivityList() {
        guard isPetActivityVisible, visiblePetActivities.count > 1 else { return }
        isActivityListExpanded = true
    }
    /// A list left with one card goes back to a plain card, and forgets it was a list.
    private func settleActivityList() {
        if visiblePetActivities.count <= 1 { isActivityListExpanded = false }
    }
    func enterPetFollowUp(_ id: UUID) {
        guard petActivityIDs.contains(id), let store = conversation(id: id)?.store else { return }
        if petFollowUpID == id {
            exitPetFollowUp()
            return
        }
        exitPetFollowUp()
        activityID = id; petFollowUpID = id
        store.expandActivity()
        if !store.isFollowUpExpanded { store.toggleFollowUp() }
    }
    func exitPetFollowUp() {
        if let id = petFollowUpID, let store = conversation(id: id)?.store, store.isFollowUpExpanded { store.toggleFollowUp() }
        petFollowUpID = nil
    }
    private func removePetActivity(_ id: UUID) {
        if petFollowUpID == id { exitPetFollowUp() }
        petActivityIDs.removeAll { $0 == id }
        conversation(id: id)?.store.closeActivity()
        if activityID == id { activityID = petActivityIDs.first }
        settleActivityList()
    }
    var isMainWindowVisible = false {
        didSet {
            if !isMainWindowVisible { dictation.cancel() }
            markViewedActivitySeen()
        }
    }
    /// A minimized main window is not visible, but it is still open: it keeps its chat.
    @ObservationIgnored var isMainWindowMinimized = false
    /// Echo is hidden (⌘H, or Hide Others in another app). The main window stays open, and AppKit
    /// brings it back when Echo is shown again, so `isMainWindowVisible` is left alone; nobody sees it meanwhile.
    var isApplicationHidden = false {
        didSet { if isApplicationHidden != oldValue { markViewedActivitySeen() } }
    }
    /// Whether the person can see the main window now: open, and Echo not hidden.
    var isMainWindowShown: Bool { isMainWindowVisible && !isApplicationHidden }
    var persistenceNotice: String?
    @ObservationIgnored var onRevealVoice: ((UUID) -> Void)?
    @ObservationIgnored var onOpenPetActivity: (() -> Void)?
    /// A chat's task changed, for the pet to show; never during a Live Voice call. See `showsOnPet`.
    @ObservationIgnored var onPetTaskEvent: ((TaskLifecycleEvent) -> Void)?
    private let emptyActivity = TaskStore()
    private let harnessFactory: (() -> AgentHarness)?
    private let persistence: WorkspacePersistence?
    @ObservationIgnored private var lifecycleObservations: [UUID: AnyCancellable] = [:]
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    /// Bumped each time what a save reads is read again under tracking; an older registration that
    /// fires afterwards is stale and does nothing.
    @ObservationIgnored private var saveTracking = 0
    @ObservationIgnored private var saveDeadline: DispatchTime?
    private let saveDebounce: DispatchTimeInterval
    private let maximumSaveDelay: DispatchTimeInterval
    @ObservationIgnored private var shuttingDown = false
    /// A Live Voice conversation whose completed replies have not been viewed. It becomes an
    /// unseen completion only when the voice session ends; until then the conversation is in progress.
    @ObservationIgnored private var voiceCompletion: UUID?
    @ObservationIgnored private var voiceObservation: ObservationHandle?
    /// Runs a Live Voice call took part in, whose endings the pet never shows. A call's failed
    /// turn ends the call, which may let go of its conversation before its ending reaches here:
    /// a TaskStore's lifecycle tells its subscribers in no fixed order.
    @ObservationIgnored private var voiceRunIDs: Set<UUID> = []
    @ObservationIgnored private var saveBlocked = false
    @ObservationIgnored private var persistedSessionIDs: Set<UUID> = []
    // Keep display timestamps fixed for this app session. Persist actual interaction
    // times separately so only the next launch applies the new order.
    private var pendingRecency: [UUID: Date] = [:]

    /// A saved workspace always has the Agent engine: a conversation without it would save its
    /// native history away.
    convenience init(persistence: WorkspacePersistence,
                     dictation: DictationController = DictationController(),
                     voice: VoiceSessionController = VoiceSessionController(),
                     saveDebounce: Duration = .milliseconds(400),
                     maximumSaveDelay: Duration = .seconds(2),
                     harnessFactory: @escaping () -> AgentHarness) {
        self.init(persistence: persistence, initialStore: nil, dictation: dictation, voice: voice,
                  saveDebounce: saveDebounce, maximumSaveDelay: maximumSaveDelay, harnessFactory: harnessFactory)
    }
    /// A workspace that is never saved. Without `harnessFactory` its conversations cannot send.
    /// `petActivities` start out on the pet's tray, the first at the front of the stack; one
    /// without a task is only a conversation.
    convenience init(initialStore: TaskStore? = nil,
                     petActivities: [WorkspaceConversation] = [],
                     dictation: DictationController = DictationController(),
                     voice: VoiceSessionController = VoiceSessionController(),
                     harnessFactory: (() -> AgentHarness)? = nil) {
        self.init(persistence: nil, initialStore: initialStore, petActivities: petActivities,
                  dictation: dictation, voice: voice, harnessFactory: harnessFactory)
    }
    private init(persistence: WorkspacePersistence?, initialStore: TaskStore?, petActivities: [WorkspaceConversation] = [],
                 dictation: DictationController,
                 voice: VoiceSessionController, saveDebounce: Duration = .milliseconds(400),
                 maximumSaveDelay: Duration = .seconds(2), harnessFactory: (() -> AgentHarness)?) {
        self.dictation = dictation; self.voice = voice
        self.saveDebounce = .nanoseconds(Int(saveDebounce / .nanoseconds(1)))
        self.maximumSaveDelay = .nanoseconds(Int(maximumSaveDelay / .nanoseconds(1)))
        self.persistence = persistence
        self.harnessFactory = harnessFactory
        voiceObservation = observeChanges({ voice.snapshot.session.owner == nil }, initial: true) { [weak self] ended in
            if ended { self?.finishVoiceConversation() } else { self?.adoptVoiceRun() }
        }
        if let initialStore {
            let conversation = WorkspaceConversation(store: initialStore)
            conversations = [conversation]; selectedID = conversation.id; activityID = conversation.id
            if initialStore.task != nil { petActivityIDs = [conversation.id] }
            bind(conversation)
        } else if let persistence {
            let (snapshot, problem) = persistence.load()
            persistenceNotice = problem?.message
            // A failed preservation must never be followed by overwriting the original archive.
            if case .preservationFailed = problem { saveBlocked = true }
            if let snapshot {
                if problem == nil {
                    persistence.pruneSessions(keeping: Set(snapshot.allConversations.map(\.id)))
                }
                projects = snapshot.projects
                conversations = snapshot.conversations.map { saved in
                    WorkspaceConversation(id: saved.id, projectID: validProjectID(saved.projectID),
                        title: saved.title, manuallyNamed: saved.manuallyNamed, untitled: saved.isUntitled, lastUsed: saved.lastUsed,
                        store: TaskStore(snapshot: persistence.restoreSession(saved), harness: harnessFactory?()))
                }
                drafts = (snapshot.drafts ?? []).map { saved in
                    WorkspaceConversation(id: saved.id, projectID: validProjectID(saved.projectID),
                        title: "新对话", lastUsed: saved.lastUsed,
                        store: TaskStore(snapshot: persistence.restoreSession(saved), harness: harnessFactory?()))
                }
                // Restore history and drafts, but leave the previous session's
                // selection and desktop activity behind on every launch.
                (conversations + drafts).forEach(bind)
            }
        }
        conversations += petActivities
        petActivityIDs += petActivities.filter { $0.store.task != nil }.map(\.id)
        petActivities.forEach(bind)
        // Armed after loading, which only repeats what is on disk, and before the first chat of a
        // launch is made, which is new.
        _ = trackedSnapshot()
        if selected == nil { _ = newConversation() }
    }

    var selected: WorkspaceConversation? { (conversations + drafts).first { $0.id == selectedID } }
    var activity: WorkspaceConversation? { conversations.first { $0.id == activityID } }
    var activityStore: TaskStore { activity?.store ?? emptyActivity }
    func conversation(id: UUID) -> WorkspaceConversation? {
        (conversations + drafts).first { $0.id == id }
    }
    func project(for conversationID: UUID) -> WorkspaceProject? {
        guard let id = conversation(id: conversationID)?.projectID else { return nil }
        return projects.first { $0.id == id }
    }
    var unseenCompletedCount: Int { petActivities.filter { $0.store.hasUnseenCompletion }.count }
    /// The bell and ⌃: collapsed opens to the stack, the list steps back to the stack, and the
    /// stack collapses. Follow-up ends with the level it sat on.
    func toggleActivityTray() {
        switch petTrayLevel {
        case .list:
            exitPetFollowUp(); isActivityListExpanded = false
        case .stack:
            exitPetFollowUp(); isPetTrayCollapsed = true; isActivityListExpanded = false
            petActivities.forEach { $0.store.foldActivity() }
        case .collapsed:
            isPetTrayCollapsed = false; isActivityListExpanded = false
            petActivities.forEach { $0.store.expandActivity() }
        }
    }
    var runningTaskCount: Int { conversations.filter { $0.store.isGenerating }.count }
    private func markViewedActivitySeen() {
        guard isMainWindowShown else { return }
        selected?.store.markSeen()
        if let selected, !selected.store.isGenerating, petActivityIDs.contains(selected.id) { removePetActivity(selected.id) }
        if voiceCompletion == selectedID { voiceCompletion = nil }
    }
    private func isViewing(_ id: UUID) -> Bool { isMainWindowShown && selectedID == id }
    private func finishVoiceConversation() {
        guard let id = voiceCompletion else { return }
        voiceCompletion = nil
        guard !shuttingDown, !isViewing(id), let store = conversation(id: id)?.store else { return }
        store.recordCompletion(unseen: true)
    }
    /// A call that starts on a running turn takes it over.
    private func adoptVoiceRun() {
        guard let id = voice.conversationID, let store = conversation(id: id)?.store,
              store.isGenerating, let runID = store.task?.runID else { return }
        voiceRunIDs.insert(runID)
    }
    /// Whether the pet shows `event` of conversation `id`: not while a Live Voice call is on, and
    /// not for a run the call took part in, even once it is over.
    private func showsOnPet(_ event: TaskLifecycleEvent, conversationID id: UUID) -> Bool {
        let inCall = voice.snapshot.session.owner != nil
        switch event {
        case .started(let runID):
            if voice.conversationID == id { voiceRunIDs.insert(runID) }
            return !inCall
        case .reply(let runID, _), .stopped(let runID):
            return voiceRunIDs.remove(runID) == nil && !inCall
        case .retired:
            return false
        }
    }
    private func synchronizeFileBrowser() {
        fileBrowser.select(project: selectedID.flatMap { project(for: $0) })
    }
    func canAssociateProject(conversationID: UUID) -> Bool {
        guard !shuttingDown, let store = conversation(id: conversationID)?.store else { return false }
        return store.messages.isEmpty && store.tools.isEmpty && !store.isGenerating && store.agentLoadError == nil
    }

    // Commands capture their target at the surface that issued them. Selection and
    // desktop activity are navigation state, never an implicit command destination.
    @discardableResult func send(_ text: String, attachments: [ChatAttachment] = [], conversationID: UUID) -> Bool {
        guard !shuttingDown, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let target = conversation(id: conversationID), target.store.canSubmit else { return false }
        return submit(conversationID) { target.store.send(text, attachments: attachments) }
    }
    /// Runs `submission`, inside the Live Voice call's submission when the call is on this conversation.
    private func submit(_ conversationID: UUID, _ submission: () -> Bool) -> Bool {
        guard voice.conversationID == conversationID else { return submission() }
        return voice.submit(submission)
    }
    /// The pet's quick composer always starts its own conversation. It never reuses the
    /// main window's draft or changes the selection; the first send makes it the activity.
    @discardableResult func sendQuickMessage(_ text: String, attachments: [ChatAttachment] = [], projectID: UUID? = nil) -> Bool {
        guard !shuttingDown, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let conversation = makeDraft(projectID: validProjectID(projectID))
        if send(text, attachments: attachments, conversationID: conversation.id) { return true }
        if conversation.store.messages.isEmpty {
            conversation.store.shutdown(); lifecycleObservations[conversation.id] = nil
            drafts.removeAll { $0.id == conversation.id }
        }
        return false
    }
    /// The pet's Live Voice entry starts its own conversation the way its quick composer does:
    /// whatever the main window is showing stays where it is, so a call started from the desktop
    /// never turns the chat being read into a voice session. An empty draft nobody is looking at
    /// is reused rather than adding another one, the way `newConversation` reuses one.
    @discardableResult func startVoiceInNewConversation(projectID: UUID? = nil) -> Bool {
        guard !shuttingDown, voice.snapshot.session.owner == nil else { return false }
        let validProject = validProjectID(projectID)
        // Never the selected one: reusing what the main window shows is the takeover this avoids.
        let target = reusableDraft(projectID: validProject, excluding: selectedID) ?? makeDraft(projectID: validProject)
        target.lastUsed = Date()
        // A failed start reports against this conversation, so the draft stays for the error to
        // hang on — and, being empty, it is what the next attempt reuses.
        return voice.activate(conversation: target, entry: "桌宠·新对话")
    }
    @discardableResult func sendMainMessage(conversationID: UUID) -> Bool {
        guard let target = conversation(id: conversationID),
              send(target.store.mainDraft, attachments: target.store.mainAttachments, conversationID: conversationID) else { return false }
        target.store.mainDraft = ""; target.store.mainAttachments = []; target.store.attachmentNotice = nil
        return true
    }
    @discardableResult func sendFollowUp(conversationID: UUID) -> Bool {
        guard let target = conversation(id: conversationID), send(target.store.followUpDraft, conversationID: conversationID) else { return false }
        target.store.followUpDraft = ""
        return true
    }
    func stop(conversationID: UUID) {
        guard !shuttingDown, let target = conversation(id: conversationID) else { return }
        if voice.conversationID == conversationID { voice.stopReply() }
        else { target.store.stopTask() }
    }
    @discardableResult func retry(conversationID: UUID) -> Bool {
        guard !shuttingDown, let target = conversation(id: conversationID), target.store.canRetry else { return false }
        return submit(conversationID) { target.store.retry() }
    }
    /// `activate` refuses while another call is on.
    @discardableResult func startVoice(conversationID: UUID) -> Bool {
        guard !shuttingDown, let target = conversation(id: conversationID) else { return false }
        return voice.activate(conversation: target, entry: "会话")
    }
    /// `file`/`line` name the control that asked, for the call's termination log only.
    func endVoice(owner: VoiceSessionSnapshot.Owner, file: StaticString = #fileID, line: UInt = #line) {
        guard voice.snapshot.session.owner == owner else { return }
        voice.end(reason: .user, origin: "\(file):\(line)")
    }
    func toggleVoiceMute(owner: VoiceSessionSnapshot.Owner) {
        guard voice.snapshot.session.owner == owner else { return }
        voice.toggleMute()
    }
    func toggleVoiceSpeakerMute(owner: VoiceSessionSnapshot.Owner) {
        guard voice.snapshot.session.owner == owner else { return }
        voice.toggleSpeakerMute()
    }
    func requestComposerFocus(conversationID: UUID) {
        composerFocusID = conversationID
        composerFocusRequest += 1
    }
    func revealVoice(conversationID: UUID? = nil, owner: VoiceSessionSnapshot.Owner? = nil) {
        guard let targetID = conversationID ?? owner?.conversationID ?? voice.conversationID else { return }
        if selectedID != targetID { select(targetID) }
        requestComposerFocus(conversationID: targetID)
        isMainWindowVisible = true
        onRevealVoice?(targetID)
    }
    /// What a save writes, and also what decides when one happens: every flush reads this with
    /// tracking armed, and the first later change to anything read here schedules the next save
    /// (`trackedSnapshot`). So everything it reads, here and in `TaskStore.snapshot`, has to be an
    /// observed property: never `@ObservationIgnored`, never kept in an object that is not
    /// `@Observable`. Otherwise a change to it alone is only written with some later change.
    /// WorkspaceTests.everySavedFieldReachesTheArchiveOnItsOwn changes each field on its own.
    var snapshot: WorkspaceSnapshot {
        WorkspaceSnapshot(projects: projects, conversations: conversations.map {
            .init(id: $0.id, projectID: $0.projectID, title: $0.title, manuallyNamed: $0.manuallyNamed,
                  untitled: $0.untitled ? true : nil, lastUsed: pendingRecency[$0.id] ?? $0.lastUsed, state: $0.store.snapshot)
        }, selectedID: selectedID, activityID: activityID, drafts: drafts.map {
            .init(id: $0.id, projectID: $0.projectID, title: $0.title, manuallyNamed: false,
                  lastUsed: $0.lastUsed, state: $0.store.snapshot)
        })
    }

    private func bind(_ conversation: WorkspaceConversation) {
        let id = conversation.id
        conversation.store.sessionID = id
        conversation.store.projectDirectory = { [weak self, weak conversation] in
            guard let self, let project = self.projects.first(where: { $0.id == conversation?.projectID }) else { return .noProject }
            guard project.isAvailable else { return .missing }
            return .path(URL(fileURLWithPath: project.path).resolvingSymlinksInPath().standardizedFileURL.path)
        }
        conversation.store.backupDirectory = persistence?.backupDirectory(id)
        conversation.store.checkpoint = { [weak self] state in
            guard let self else { throw CocoaError(.fileWriteUnknown) }
            if self.saveBlocked { throw CocoaError(.fileWriteNoPermission) }
            if let error = state.loadError { throw SettingsError(error) }
            try self.persistence?.saveSession(state, id: id)
            // Ensure a new conversation is discoverable before any tool starts.
            // The manifest stores references; tool updates write only this sidecar.
            if !self.persistedSessionIDs.contains(id) {
                try self.persistence?.save(self.snapshot)
                self.persistedSessionIDs.insert(id)
            }
        }
        conversation.store.onUserAction = { [weak self] in self?.didUse(id) }
        conversation.store.onFilesChanged = { [weak self, weak conversation] in self?.fileBrowser.refresh(projectID: conversation?.projectID) }
        conversation.store.onVisibilityChange = { [weak self] visible in self?.isMainWindowVisible = visible }
        lifecycleObservations[id] = conversation.store.lifecycle.sink { [weak self] event in
            guard let self, let target = self.conversation(id: id) else { return }
            switch event {
            case .started:
                target.store.markSeen()
                if !self.petActivityIDs.contains(id) {
                    // An open list takes the new card on top; otherwise it arrives as the stack.
                    if !self.isPetActivityVisible { self.isActivityListExpanded = false }
                    self.exitPetFollowUp(); self.isPetTrayCollapsed = false
                    self.petActivityIDs.insert(id, at: 0)
                }
                // A Live Voice turn is folded before the companion next synchronizes, so its card never shows.
                if self.voice.conversationID == id || self.isPetTrayCollapsed { target.store.foldActivity() }
                else { target.store.expandActivity() }
            case .reply(_, .completed):
                // The conversation on screen already shows its reply; elsewhere the result stays unread.
                // A Live Voice conversation is still in progress; it is counted when the voice session ends.
                let viewed = self.isViewing(id)
                if self.voice.conversationID == id { self.voiceCompletion = viewed ? nil : id }
                target.store.recordCompletion(unseen: !viewed && self.voice.conversationID != id)
                if viewed { self.removePetActivity(id) }
                self.fileBrowser.refresh(projectID: target.projectID)
            case .reply(_, .failed), .stopped:
                target.store.recordCompletion(unseen: !self.isViewing(id))
                if self.isViewing(id) { self.removePetActivity(id) }
                self.fileBrowser.refresh(projectID: target.projectID)
            default: break
            }
            if self.showsOnPet(event, conversationID: id) { self.onPetTaskEvent?(event) }
        }
    }
    private func didUse(_ id: UUID) {
        let usedAt = Date()
        // A blank composer becomes a sidebar conversation only after the first real message.
        if let draft = drafts.first(where: { $0.id == id }), !draft.store.messages.isEmpty {
            drafts.removeAll { $0.id == id }
            draft.lastUsed = usedAt
            conversations.append(draft)
        }
        guard let conversation = conversations.first(where: { $0.id == id }) else { return }
        pendingRecency[id] = usedAt
        if conversation.untitled {
            if let first = conversation.store.messages.first(where: { $0.role == .user }) {
                conversation.title = String(first.content.prefix(60)); conversation.untitled = false
            } else { conversation.title = "新会话" }
        }
        activityID = id
    }
    @discardableResult func newConversation(projectID: UUID? = nil) -> WorkspaceConversation {
        let validProject = validProjectID(projectID)
        let conversation = reusableDraft(projectID: validProject) ?? makeDraft(projectID: validProject)
        if selectedID != conversation.id { dictation.cancel(); flush() }
        selectedID = conversation.id
        conversation.lastUsed = Date()
        requestComposerFocus(conversationID: conversation.id)
        return conversation
    }
    func select(_ id: UUID) {
        guard id != selectedID, conversation(id: id) != nil else { return }
        dictation.cancel()
        flush()
        selectedID = id
        if let draft = drafts.first(where: { $0.id == id }) { draft.lastUsed = Date() }
    }
    func revealActivity() {
        if let activityID, activityID != selectedID { select(activityID) }
        isMainWindowVisible = true
    }
    /// Clicking the pet. A Live Voice call takes it to the call's conversation. Otherwise a main
    /// window still open, showing or minimized, keeps its chat, and a closed one opens on a new
    /// chat, reusing an empty draft, rather than on a notification's chat, so every notification
    /// stays unread.
    func revealFromPet() {
        if voice.isActive, let id = voice.conversationID { revealVoice(conversationID: id); return }
        if !isMainWindowVisible && !isMainWindowMinimized { newConversation(projectID: selected?.projectID) }
        isMainWindowVisible = true
    }
    func renameConversation(_ id: UUID, to title: String) {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let conversation = conversations.first(where: { $0.id == id }) else { return }
        conversation.title = name; conversation.manuallyNamed = true; conversation.untitled = false
    }
    func deleteConversation(_ id: UUID) {
        guard let conversation = conversation(id: id) else { return }
        if dictation.conversationID == id { dictation.cancel(discard: true) }
        if voice.conversationID == id { voice.end(reason: .conversationDeleted) }
        voice.clearError(conversationID: id)
        conversation.store.shutdown(); lifecycleObservations[id] = nil
        pendingRecency[id] = nil
        conversations.removeAll { $0.id == id }
        drafts.removeAll { $0.id == id }
        removePetActivity(id)
        if selectedID == id { selectedID = (conversations + drafts).max(by: { $0.lastUsed < $1.lastUsed })?.id }
        if conversations.isEmpty && drafts.isEmpty { _ = newConversation() }
        // Remove the history sidecar, and the copies of files its Agent replaced, only once neither
        // the manifest nor its backup references it.
        guard flush(), let persistence else { return }
        persistedSessionIDs.remove(id)
        do { try persistence.refreshBackup(); try persistence.removeSession(id); try persistence.removeBackups(id) }
        catch { persistenceNotice = String(localized: "聊天记录删除失败：\(error.localizedDescription)") }
    }
    /// The sidebar always lists everything. Searching is a separate surface — a palette
    /// with its own query and its own results — so the column never hides chats behind a
    /// filter the person cannot see.
    var recentConversations: [WorkspaceConversation] { byRecency(conversations) }
    func filteredConversations(projectID: UUID?) -> [WorkspaceConversation] {
        byRecency(conversations.filter { $0.projectID == projectID })
    }
    /// The search palette's results: every chat whose title or transcript contains the
    /// query, most recently used first. An empty query answers with all of them, which is
    /// what the palette shows before anything is typed.
    func conversations(matching query: String) -> [WorkspaceConversation] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return recentConversations }
        return byRecency(conversations.filter {
            $0.displayTitle.localizedStandardContains(query)
                || $0.store.messages.contains { $0.content.localizedStandardContains(query) }
        })
    }
    private func validProjectID(_ id: UUID?) -> UUID? { projects.contains { $0.id == id } ? id : nil }
    /// The most recent empty draft in `projectID` that can still take a project.
    private func reusableDraft(projectID: UUID?, excluding: UUID? = nil) -> WorkspaceConversation? {
        byRecency(drafts.filter { $0.id != excluding && $0.projectID == projectID && canAssociateProject(conversationID: $0.id) }).first
    }
    private func makeDraft(projectID: UUID?) -> WorkspaceConversation {
        let conversation = WorkspaceConversation(projectID: projectID, title: "新对话", store: TaskStore(harness: harnessFactory?()))
        drafts.append(conversation); bind(conversation)
        return conversation
    }
    private func byRecency(_ conversations: [WorkspaceConversation]) -> [WorkspaceConversation] {
        conversations.sorted {
            if $0.lastUsed != $1.lastUsed { return $0.lastUsed > $1.lastUsed }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
    private static func projectPath(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
    @discardableResult func addProject(url: URL) -> UUID {
        let path = Self.projectPath(url)
        if let existing = projects.first(where: { $0.path == path }) { return existing.id }
        let project = WorkspaceProject(name: url.lastPathComponent, path: path)
        projects.append(project); return project.id
    }
    func renameProject(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[index].name = name
    }
    func relocateProject(_ id: UUID, to url: URL) {
        guard !projectIsActive(id) else { persistenceNotice = String(localized: "任务活动期间不能重新定位项目。"); return }
        let path = Self.projectPath(url)
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        guard !projects.contains(where: { $0.id != id && $0.path == path }) else {
            persistenceNotice = String(localized: "该文件夹已属于另一个项目。"); return
        }
        projects[index].path = path
    }
    func removeProject(_ id: UUID) {
        guard !projectIsActive(id) else { persistenceNotice = String(localized: "任务活动期间不能解除项目关联。"); return }
        (conversations + drafts).filter { $0.projectID == id }.forEach { $0.projectID = nil }
        projects.removeAll { $0.id == id }; flush()
    }
    /// Bumped when Echo comes back to the front, since a project's folder may have moved or come
    /// back meanwhile. `isAvailable(_:)` reads it so the views that show availability look again.
    private(set) var projectAvailabilityRevision = 0
    func refreshProjectAvailability() { projectAvailabilityRevision += 1 }
    func isAvailable(_ project: WorkspaceProject) -> Bool {
        _ = projectAvailabilityRevision
        return project.isAvailable
    }
    func projectIsActive(_ id: UUID) -> Bool {
        (conversations + drafts).contains { $0.projectID == id && $0.store.isGenerating }
    }
    @discardableResult func associateProject(_ projectID: UUID?, conversationID: UUID) -> Bool {
        guard canAssociateProject(conversationID: conversationID),
              let conversation = conversation(id: conversationID) else { return false }
        if let projectID, !projects.contains(where: { $0.id == projectID && $0.isAvailable }) { return false }
        conversation.projectID = projectID
        conversation.lastUsed = Date()
        synchronizeFileBrowser()
        flush()
        return true
    }
    @discardableResult func associateFolder(_ url: URL, conversationID: UUID) -> Bool {
        // A sheet can outlive its composer. Revalidate before even adding a project.
        guard selectedID == conversationID, canAssociateProject(conversationID: conversationID),
              (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return false }
        return associateProject(addProject(url: url), conversationID: conversationID)
    }

    func prepareForTermination() async {
        shuttingDown = true; dictation.shutdown(); voice.shutdown()
        let stores = (conversations + drafts).map(\.store)
        stores.forEach { $0.stopTask() }
        // An undo runs off the main actor and saves its result when done; it changes files, so it
        // is waited for like a turn, or its change would be on disk with its card still offering Undo.
        while stores.contains(where: { $0.isGenerating || !$0.undoingTools.isEmpty }) {
            try? await Task.sleep(for: .milliseconds(20))
        }
        flush()
        stores.forEach { $0.shutdown() }
    }
    private func scheduleSave() {
        guard !shuttingDown else { return }
        let now = DispatchTime.now()
        // Keep the trailing debounce, but continuous updates cannot postpone a
        // checkpoint more than `maximumSaveDelay` after the first unsaved change.
        let deadline = saveDeadline ?? (now + maximumSaveDelay)
        saveDeadline = deadline
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { _ = self?.flush() } }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: min(now + saveDebounce, deadline), execute: work)
    }
    @discardableResult func flush() -> Bool {
        saveWork?.cancel(); saveWork = nil; saveDeadline = nil
        guard let persistence else { return false }
        guard !saveBlocked else {
            persistenceNotice = Self.saveBlockedNotice
            return false
        }
        // Logged only during a Live Voice call: every save for its first 10 s, then only slow ones.
        do {
            try VoiceDiagnostics.shared.measure("WorkspaceStore.flush", quietAfter: .seconds(10)) {
                try persistence.save(trackedSnapshot())
            }
            return true
        }
        catch { persistenceNotice = String(localized: "聊天保存失败：\(error.localizedDescription)"); return false }
    }
    /// Reads what a save writes with tracking armed: the first later change to any of it schedules
    /// a save, inside that write, the way an explicit `scheduleSave()` after it would. Every flush
    /// reads it again, so a change made right after a flush in the same turn still schedules one;
    /// otherwise it is read again on the next main-queue turn.
    private func trackedSnapshot() -> WorkspaceSnapshot {
        saveTracking += 1
        let armed = saveTracking
        return withObservationTracking(options: [.didSet]) { snapshot } onChange: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.saveTracking == armed else { return }
                self.scheduleSave()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.saveTracking == armed else { return }
                    _ = self.trackedSnapshot()
                }
            }
        }
    }
    private static var saveBlockedNotice: String { String(localized: "无法备份损坏的聊天文件；为保留原件，保存已暂停。请恢复目录写入权限后重新打开应用。") }
    func shutdown() {
        fileBrowser.select(project: nil)
        dictation.shutdown()
        voiceObservation = nil
        voice.shutdown()
        shuttingDown = true; flush(); saveTracking += 1; lifecycleObservations.removeAll()
        (conversations + drafts).forEach { $0.store.shutdown() }
    }
}
