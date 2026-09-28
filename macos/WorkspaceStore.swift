import Foundation
import Combine

struct WorkspaceProject: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var path: String
    var isAvailable: Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }
}

@MainActor final class WorkspaceConversation: Identifiable {
    let id: UUID
    fileprivate(set) var projectID: UUID?
    var title: String
    var manuallyNamed: Bool
    var lastUsed: Date
    let store: TaskStore
    init(id: UUID = UUID(), projectID: UUID? = nil, title: String = "新会话",
         manuallyNamed: Bool = false, lastUsed: Date = Date(), store: TaskStore) {
        self.id = id; self.projectID = projectID; self.title = title
        self.manuallyNamed = manuallyNamed; self.lastUsed = lastUsed; self.store = store
    }
}

struct WorkspaceSnapshot: Codable {
    struct Conversation: Codable {
        var id: UUID
        var projectID: UUID?
        var title: String
        var manuallyNamed: Bool
        var lastUsed: Date
        var state: TaskStore.Snapshot
    }
    var version = 1
    var projects: [WorkspaceProject]
    var conversations: [Conversation]
    var selectedID: UUID?
    var activityID: UUID?
    var drafts: [Conversation]? = nil
}

/// Accessed on the main actor: mutations and atomic saves have a single ordered writer.
@MainActor final class WorkspacePersistence {
    let url: URL
    var backupURL: URL { url.appendingPathExtension("backup") }
    init(url: URL) { self.url = url }
    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.chiyan.desktop-pet/workspace.json")
    }
    private func decode(_ url: URL) throws -> WorkspaceSnapshot {
        let result = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(contentsOf: url))
        guard result.version == 1,
              Set(result.conversations.map(\.id) + (result.drafts ?? []).map(\.id)).count
                == result.conversations.count + (result.drafts ?? []).count,
              Set(result.projects.map(\.id)).count == result.projects.count else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return result
    }
    var sessionsDirectory: URL { url.deletingLastPathComponent().appendingPathComponent("agent-sessions") }
    /// Native-engine sidecars live apart from the Rust engine's, so a build that knows only the
    /// Rust engine never finds one: it sees a missing history and blocks the conversation instead
    /// of importing its visible messages as a fresh history.
    var nativeSessionsDirectory: URL { url.deletingLastPathComponent().appendingPathComponent("agent-sessions-v2") }
    func sessionURL(_ id: UUID) -> URL {
        sessionsDirectory.appendingPathComponent("\(id.uuidString).json")
    }
    func nativeSessionURL(_ id: UUID) -> URL {
        nativeSessionsDirectory.appendingPathComponent("\(id.uuidString).json")
    }
    func sessionURL(_ id: UUID, engine: AgentEngineKind?) -> URL {
        engine == .native ? nativeSessionURL(id) : sessionURL(id)
    }
    func saveSession(_ state: TaskStore.Snapshot, id: UUID) throws {
        let target = state.native != nil ? nativeSessionURL(id) : sessionURL(id)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        // Only a changed conversation is written.
        if (try? Data(contentsOf: target)) == data { return }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
    }
    func removeSession(_ id: UUID) throws {
        for target in [sessionURL(id), nativeSessionURL(id)] {
            do { try FileManager.default.removeItem(at: target) }
            catch CocoaError.fileNoSuchFile {}
        }
    }
    /// Deletes sidecars no manifest conversation references, such as those left by deletions before
    /// sessions were removed. Only call after the manifest itself loaded cleanly.
    func pruneSessions(keeping ids: Set<UUID>) {
        let fm = FileManager.default
        let files = [sessionsDirectory, nativeSessionsDirectory].flatMap {
            (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? []
        }
        guard !files.isEmpty,
              let siblings = try? fm.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil) else { return }
        // The backup and archives preserved by `load` may be the only way back to a history.
        // They need not decode, so any UUID text in them counts as a reference.
        let archivePrefix = url.deletingPathExtension().lastPathComponent + ".corrupt-"
        var referenced = ids
        for archive in siblings where archive.lastPathComponent == backupURL.lastPathComponent
                                   || archive.lastPathComponent.hasPrefix(archivePrefix) {
            guard let data = try? Data(contentsOf: archive) else { return }
            let pattern = /[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/
            referenced.formUnion(String(decoding: data, as: UTF8.self).matches(of: pattern).compactMap { UUID(uuidString: String($0.output)) })
        }
        for file in files where file.pathExtension == "json" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !referenced.contains(id) else { continue }
            try? fm.removeItem(at: file)
        }
    }
    /// Aligns the backup with the manifest just saved, so recovery cannot restore what it dropped.
    func refreshBackup() throws {
        _ = try decode(url)
        try Data(contentsOf: url).write(to: backupURL, options: .atomic)
    }
    /// The engine follows the sidecar that exists: a build that knows only the Rust engine may
    /// have rewritten the manifest without its `engine` hint, or with a load error of its own.
    func restoreSession(_ saved: WorkspaceSnapshot.Conversation) -> TaskStore.Snapshot {
        let unreadable = "Agent 历史无法读取，已禁止执行。请恢复会话文件后重新打开应用。"
        let native = nativeSessionURL(saved.id)
        if FileManager.default.fileExists(atPath: native.path) || saved.state.engine == .native {
            do {
                var state = try JSONDecoder().decode(TaskStore.Snapshot.self, from: Data(contentsOf: native))
                guard state.native != nil else { throw CocoaError(.fileReadCorruptFile) }
                state.engine = .native; state.loadError = nil
                return state
            } catch {
                var state = saved.state
                state.engine = .native; state.agentStored = true; state.loadError = unreadable
                return state
            }
        }
        guard saved.state.agentStored == true else { return saved.state }
        do { return try JSONDecoder().decode(TaskStore.Snapshot.self, from: Data(contentsOf: sessionURL(saved.id))) }
        catch {
            var state = saved.state
            state.loadError = unreadable
            return state
        }
    }
    func load() -> (WorkspaceSnapshot?, String?) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (nil, nil) }
        do { return (try decode(url), nil) }
        catch {
            // Preserve the unreadable archive before any subsequent save replaces it.
            let preserved = url.deletingPathExtension().appendingPathExtension("corrupt-\(UUID().uuidString).json")
            do { try FileManager.default.copyItem(at: url, to: preserved) }
            catch { return (nil, "无法备份损坏的会话文件：\(error.localizedDescription)") }
            if let backup = try? decode(backupURL) {
                return (backup, "会话文件无法读取，已从备份恢复；原文件已保留。")
            }
            return (nil, "会话文件无法读取，原文件已保留。已打开空白工作区。")
        }
    }
    func save(_ snapshot: WorkspaceSnapshot) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var compact = snapshot
        func reference(_ saved: WorkspaceSnapshot.Conversation) throws -> WorkspaceSnapshot.Conversation {
            var result = saved
            if saved.state.tools != nil && saved.state.loadError == nil {
                try saveSession(saved.state, id: saved.id)
                result.state.messages = []; result.state.tools = nil; result.state.agentHistory = nil
                result.state.inputReceipts = nil; result.state.pendingInputs = nil
                result.state.agentProjection = nil; result.state.savedCheckpoint = nil; result.state.deliveredReplies = nil
                result.state.native = nil
                result.state.agentStored = true
            }
            return result
        }
        compact.conversations = try compact.conversations.map(reference)
        compact.drafts = try compact.drafts?.map(reference)
        let data = try encoder.encode(compact)
        if (try? decode(url)) != nil {
            try Data(contentsOf: url).write(to: backupURL, options: .atomic)
        }
        try data.write(to: url, options: .atomic)
    }
}

@MainActor final class WorkspaceStore: ObservableObject {
    let fileBrowser = ProjectFileBrowserStore()
    let voice: VoiceSessionController
    let dictation: DictationController
    @Published private(set) var projects: [WorkspaceProject] = [] {
        didSet { synchronizeFileBrowser() }
    }
    @Published private(set) var conversations: [WorkspaceConversation] = []
    @Published private(set) var selectedID: UUID? {
        didSet {
            if oldValue != selectedID { fileBrowser.collapsePreview() }
            synchronizeFileBrowser()
            markViewedActivitySeen()
        }
    }
    @Published private(set) var composerFocusRequest = 0
    private(set) var composerFocusID: UUID?
    private var drafts: [WorkspaceConversation] = []
    @Published private(set) var activityID: UUID?
    @Published var isMainWindowVisible = false {
        didSet {
            if !isMainWindowVisible { dictation.cancel() }
            markViewedActivitySeen()
        }
    }
    @Published var persistenceNotice: String?
    var onRevealVoice: ((UUID) -> Void)?
    private let emptyActivity = TaskStore()
    private let sourceFactory: () -> (any TaskSource)?
    /// The native engine's source; nil keeps every conversation on `sourceFactory`.
    private let nativeSourceFactory: (() -> (any TaskSource)?)?
    /// Whether a conversation sent to for the first time uses the native engine.
    private let prefersNative: () -> Bool
    private let persistence: WorkspacePersistence?
    private var observations: [UUID: AnyCancellable] = [:]
    private var lifecycleObservations: [UUID: AnyCancellable] = [:]
    private var emptyObservation: AnyCancellable?
    private var saveWork: DispatchWorkItem?
    private var saveDeadline: DispatchTime?
    private var shuttingDown = false
    /// A Live Voice conversation whose completed replies have not been viewed. It becomes an
    /// unseen completion only when the voice session ends; until then the conversation is in progress.
    private var voiceCompletion: UUID?
    private var voiceObservation: AnyCancellable?
    private var saveBlocked = false
    // Keep display timestamps fixed for this app session. Persist actual interaction
    // times separately so only the next launch applies the new order.
    private var pendingRecency: [UUID: Date] = [:]
    private let directoryScheduler = AgentDirectoryScheduler()

    init(persistence: WorkspacePersistence? = nil,
         initialStore: TaskStore? = nil,
         dictation: DictationController = DictationController(),
         voice: VoiceSessionController = VoiceSessionController(),
         sourceFactory: @escaping () -> (any TaskSource)? = { nil },
         nativeSourceFactory: (() -> (any TaskSource)?)? = nil,
         prefersNative: @escaping () -> Bool = { false }) {
        self.dictation = dictation; self.voice = voice
        self.persistence = persistence
        self.sourceFactory = sourceFactory
        self.nativeSourceFactory = nativeSourceFactory
        self.prefersNative = prefersNative
        voiceObservation = voice.$snapshot.map { $0.session.owner == nil }.removeDuplicates().sink { [weak self] ended in
            if ended { self?.finishVoiceConversation() }
        }
        emptyObservation = emptyActivity.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.objectWillChange.send() }
        }
        if let initialStore {
            let conversation = WorkspaceConversation(store: initialStore)
            conversations = [conversation]; selectedID = conversation.id; activityID = conversation.id
            bind(conversation)
        } else if let persistence {
            let (snapshot, notice) = persistence.load()
            persistenceNotice = notice
            // A failed preservation must never be followed by overwriting the original archive.
            saveBlocked = notice?.hasPrefix("无法备份损坏") == true
            if let snapshot {
                if notice == nil {
                    persistence.pruneSessions(keeping: Set((snapshot.conversations + (snapshot.drafts ?? [])).map(\.id)))
                }
                projects = snapshot.projects
                conversations = snapshot.conversations.map { saved in
                    let (store, restored) = restoredStore(saved, persistence: persistence)
                    // Retitle only after the legacy demo cleanup changed what the conversation shows.
                    let title = !saved.manuallyNamed && store.engine != .native && store.messages != restored.messages
                        ? String((store.messages.first(where: { $0.role == .user })?.content ?? "新会话").prefix(60))
                        : saved.title
                    return WorkspaceConversation(id: saved.id,
                        projectID: projects.contains(where: { project in project.id == saved.projectID }) ? saved.projectID : nil,
                        title: title, manuallyNamed: saved.manuallyNamed, lastUsed: saved.lastUsed,
                        store: store)
                }
                drafts = (snapshot.drafts ?? []).map { saved in
                    WorkspaceConversation(id: saved.id,
                        projectID: projects.contains(where: { $0.id == saved.projectID }) ? saved.projectID : nil,
                        title: "新对话", lastUsed: saved.lastUsed,
                        store: restoredStore(saved, persistence: persistence).store)
                }
                // Restore history and drafts, but leave the previous session's
                // selection and desktop activity behind on every launch.
                (conversations + drafts).forEach(bind)
            }
            if selected == nil { _ = newConversation() }
        } else { _ = newConversation() }
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
    /// Completed runs whose card has not been expanded since, across all conversations.
    var unseenCompletedCount: Int { conversations.filter { $0.store.hasUnseenCompletion }.count }
    /// The pet's bell: an open card collapses; otherwise the newest unseen completion becomes
    /// the activity and expands, so each click views one completed task.
    func toggleActivityTray() {
        let current = activityStore
        if current.isActivityVisible { current.toggleActivities(); return }
        let unseen = conversations.compactMap { conversation in
            conversation.store.unseenCompletion.map { (conversation, $0) }
        }
        if let next = unseen.max(by: { $0.1 < $1.1 })?.0 {
            if activityID != next.id { activityID = next.id }
            next.store.expandActivity()
        } else if current.task != nil {
            current.expandActivity()
        }
    }
    var runningTaskCount: Int { conversations.filter { $0.store.isGenerating }.count }
    private func markViewedActivitySeen() {
        guard isMainWindowVisible else { return }
        selected?.store.markSeen()
        if voiceCompletion == selectedID { voiceCompletion = nil }
    }
    private func isViewing(_ id: UUID) -> Bool { isMainWindowVisible && selectedID == id }
    private func finishVoiceConversation() {
        guard let id = voiceCompletion else { return }
        voiceCompletion = nil
        guard !shuttingDown, !isViewing(id), let store = conversation(id: id)?.store else { return }
        store.collapseForCompletion(unseen: true)
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
    private var preferredEngine: AgentEngineKind? { nativeSourceFactory != nil && prefersNative() ? .native : nil }
    private func makeSource(_ engine: AgentEngineKind?) -> (any TaskSource)? {
        if engine == .native, let nativeSourceFactory { return nativeSourceFactory() }
        return sourceFactory()
    }
    /// A native conversation whose workspace gives it no native engine stays blocked: another
    /// engine would save its state to its own sidecar and fork the conversation.
    private func restoredStore(_ saved: WorkspaceSnapshot.Conversation,
                               persistence: WorkspacePersistence) -> (store: TaskStore, restored: TaskStore.Snapshot) {
        var restored = persistence.restoreSession(saved)
        let source = makeSource(restored.engine)
        if restored.engine == .native, !(source is AgentHarness) {
            // Keep the manifest's reference, not the history: saving must neither copy the
            // conversation into the manifest nor replace its sidecar.
            restored = saved.state
            restored.engine = .native; restored.agentStored = true
            restored.loadError = "此会话由 Foundation Models Agent 创建，当前无法打开，已禁止执行。"
        }
        return (TaskStore(snapshot: restored, source: source), restored)
    }
    @discardableResult func send(_ text: String, conversationID: UUID) -> Bool {
        guard !shuttingDown, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let target = conversation(id: conversationID), target.store.canSubmit else { return false }
        // The engine is chosen at a conversation's first send, from the setting at that moment.
        if target.store.isPristine, let preferred = preferredEngine ?? (nativeSourceFactory != nil ? .rust : nil),
           target.store.engine != preferred {
            target.store.adoptSource(makeSource(preferred))
        }
        if voice.conversationID == conversationID {
            guard voice.canSubmit else { return false }
            voice.prepareForSubmission()
            let accepted = target.store.send(text)
            voice.finishSubmission()
            return accepted
        }
        return target.store.send(text)
    }
    /// The pet's quick composer always starts its own conversation. It never reuses the
    /// main window's draft or changes the selection; the first send makes it the activity.
    @discardableResult func sendQuickMessage(_ text: String, projectID: UUID? = nil) -> Bool {
        guard !shuttingDown, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let conversation = makeDraft(projectID: validProjectID(projectID))
        if send(text, conversationID: conversation.id) { return true }
        if conversation.store.messages.isEmpty {
            conversation.store.shutdown(); observations[conversation.id] = nil; lifecycleObservations[conversation.id] = nil
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
        guard voice.activate(conversation: target, entry: "桌宠·新对话") else { return false }
        scheduleSave()
        return true
    }
    @discardableResult func sendMainMessage(conversationID: UUID) -> Bool {
        guard let target = conversation(id: conversationID), send(target.store.mainDraft, conversationID: conversationID) else { return false }
        target.store.mainDraft = ""
        return true
    }
    @discardableResult func sendFollowUp(conversationID: UUID) -> Bool {
        guard let target = conversation(id: conversationID), send(target.store.followUpDraft, conversationID: conversationID) else { return false }
        target.store.followUpDraft = ""
        if target.store.isFollowUpExpanded { target.store.toggleFollowUp() }
        return true
    }
    func stop(conversationID: UUID) {
        guard !shuttingDown, let target = conversation(id: conversationID) else { return }
        if voice.conversationID == conversationID { voice.stopReply() }
        else { target.store.stopTask() }
    }
    @discardableResult func retry(conversationID: UUID) -> Bool {
        guard !shuttingDown, let target = conversation(id: conversationID), target.store.canRetry else { return false }
        if voice.conversationID == conversationID {
            guard voice.canSubmit else { return false }
            voice.prepareForSubmission()
            let accepted = target.store.retry()
            voice.finishSubmission()
            return accepted
        }
        return target.store.retry()
    }
    @discardableResult func startVoice(conversationID: UUID) -> Bool {
        guard !shuttingDown, voice.snapshot.session.owner == nil,
              let target = conversation(id: conversationID) else { return false }
        return voice.activate(conversation: target, entry: "会话")
    }
    func stopVoiceReply(owner: VoiceSessionSnapshot.Owner) {
        guard voice.snapshot.session.owner == owner else { return }
        stop(conversationID: owner.conversationID)
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
        let targetID = conversationID ?? owner?.conversationID ?? voice.conversationID
        guard let targetID else { return }
        if selectedID != targetID { select(targetID) }
        requestComposerFocus(conversationID: targetID)
        isMainWindowVisible = true
        onRevealVoice?(targetID)
    }
    var snapshot: WorkspaceSnapshot {
        WorkspaceSnapshot(projects: projects, conversations: conversations.map {
            .init(id: $0.id, projectID: $0.projectID, title: $0.title, manuallyNamed: $0.manuallyNamed,
                  lastUsed: pendingRecency[$0.id] ?? $0.lastUsed, state: $0.store.snapshot)
        }, selectedID: selectedID, activityID: activityID, drafts: drafts.map {
            .init(id: $0.id, projectID: $0.projectID, title: $0.title, manuallyNamed: false,
                  lastUsed: $0.lastUsed, state: $0.store.snapshot)
        })
    }

    private func bind(_ conversation: WorkspaceConversation) {
        let id = conversation.id
        conversation.store.sessionID = id
        conversation.store.projectDirectory = { [weak self, weak conversation] in
            guard let self, let project = self.projects.first(where: { $0.id == conversation?.projectID }), project.isAvailable else { return nil }
            return URL(fileURLWithPath: project.path).resolvingSymlinksInPath().standardizedFileURL
        }
        conversation.store.checkpoint = { [weak self] state in
            guard let self else { throw CocoaError(.fileWriteUnknown) }
            if self.saveBlocked { throw CocoaError(.fileWriteNoPermission) }
            if let error = state.loadError { throw SettingsError(error) }
            try self.persistence?.saveSession(state, id: id)
            // Ensure a new conversation is discoverable before any tool starts.
            // The manifest stores references; tool updates write only this sidecar.
            if !self.persistedAgentIDs.contains(id) {
                try self.persistence?.save(self.snapshot)
                self.persistedAgentIDs.insert(id)
            }
        }
        let scheduler = directoryScheduler
        conversation.store.acquireDirectory = { path, ready in scheduler.acquire(path, owner: id, ready: ready) }
        conversation.store.cancelDirectoryWait = { scheduler.cancelWait(id) }
        conversation.store.releaseDirectory = { scheduler.release(id) }
        conversation.store.onUserAction = { [weak self] in self?.didUse(id) }
        conversation.store.onVisibilityChange = { [weak self] visible in self?.isMainWindowVisible = visible }
        lifecycleObservations[id] = conversation.store.lifecycle.sink { [weak self] event in
            guard let self, let target = self.conversation(id: id) else { return }
            switch event {
            case .started:
                // A new run supersedes the previous outcome.
                target.store.markSeen()
                // Folded before the companion next synchronizes, so the card never shows for a Live Voice turn.
                if self.voice.conversationID == id { target.store.foldActivity() }
            case .reply(_, .completed):
                // The conversation on screen already shows its reply; everywhere else it waits in the bell.
                // A Live Voice conversation is still in progress; it is counted when the voice session ends.
                let viewed = self.isViewing(id)
                if self.voice.conversationID == id { self.voiceCompletion = viewed ? nil : id }
                target.store.collapseForCompletion(unseen: !viewed && self.voice.conversationID != id)
                if target.store.usesAgent { self.fileBrowser.refresh(projectID: target.projectID) }
            case .reply(_, .failed):
                if !target.store.isActivityVisible { target.store.revealCollapsed() }
                if target.store.usesAgent { self.fileBrowser.refresh(projectID: target.projectID) }
            case .stopped:
                if target.store.usesAgent { self.fileBrowser.refresh(projectID: target.projectID) }
            default: break
            }
        }
        observations[id] = conversation.store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.shuttingDown, (self.conversations + self.drafts).contains(where: { $0.id == id }) else { return }
                self.objectWillChange.send()
                self.scheduleSave()
            }
        }
    }
    private var persistedAgentIDs: Set<UUID> = []
    private func didUse(_ id: UUID) {
        let usedAt = Date()
        // A blank composer becomes a sidebar conversation only after the first real message.
        if let draft = drafts.first(where: { $0.id == id }), !draft.store.messages.isEmpty {
            drafts.removeAll { $0.id == id }
            draft.lastUsed = usedAt
            conversations.append(draft)
        }
        guard let conversation = conversations.first(where: { $0.id == id }) else { return }
        objectWillChange.send()
        pendingRecency[id] = usedAt
        if !conversation.manuallyNamed, conversation.title == "新会话" || conversation.title == "新对话" {
            conversation.title = String((conversation.store.messages.first(where: { $0.role == .user })?.content ?? "新会话").prefix(60))
        }
        activityID = id
        scheduleSave()
    }
    @discardableResult func newConversation(projectID: UUID? = nil) -> WorkspaceConversation {
        let validProject = validProjectID(projectID)
        let conversation = reusableDraft(projectID: validProject) ?? makeDraft(projectID: validProject)
        if selectedID != conversation.id { dictation.cancel(); flush() }
        selectedID = conversation.id
        conversation.lastUsed = Date()
        composerFocusID = conversation.id; composerFocusRequest += 1
        scheduleSave()
        return conversation
    }
    func select(_ id: UUID) {
        guard id != selectedID, (conversations + drafts).contains(where: { $0.id == id }) else { return }
        dictation.cancel()
        flush()
        selectedID = id
        if let draft = drafts.first(where: { $0.id == id }) { draft.lastUsed = Date() }
        scheduleSave()
    }
    func revealActivity() {
        if let activityID, activityID != selectedID { select(activityID) }
        isMainWindowVisible = true
    }
    func renameConversation(_ id: UUID, to title: String) {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let conversation = conversations.first(where: { $0.id == id }) else { return }
        objectWillChange.send(); conversation.title = name; conversation.manuallyNamed = true
        scheduleSave()
    }
    func deleteConversation(_ id: UUID) {
        guard let conversation = (conversations + drafts).first(where: { $0.id == id }) else { return }
        if dictation.conversationID == id { dictation.cancel(discard: true) }
        if voice.conversationID == id { voice.end(reason: .conversationDeleted) }
        voice.clearError(conversationID: id)
        conversation.store.shutdown(); observations[id] = nil; lifecycleObservations[id] = nil
        pendingRecency[id] = nil
        conversations.removeAll { $0.id == id }
        drafts.removeAll { $0.id == id }
        if activityID == id { activityID = nil }
        if selectedID == id { selectedID = (conversations + drafts).max(by: { $0.lastUsed < $1.lastUsed })?.id }
        if conversations.isEmpty && drafts.isEmpty { _ = newConversation() }
        // Remove the history sidecar only once neither the manifest nor its backup references it.
        guard flush(), let persistence else { return }
        persistedAgentIDs.remove(id)
        do { try persistence.refreshBackup(); try persistence.removeSession(id) }
        catch { persistenceNotice = "会话记录删除失败：\(error.localizedDescription)" }
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
        guard !query.isEmpty else { return byRecency(conversations) }
        return byRecency(conversations.filter {
            $0.title.localizedStandardContains(query)
                || $0.store.messages.contains { $0.content.localizedStandardContains(query) }
        })
    }
    private func validProjectID(_ id: UUID?) -> UUID? { projects.contains { $0.id == id } ? id : nil }
    /// The most recent empty draft in `projectID` that can still take a project.
    private func reusableDraft(projectID: UUID?, excluding: UUID? = nil) -> WorkspaceConversation? {
        byRecency(drafts.filter { $0.id != excluding && $0.projectID == projectID && canAssociateProject(conversationID: $0.id) }).first
    }
    private func makeDraft(projectID: UUID?) -> WorkspaceConversation {
        let conversation = WorkspaceConversation(projectID: projectID, title: "新对话", store: TaskStore(source: makeSource(preferredEngine)))
        drafts.append(conversation); bind(conversation)
        return conversation
    }
    private func byRecency(_ conversations: [WorkspaceConversation]) -> [WorkspaceConversation] {
        conversations.sorted {
            if $0.lastUsed != $1.lastUsed { return $0.lastUsed > $1.lastUsed }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
    @discardableResult func addProject(url: URL) -> UUID {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        if let existing = projects.first(where: { $0.path == path }) { return existing.id }
        let project = WorkspaceProject(name: url.lastPathComponent, path: path)
        projects.append(project); scheduleSave(); return project.id
    }
    func renameProject(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[index].name = name; scheduleSave()
    }
    func relocateProject(_ id: UUID, to url: URL) {
        guard !projectIsActive(id) else { persistenceNotice = "任务活动期间不能重新定位项目。"; return }
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        guard !projects.contains(where: { $0.id != id && $0.path == path }) else {
            persistenceNotice = "该文件夹已属于另一个项目。"; return
        }
        projects[index].path = path; scheduleSave()
    }
    func removeProject(_ id: UUID) {
        guard !projectIsActive(id) else { persistenceNotice = "任务活动期间不能解除项目关联。"; return }
        objectWillChange.send()
        (conversations + drafts).filter { $0.projectID == id }.forEach { $0.projectID = nil }
        projects.removeAll { $0.id == id }; flush()
    }
    func projectIsActive(_ id: UUID) -> Bool {
        (conversations + drafts).contains { $0.projectID == id && $0.store.isGenerating }
    }
    @discardableResult func associateProject(_ projectID: UUID?, conversationID: UUID) -> Bool {
        guard canAssociateProject(conversationID: conversationID),
              let conversation = conversation(id: conversationID) else { return false }
        if let projectID, !projects.contains(where: { $0.id == projectID && $0.isAvailable }) { return false }
        objectWillChange.send()
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
    func provideDirectory(_ url: URL?, conversationID: UUID) {
        guard let conversation = conversation(id: conversationID), conversation.store.needsDirectory else { return }
        if let url {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                persistenceNotice = "所选文件夹不可用，请重新选择。"; return
            }
            guard !saveBlocked else {
                persistenceNotice = Self.saveBlockedNotice; conversation.store.stopTask(); return
            }
            let previousProject = conversation.projectID, knownProjects = Set(projects.map(\.id))
            objectWillChange.send(); conversation.projectID = addProject(url: url)
            synchronizeFileBrowser()
            // Persist the binding before letting the pending call proceed.
            do { try persistence?.save(snapshot) }
            catch {
                // A call that will not run leaves no unsaved binding behind.
                conversation.projectID = previousProject
                projects.removeAll { !knownProjects.contains($0.id) }
                synchronizeFileBrowser()
                persistenceNotice = error.localizedDescription; conversation.store.stopTask(); return
            }
        }
        conversation.store.provideDirectory(url?.resolvingSymlinksInPath().standardizedFileURL)
    }

    func prepareForTermination() async {
        shuttingDown = true; dictation.shutdown(); voice.shutdown()
        let stores = (conversations + drafts).map(\.store)
        stores.forEach { $0.stopTask() }
        while stores.contains(where: \.isGenerating) {
            try? await Task.sleep(for: .milliseconds(20))
        }
        flush()
        stores.forEach { $0.shutdown() }
        await AgentBridge.waitForShutdown()
        await ExecutionService.waitForShutdown()
    }
    private func scheduleSave() {
        guard !shuttingDown else { return }
        let now = DispatchTime.now()
        // Keep the trailing debounce, but continuous updates cannot postpone a
        // checkpoint more than two seconds after the first unsaved change.
        let deadline = saveDeadline ?? (now + 2)
        saveDeadline = deadline
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { _ = self?.flush() } }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: min(now + 0.4, deadline), execute: work)
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
            try VoiceDiagnostics.shared.measure("WorkspaceStore.flush", quietAfter: .seconds(10)) { try persistence.save(snapshot) }
            return true
        }
        catch { persistenceNotice = "会话保存失败：\(error.localizedDescription)"; return false }
    }
    private static let saveBlockedNotice = "无法备份损坏的会话文件；为保留原件，保存已暂停。请恢复目录写入权限后重新打开应用。"
    func shutdown() {
        fileBrowser.select(project: nil)
        dictation.shutdown()
        voiceObservation = nil
        voice.shutdown()
        shuttingDown = true; flush(); observations.removeAll(); lifecycleObservations.removeAll(); emptyObservation = nil
        (conversations + drafts).forEach { $0.store.shutdown() }
    }
}
