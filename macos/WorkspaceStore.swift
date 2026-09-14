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
    func sessionURL(_ id: UUID) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("agent-sessions/\(id.uuidString).json")
    }
    func saveSession(_ state: TaskStore.Snapshot, id: UUID) throws {
        let target = sessionURL(id)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        if (try? Data(contentsOf: target)) == data { return }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
    }
    func restoreSession(_ saved: WorkspaceSnapshot.Conversation) -> TaskStore.Snapshot {
        guard saved.state.agentStored == true else { return saved.state }
        do { return try JSONDecoder().decode(TaskStore.Snapshot.self, from: Data(contentsOf: sessionURL(saved.id))) }
        catch {
            var state = saved.state
            state.loadError = "Agent 历史无法读取，已禁止执行。请恢复会话文件后重新打开应用。"
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
        }
    }
    @Published private(set) var composerFocusRequest = 0
    private(set) var composerFocusID: UUID?
    private var drafts: [WorkspaceConversation] = []
    @Published private(set) var activityID: UUID?
    @Published var isMainWindowVisible = false {
        didSet { if !isMainWindowVisible { dictation.cancel() } }
    }
    @Published var searchText = ""
    @Published var searchFocusRequest = 0
    @Published var persistenceNotice: String?
    var onRevealVoice: ((UUID) -> Void)?
    private let emptyActivity = TaskStore()
    private let sourceFactory: () -> (any TaskSource)?
    private let persistence: WorkspacePersistence?
    private var observations: [UUID: AnyCancellable] = [:]
    private var lifecycleObservations: [UUID: AnyCancellable] = [:]
    private var emptyObservation: AnyCancellable?
    private var saveWork: DispatchWorkItem?
    private var saveDeadline: DispatchTime?
    private var shuttingDown = false
    private var saveBlocked = false
    // Keep display timestamps fixed for this app session. Persist actual interaction
    // times separately so only the next launch applies the new order.
    private var pendingRecency: [UUID: Date] = [:]
    private let directoryScheduler = AgentDirectoryScheduler()

    init(persistence: WorkspacePersistence? = nil,
         initialStore: TaskStore? = nil,
         dictation: DictationController = DictationController(),
         voice: VoiceSessionController = VoiceSessionController(),
         sourceFactory: @escaping () -> (any TaskSource)? = { nil }) {
        self.dictation = dictation; self.voice = voice
        self.persistence = persistence
        self.sourceFactory = sourceFactory
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
                projects = snapshot.projects
                conversations = snapshot.conversations.map { saved in
                    let restored = persistence.restoreSession(saved)
                    let store = TaskStore(snapshot: restored, source: sourceFactory())
                    let title = !saved.manuallyNamed && store.messages != restored.messages
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
                        store: TaskStore(snapshot: persistence.restoreSession(saved), source: sourceFactory()))
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
    private func synchronizeFileBrowser() {
        fileBrowser.select(project: selectedID.flatMap { project(for: $0) })
    }
    func canAssociateProject(conversationID: UUID) -> Bool {
        guard !shuttingDown, let store = conversation(id: conversationID)?.store else { return false }
        return store.messages.isEmpty && store.tools.isEmpty && !store.isGenerating && store.agentLoadError == nil
    }

    // Commands capture their target at the surface that issued them. Selection and
    // desktop activity are navigation state, never an implicit command destination.
    @discardableResult func send(_ text: String, conversationID: UUID) -> Bool {
        guard !shuttingDown, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let target = conversation(id: conversationID), target.store.canSubmit else { return false }
        if voice.conversationID == conversationID {
            guard voice.canSubmit else { return false }
            voice.prepareForSubmission()
            let accepted = target.store.send(text)
            voice.finishSubmission()
            return accepted
        }
        return target.store.send(text)
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
        return voice.activate(conversation: target)
    }
    func stopVoiceReply(owner: VoiceSessionSnapshot.Owner) {
        guard voice.snapshot.session.owner == owner else { return }
        stop(conversationID: owner.conversationID)
    }
    func endVoice(owner: VoiceSessionSnapshot.Owner) {
        guard voice.snapshot.session.owner == owner else { return }
        voice.end()
    }
    func toggleVoiceMute(owner: VoiceSessionSnapshot.Owner) {
        guard voice.snapshot.session.owner == owner else { return }
        voice.toggleMute()
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
            guard let self, let target = self.conversation(id: id), target.store.usesAgent else { return }
            switch event {
            case .reply(_, .completed), .reply(_, .failed), .stopped:
                self.fileBrowser.refresh(projectID: target.projectID)
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
        let validProject = projects.contains { $0.id == projectID } ? projectID : nil
        let conversation: WorkspaceConversation
        if let existing = drafts.filter({ $0.projectID == validProject && canAssociateProject(conversationID: $0.id) })
            .sorted(by: { $0.lastUsed == $1.lastUsed ? $0.id.uuidString < $1.id.uuidString : $0.lastUsed > $1.lastUsed }).first {
            conversation = existing
        } else {
            conversation = WorkspaceConversation(projectID: validProject, title: "新对话", store: TaskStore(source: sourceFactory()))
            drafts.append(conversation); bind(conversation)
        }
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
        if voice.conversationID == id { voice.end() }
        voice.clearError(conversationID: id)
        conversation.store.shutdown(); observations[id] = nil; lifecycleObservations[id] = nil
        pendingRecency[id] = nil
        conversations.removeAll { $0.id == id }
        drafts.removeAll { $0.id == id }
        if activityID == id { activityID = nil }
        if selectedID == id { selectedID = (conversations + drafts).max(by: { $0.lastUsed < $1.lastUsed })?.id }
        if conversations.isEmpty && drafts.isEmpty { _ = newConversation() }
        flush()
    }
    var recentConversations: [WorkspaceConversation] { filteredAndSorted(conversations) }
    func filteredConversations(projectID: UUID?) -> [WorkspaceConversation] {
        filteredAndSorted(conversations.filter { $0.projectID == projectID })
    }
    private func filteredAndSorted(_ conversations: [WorkspaceConversation]) -> [WorkspaceConversation] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return conversations.filter {
            query.isEmpty || $0.title.localizedStandardContains(query)
                || $0.store.messages.contains(where: { $0.content.localizedStandardContains(query) })
        }.sorted {
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
            objectWillChange.send(); conversation.projectID = addProject(url: url)
            synchronizeFileBrowser()
            // Persist the binding before letting the pending call proceed.
            do { try persistence?.save(snapshot) }
            catch { persistenceNotice = error.localizedDescription; conversation.store.stopTask(); return }
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
    }
    private func scheduleSave() {
        guard !shuttingDown else { return }
        let now = DispatchTime.now()
        // Keep the trailing debounce, but continuous updates cannot postpone a
        // checkpoint more than two seconds after the first unsaved change.
        let deadline = saveDeadline ?? (now + 2)
        saveDeadline = deadline
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.flush() } }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: min(now + 0.4, deadline), execute: work)
    }
    func flush() {
        saveWork?.cancel(); saveWork = nil; saveDeadline = nil
        guard let persistence else { return }
        guard !saveBlocked else {
            persistenceNotice = "无法备份损坏的会话文件；为保留原件，保存已暂停。请恢复目录写入权限后重新打开应用。"
            return
        }
        do { try persistence.save(snapshot) }
        catch { persistenceNotice = "会话保存失败：\(error.localizedDescription)" }
    }
    func shutdown() {
        fileBrowser.select(project: nil)
        dictation.shutdown()
        voice.shutdown()
        shuttingDown = true; flush(); observations.removeAll(); lifecycleObservations.removeAll(); emptyObservation = nil
        (conversations + drafts).forEach { $0.store.shutdown() }
    }
}
