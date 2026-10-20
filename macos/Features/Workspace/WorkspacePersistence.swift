import Foundation

struct WorkspaceSnapshot: Codable {
    struct Conversation: Codable {
        var id: UUID
        var projectID: UUID?
        var title: String
        var manuallyNamed: Bool
        /// Written only while the conversation is untitled.
        var untitled: Bool? = nil
        var lastUsed: Date
        var state: TaskStore.Snapshot
        var isUntitled: Bool { untitled ?? false }
    }
    var version = 1
    var projects: [WorkspaceProject]
    var conversations: [Conversation]
    var selectedID: UUID?
    var activityID: UUID?
    var drafts: [Conversation]? = nil
    var allConversations: [Conversation] { conversations + (drafts ?? []) }
}

/// Accessed on the main actor: mutations and atomic saves have a single ordered writer.
@MainActor final class WorkspacePersistence {
    let url: URL
    var backupURL: URL { url.appendingPathExtension("backup") }
    init(url: URL) { self.url = url }
    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("io.github.houbaoshu.echo/workspace.json")
    }
    private func decode(_ data: Data) throws -> WorkspaceSnapshot {
        let result = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
        let all = result.allConversations
        guard result.version == 1, Set(all.map(\.id)).count == all.count,
              Set(result.projects.map(\.id)).count == result.projects.count else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return result
    }
    private func decode(_ url: URL) throws -> WorkspaceSnapshot { try decode(Data(contentsOf: url)) }
    /// Agent conversations keep their history in a sidecar here; the manifest holds a reference.
    var sessionsDirectory: URL { url.deletingLastPathComponent().appendingPathComponent("agent-sessions-v2") }
    func sessionURL(_ id: UUID) -> URL {
        sessionsDirectory.appendingPathComponent("\(id.uuidString).json")
    }
    static var unreadableHistory: String { String(localized: "Agent 历史无法读取，已禁止执行。请恢复聊天文件后重新打开应用。") }
    func saveSession(_ state: TaskStore.Snapshot, id: UUID) throws {
        let target = sessionURL(id)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        // Only a changed conversation is written.
        if (try? Data(contentsOf: target)) == data { return }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
    }
    func removeSession(_ id: UUID) throws { try removeIfPresent(sessionURL(id)) }
    /// Copies of the files each conversation's Agent replaced, one folder per conversation.
    var backupsDirectory: URL { url.deletingLastPathComponent().appendingPathComponent("agent-backups") }
    func backupDirectory(_ id: UUID) -> URL { backupsDirectory.appendingPathComponent(id.uuidString) }
    func removeBackups(_ id: UUID) throws { try removeIfPresent(backupDirectory(id)) }
    private func removeIfPresent(_ url: URL) throws {
        do { try FileManager.default.removeItem(at: url) }
        catch CocoaError.fileNoSuchFile {}
    }
    /// Deletes sidecars no manifest conversation references, such as those left by deletions before
    /// sessions were removed. Only call after the manifest itself loaded cleanly.
    func pruneSessions(keeping ids: Set<UUID>) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: sessionsDirectory, includingPropertiesForKeys: nil), !files.isEmpty,
              let siblings = try? fm.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil) else { return }
        // The backup and archives preserved by `load` may be the only way back to a history.
        // They need not decode, so any UUID text in them counts as a reference.
        let archivePrefix = url.deletingPathExtension().lastPathComponent + ".corrupt-"
        let pattern = /[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/
        var referenced = ids
        for archive in siblings where archive.lastPathComponent == backupURL.lastPathComponent
                                   || archive.lastPathComponent.hasPrefix(archivePrefix) {
            guard let data = try? Data(contentsOf: archive) else { return }
            referenced.formUnion(String(decoding: data, as: UTF8.self).matches(of: pattern).compactMap { UUID(uuidString: String($0.output)) })
        }
        for file in files where file.pathExtension == "json" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !referenced.contains(id) else { continue }
            try? fm.removeItem(at: file)
        }
    }
    /// Aligns the backup with the manifest just saved, so recovery cannot restore what it dropped.
    func refreshBackup() throws {
        let data = try Data(contentsOf: url)
        _ = try decode(data)
        try data.write(to: backupURL, options: .atomic)
    }
    /// A conversation's saved state. Only the native sidecar is history: when it is missing, an
    /// Agent conversation, or one whose messages are only in the manifest, is blocked as
    /// unreadable, and what it saved is left as it is until it is deleted.
    func restoreSession(_ saved: WorkspaceSnapshot.Conversation) -> TaskStore.Snapshot {
        if FileManager.default.fileExists(atPath: sessionURL(saved.id).path) {
            do {
                var state = try JSONDecoder().decode(TaskStore.Snapshot.self, from: Data(contentsOf: sessionURL(saved.id)))
                guard state.native != nil else { throw CocoaError(.fileReadCorruptFile) }
                state.loadError = nil
                return state
            } catch {
                var state = saved.state
                state.agentStored = true; state.loadError = Self.unreadableHistory
                return state
            }
        }
        var state = saved.state
        // The manifest never holds native history: only the sidecar does.
        state.native = nil
        // A load error saved with a manifest conversation is recomputed on every launch.
        state.loadError = saved.state.agentStored == true || !state.messages.isEmpty ? Self.unreadableHistory : nil
        return state
    }
    /// Why `load` did not hand back the archive as it is on disk.
    enum LoadProblem {
        /// The unreadable archive could not be set aside, so nothing may save over it.
        case preservationFailed(String)
        case restoredFromBackup
        case unreadable
        var message: String {
            switch self {
            case .preservationFailed(let reason): String(localized: "无法备份损坏的聊天文件：\(reason)")
            case .restoredFromBackup: String(localized: "聊天文件无法读取，已从备份恢复；原文件已保留。")
            case .unreadable: String(localized: "聊天文件无法读取，原文件已保留。已打开空白工作区。")
            }
        }
    }
    func load() -> (WorkspaceSnapshot?, LoadProblem?) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (nil, nil) }
        do { return (try decode(url), nil) }
        catch {
            // Preserve the unreadable archive before any subsequent save replaces it.
            let preserved = url.deletingPathExtension().appendingPathExtension("corrupt-\(UUID().uuidString).json")
            do { try FileManager.default.copyItem(at: url, to: preserved) }
            catch { return (nil, .preservationFailed(error.localizedDescription)) }
            if let backup = try? decode(backupURL) { return (backup, .restoredFromBackup) }
            return (nil, .unreadable)
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
                result.state.messages = []; result.state.tools = nil
                result.state.native = nil
                result.state.agentStored = true
            }
            return result
        }
        compact.conversations = try compact.conversations.map(reference)
        compact.drafts = try compact.drafts?.map(reference)
        let data = try encoder.encode(compact)
        if let existing = try? Data(contentsOf: url), (try? decode(existing)) != nil {
            try existing.write(to: backupURL, options: .atomic)
        }
        try data.write(to: url, options: .atomic)
    }
}
