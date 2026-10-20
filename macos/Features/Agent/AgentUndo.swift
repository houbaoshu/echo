import Darwin
import Foundation

/// Records of the write tools' changes, one folder per change in this chat's folder: for a file
/// replaced, the original's bytes; for every change, a record of where it was, what described the
/// original, and the fingerprint of what was written, written last, so a folder with a record is
/// whole. Undo restores files from these.
struct AgentBackupStore {
    struct Record: Codable, Equatable {
        /// Where the file was, absolute.
        var path: String
        /// The project or Finder folder the call wrote in, absolute, and which of the two it was;
        /// for a memory call, the memory file's folder and `AgentBackupStore.memoryRoot`.
        var root: String
        var rootKind: String
        /// The path the call named, relative to `root`.
        var relativePath: String
        var chat: UUID
        /// The call's card: `AgentToolRecord.id`, which is "turn:entry:call ID".
        var toolRecord: String
        var tool: String
        var savedAt: Date
        /// The original's permission bits and size; none for a new file.
        var mode: Int?
        var size: Int?
        /// The original's creation date and extended attributes, all of them, as it had them; none
        /// for a new file. `created` is to the second, `createdTime` exact.
        var created: Date?
        var attributes: [String: Data]?
        /// What the call did: "created", "overwritten" or "edited". Records kept before undo existed
        /// have none of the fields from here on, and their changes cannot be undone.
        var action: String?
        /// `AgentFileWriter.fingerprint` of the content the call wrote.
        var written: String?
        var createdTime: FileTime?
        /// The original's access control list, as `AgentFileDescription.acl`; none when it had none,
        /// and in records kept before lists were carried over.
        var acl: String?

        struct FileTime: Codable, Equatable {
            var seconds: Int
            var nanoseconds: Int
            init(_ time: Darwin.timespec) { seconds = time.tv_sec; nanoseconds = time.tv_nsec }
            var value: Darwin.timespec { .init(tv_sec: seconds, tv_nsec: nanoseconds) }
        }

        init(path: String, root: String, rootKind: String, relativePath: String, chat: UUID, toolRecord: String, tool: String,
             savedAt: Date, original: AgentOriginalFile?, action: String, written: Data) {
            self.path = path; self.root = root; self.rootKind = rootKind; self.relativePath = relativePath
            self.chat = chat; self.toolRecord = toolRecord; self.tool = tool; self.savedAt = savedAt
            self.action = action; self.written = AgentFileWriter.fingerprint(written)
            if let original {
                mode = Int(original.mode); size = original.data.count; attributes = original.attributes
                created = Date(timeIntervalSince1970: TimeInterval(original.created.tv_sec) + TimeInterval(original.created.tv_nsec) / 1e9)
                createdTime = FileTime(original.created)
                acl = original.acl
            }
        }

        /// What described the original, for an undo to put back.
        var original: AgentFileDescription? {
            guard let mode, let createdTime else { return nil }
            return .init(mode: mode_t(mode), attributes: attributes ?? [:], created: createdTime.value, acl: acl)
        }
    }
    static let recordName = "backup.json"
    /// `Record.rootKind` of a change to the memory file.
    static let memoryRoot = "memory"
    static let originalName = "original"

    /// This chat's folder of copies.
    let directory: URL

    /// Keeps a record of a change, with a copy of `original` when it replaced a file. Returns the record's folder.
    @discardableResult func save(_ original: AgentOriginalFile?, record: Record) throws -> URL {
        let fm = FileManager.default
        let stamp = Int(record.savedAt.timeIntervalSince1970 * 1000)
        let folder = directory.appendingPathComponent("\(stamp)-\(UUID().uuidString)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            if let original {
                guard fm.createFile(atPath: folder.appendingPathComponent(Self.originalName).path, contents: original.data,
                                    attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(record).write(to: folder.appendingPathComponent(Self.recordName), options: .atomic)
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
        return folder
    }

    /// The newest record of the change `toolRecord` names, and its folder.
    func find(toolRecord: String) -> (record: Record, folder: URL)? {
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return folders.sorted { $0.lastPathComponent > $1.lastPathComponent }.lazy.compactMap { folder in
            (try? Data(contentsOf: folder.appendingPathComponent(Self.recordName)))
                .flatMap { try? decoder.decode(Record.self, from: $0) }
                .flatMap { $0.toolRecord == toolRecord ? ($0, folder) : nil }
        }.first
    }
}

/// Moves a file a write created to the Trash when its change is undone, and an imported pet or
/// planet's folder when it is deleted from settings.
struct AgentTrash: Sendable {
    let move: @Sendable (URL) throws -> Void
    static let system = AgentTrash { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
}

/// Why a change was not undone, for a file or a reminder or event. Raw values are what archives store.
enum AgentUndoRefusal: Codable, Equatable, Sendable {
    /// The file no longer has what the call wrote.
    case changed
    case missing
    case symbolicLink
    case notFile
    /// The location can only be read, as for the write tools.
    case readOnly
    case backupMissing
    /// The system refused; the reason as it said it.
    case failed(String)
    /// The reminder or event is no longer as Echo's change left it: its modification date differs.
    case reminderChanged, eventChanged
    case reminderMissing, eventMissing
    case noRemindersAccess, noCalendarAccess
    /// The memory no longer has what the call left in it.
    case memoryChanged

    var message: String {
        switch self {
        case .changed: String(localized: "文件在写入之后又被改过，没有撤销。")
        case .missing: String(localized: "文件已不在原来的位置，没有撤销。")
        case .symbolicLink: String(localized: "原来的位置现在是符号链接，没有撤销。")
        case .notFile: String(localized: "原来的位置现在不是普通文件，没有撤销。")
        case .readOnly: String(localized: "这个位置只能读取，没有撤销。")
        case .backupMissing: String(localized: "找不到这次改动的备份，没有撤销。")
        case .failed(let reason): String(localized: "没有撤销：\(reason)")
        case .reminderChanged: String(localized: "这条提醒事项后来又被改过，没有撤销。")
        case .eventChanged: String(localized: "这个日程后来又被改过，没有撤销。")
        case .reminderMissing: String(localized: "这条提醒事项已经不在了，没有撤销。")
        case .eventMissing: String(localized: "这个日程已经不在了，没有撤销。")
        case .noRemindersAccess: String(localized: "Echo 没有提醒事项的访问权限，没有撤销。")
        case .noCalendarAccess: String(localized: "Echo 没有日历的访问权限，没有撤销。")
        case .memoryChanged: String(localized: "记忆在这次改动之后又变过，没有撤销。")
        }
    }
}

/// Puts a file back as it was before one write call, while it still has exactly what that call
/// wrote: a replaced file gets its original bytes, permission bits, extended attributes, access
/// control list and creation date back, through a temporary file renamed over it, as a write does; a new file goes
/// to the Trash, and the folders made for it stay. The path is checked as a write checks it, from
/// the root's descriptor without following symbolic links. Runs off the main actor: reading the file
/// can wait for it to download.
enum AgentFileUndo {
    /// Attributes an undo does not put back: the system's own record of which app wrote the file
    /// and which apps may open it. The original's text encoding comes back with its bytes.
    static let attributesNotRestored: Set<String> = ["com.apple.provenance", "com.apple.macl"]

    /// Nil when the change was undone. `memory` is the memory file's folder, canonical: a memory
    /// record is undone only there, the one folder outside the write tools' reach that it may change.
    static func undo(_ record: AgentBackupStore.Record, copy folder: URL, policy: AgentWritePolicy = AgentWritePolicy(),
                     memory: String? = nil, trash: AgentTrash = .system) -> AgentUndoRefusal? {
        guard let written = record.written, let action = record.action else { return .backupMissing }
        if record.rootKind == AgentBackupStore.memoryRoot {
            guard let memory, record.root == memory, record.relativePath == AgentMemoryFile.fileName else { return .backupMissing }
        } else {
            guard policy.refusal(folder: record.root, scope: AgentReadScope(rawValue: record.rootKind) ?? .project) == nil else { return .readOnly }
        }
        guard let path = AgentToolPath.normalize(record.relativePath) else { return .readOnly }
        let parts = path.split(separator: "/")
        guard AgentWritePolicy.refusal(path: parts, raw: path) == nil else { return .readOnly }
        let folders = parts.dropLast().map(String.init), name = String(parts.last!)

        var fd = open(record.root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return refusal(errno, in: AT_FDCWD, record.root) }
        defer { close(fd) }
        for folder in folders {
            let next = openat(fd, folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { return refusal(errno, in: fd, folder) }
            close(fd); fd = next
        }
        var info = stat()
        guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return refusal(errno, in: fd, name) }
        switch info.st_mode & S_IFMT {
        case S_IFLNK: return .symbolicLink
        case S_IFREG: break
        default: return .notFile
        }
        // Echo never writes an executable file, or a text file over 4 MiB, so such a file was changed since.
        let limit = AgentHarness.imageTools.contains(record.tool) ? AgentImageFiles.maxBytes : AgentFileWriter.maxFileBytes
        guard info.st_mode & 0o111 == 0, info.st_size <= limit else { return .changed }
        let current: AgentOriginalFile
        switch AgentFileWriter.read(fd, name, path: record.root + "/" + path, limit: limit) {
        case .success(let file): current = file
        case .failure(let error): return refusal(error.code, in: fd, name)
        }
        guard current.device == info.st_dev, current.inode == info.st_ino,
              AgentFileWriter.fingerprint(current.data) == written else { return .changed }

        // Read without the lock, since reading can wait for a download; under it, the file must
        // still be the one read, so no write or undo from another chat comes between.
        let directory = fd
        return AgentFileWriter.changes.withLock { _ in
            var now = stat()
            guard fstatat(directory, name, &now, AT_SYMLINK_NOFOLLOW) == 0, current.isSame(as: now) else { return .changed }
            if action == "created" {
                do { try trash.move(URL(fileURLWithPath: record.root).appendingPathComponent(path)) }
                catch { return .failed(error.localizedDescription) }
                return nil
            }
            guard let original = record.original,
                  let data = try? Data(contentsOf: folder.appendingPathComponent(AgentBackupStore.originalName)),
                  data.count == record.size else { return .backupMissing }
            switch AgentFileWriter.replace(in: directory, name: name, with: data, like: original, skipping: attributesNotRestored) {
            case .none: return nil
            case .system(let code): return .failed(String(cString: strerror(code)))
            case .attribute(let attribute, let code): return .failed("\(attribute): \(String(cString: strerror(code)))")
            }
        }
    }

    /// Why `name` in `directory` could not be opened, from what is there now.
    private static func refusal(_ code: Int32, in directory: Int32, _ name: String) -> AgentUndoRefusal {
        var info = stat()
        if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            switch info.st_mode & S_IFMT {
            case S_IFLNK: return .symbolicLink
            // A file where a folder was: the path no longer leads to it.
            case S_IFDIR: break
            default: if code == ENOTDIR { return .missing }
            }
        }
        switch code {
        case ENOENT: return .missing
        case ELOOP: return .symbolicLink
        default: return .failed(String(cString: strerror(code)))
        }
    }
}
