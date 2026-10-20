import CryptoKit
import Darwin
import Foundation
import FoundationModels
import Synchronization

/// What a write call asks for. The harness runs it in its turn: after every call written before it
/// in its batch, with the call saved before anything on disk changes.
struct AgentWriteRequest: Sendable {
    enum Change: Sendable {
        /// write_file: the whole new content.
        case replace(String)
        /// edit_file: one exact passage and what replaces it.
        case edit(old: String, new: String)
        /// The new content worked out from the original, nil when there is none: the memory tools'.
        case derive(@Sendable (Data?) -> Result<Data, AgentInvalidArguments>)
    }
    var path: String
    var change: Change
}

/// Arguments a tool could not read; the call still takes its turn, with this as its result.
struct AgentInvalidArguments: Error {
    let result: String

    static func failed(_ detail: String) -> Self { Self(result: AgentToolResult.failed(detail)) }

    /// Arguments `tool` cannot read: what it expected, `shape` written as JSON with types for values,
    /// and what it received.
    static func expected(_ shape: String, by tool: String, received arguments: GeneratedContent) -> Self {
        failed("invalid arguments for \(tool); expected \(shape). Received: \(arguments.jsonString)")
    }
}

/// Runs write calls for the conversation.
protocol AgentWriteAccess: Sendable {
    /// `call` links the call to the one the harness saw dispatched, as for finder_location.
    func write(call: GenerationID?, _ request: Result<AgentWriteRequest, AgentInvalidArguments>) async throws -> String
}

struct WriteFileTool: Tool {
    let name = "write_file"
    let description = "Create a UTF-8 text file in the workspace, or replace one in full"
    let access: any AgentWriteAccess

    @Generable
    struct Input {
        @Guide(description: "File path relative to the root; missing folders on the way are created")
        var path: String
        @Guide(description: "The file's whole new content")
        var content: String
    }

    var parameters: GenerationSchema { Input.generationSchema }

    @concurrent func call(arguments: GeneratedContent) async throws -> String {
        guard let input = try? Input(arguments) else {
            return try await access.write(call: arguments.id, .failure(.expected(#"{"path": string, "content": string}"#, by: name, received: arguments)))
        }
        if AgentAttachedArguments.named(in: arguments) {
            return try await access.write(call: arguments.id, .failure(.failed(AgentToolResult.attachedReadOnly)))
        }
        return try await access.write(call: arguments.id, .success(.init(path: input.path, change: .replace(input.content))))
    }
}

struct EditFileTool: Tool {
    let name = "edit_file"
    let description = "Replace one exact passage of a UTF-8 text file in the workspace"
    let access: any AgentWriteAccess

    @Generable
    struct Input {
        @Guide(description: "File path relative to the root")
        var path: String
        @Guide(description: "The passage to replace, exactly as it appears in the file; it must appear exactly once")
        var old_text: String
        @Guide(description: "The text that replaces it")
        var new_text: String
    }

    var parameters: GenerationSchema { Input.generationSchema }

    @concurrent func call(arguments: GeneratedContent) async throws -> String {
        guard let input = try? Input(arguments) else {
            return try await access.write(call: arguments.id, .failure(.expected(#"{"path": string, "old_text": string, "new_text": string}"#,
                                                                                 by: name, received: arguments)))
        }
        if AgentAttachedArguments.named(in: arguments) {
            return try await access.write(call: arguments.id, .failure(.failed(AgentToolResult.attachedReadOnly)))
        }
        return try await access.write(call: arguments.id, .success(.init(path: input.path, change: .edit(old: input.old_text, new: input.new_text))))
    }
}

/// Where the write tools may not write. Echo runs no code, so a write must not become a way to run
/// code through the person's hands: folders whose files the system or the person's tools load on
/// their own can only be read, and files that run when opened are never written.
struct AgentWritePolicy: Sendable {
    /// The person's home folder, canonical.
    let home: String

    init(home: String = ProjectPath.canonical(NSHomeDirectory()) ?? NSHomeDirectory()) {
        self.home = home
    }

    /// Why nothing may be written in `folder`, a canonical path, or nil when writing is allowed.
    func refusal(folder: String, scope: AgentReadScope) -> String? {
        let parts = folder.split(separator: "/")
        let library = home + "/Library"
        let cloud = [library + "/Mobile Documents/", library + "/CloudStorage/"]
        let readOnly = folder == home || home.hasPrefix(folder == "/" ? "/" : folder + "/")
            || ((folder == library || folder.hasPrefix(library + "/")) && !cloud.contains { folder.hasPrefix($0) })
            || parts.contains { $0.hasPrefix(".") }
        let reason: String
        if parts.contains(where: Self.isApplication) {
            reason = "is inside an application bundle (.app), so nothing was written."
        } else if readOnly {
            reason = "can only be read: nothing is written in the home folder itself, the folders above it, hidden folders, or ~/Library outside iCloud Drive and cloud storage folders. Nothing was written."
        } else {
            return nil
        }
        // Named only once refused: the name Finder shows takes a lookup.
        let name = FileManager.default.displayName(atPath: folder)
        return scope == .finder
            ? "This chat's Finder folder, \(name), \(reason) Ask the person to open a more specific folder in Finder, then call finder_location."
            : "The conversation's project folder, \(name), \(reason) Ask the person for a more specific folder to work in."
    }

    /// Why nothing may be written at `parts`, a normalized relative path, or nil.
    static func refusal(path parts: [Substring], raw: String) -> String? {
        if parts.isEmpty { return "path must name a file: \(raw)" }
        if parts.contains(where: { $0.hasPrefix(".") }) { return "hidden files and folders are not written: \(raw)" }
        if parts.contains(where: isApplication) { return "nothing inside an application bundle (.app) is written: \(raw)" }
        if (parts.last.map { ($0 as NSString).pathExtension.lowercased() }) == "terminal" {
            return "Terminal settings files (.terminal) are not written, since opening one runs the commands it holds: \(raw)"
        }
        return nil
    }

    private static func isApplication(_ part: Substring) -> Bool {
        (part as NSString).pathExtension.lowercased() == "app"
    }
}

/// What describes a file besides its bytes, as a write carries it over and an undo puts it back.
struct AgentFileDescription: Sendable {
    let mode: mode_t
    /// Extended attributes by name.
    let attributes: [String: Data]
    let created: timespec
    /// Its access control list as `acl_to_text` writes it; nil for none. The list is kept apart from
    /// the extended attributes, which do not show it.
    var acl: String? = nil
}

/// The file a write replaces, as it was before: its bytes and what describes it.
struct AgentOriginalFile: Sendable {
    let data: Data
    let mode: mode_t
    /// Where it is, absolute; for the backup's record only, never for the model.
    let path: String
    /// Every extended attribute it had, by name: Finder tags, Finder info, where it came from, and so on.
    let attributes: [String: Data]
    let created: timespec
    /// What identifies it on disk, to tell whether it is still the same file when the write goes in.
    let device: dev_t
    let inode: ino_t
    let modified: timespec
    /// Its access control list, as `AgentFileDescription.acl`.
    var acl: String? = nil

    var description: AgentFileDescription { .init(mode: mode, attributes: attributes, created: created, acl: acl) }

    /// Whether `info` is still this file as it was read: the same file, its size and modification
    /// time unchanged.
    func isSame(as info: stat) -> Bool {
        info.st_dev == device && info.st_ino == inode && info.st_size == data.count
            && info.st_mtimespec.tv_sec == modified.tv_sec && info.st_mtimespec.tv_nsec == modified.tv_nsec
    }
}

/// Points in a write where tests hold it. Each runs on the thread doing the work, never the main actor.
struct AgentWriteHooks: Sendable {
    /// Before the original is read: reading can wait for a file to download, as in iCloud Drive.
    var beforeReading: @Sendable () -> Void = {}
    /// After the copy is kept, before anything in the folder changes.
    var beforeReplacing: @Sendable () -> Void = {}
}

/// write_file and edit_file on disk, in two steps that each run off the main actor. `prepare`
/// checks everything and reads the original, changing nothing; `commit` keeps a copy of the
/// original, then writes the new content to a temporary file beside the target that replaces it,
/// so an interrupted write leaves the old content or the new, never part of either. Every component
/// is opened with `O_NOFOLLOW` from the root's descriptor, in both steps.
enum AgentFileWriter {
    static let maxFileBytes = ReadFileTool.maxFileBytes
    /// Extended attributes a replaced file does not pass on. TextEncoding describes the old bytes,
    /// which are gone; provenance and macl are the system's own record of which app wrote the file and
    /// which apps may open it, so the new file gets the system's, not copies.
    static let attributesNotCarried: Set<String> = ["com.apple.TextEncoding", "com.apple.provenance", "com.apple.macl"]
    /// Held by every write and undo, in every chat, from checking the target to putting the new
    /// content in place. Each chat runs its own calls in turn, but two chats changing one file, the
    /// memory file above all, could otherwise both pass the check and one lose its change unseen.
    static let changes = Mutex(())

    /// A write checked and read, with nothing changed yet.
    struct Plan: Sendable {
        let root: String
        let path: String
        let raw: String
        let scope: AgentReadScope
        /// The folders on the way; those from `firstMissing` on do not exist yet.
        let folders: [String]
        let firstMissing: Int
        let name: String
        let original: AgentOriginalFile?
        let content: Data
        let action: String
    }

    /// Checks, reads, and works out the new content. A failure is the call's result.
    static func prepare(root: String, path raw: String, change: AgentWriteRequest.Change, scope: AgentReadScope = .project,
                        hooks: AgentWriteHooks = AgentWriteHooks()) -> Result<Plan, AgentInvalidArguments> {
        func failed(_ detail: String) -> Result<Plan, AgentInvalidArguments> { .failure(.failed(detail)) }
        func failure(_ code: Int32) -> Result<Plan, AgentInvalidArguments> { failed(AgentToolPath.message(.system(code), path: raw, scope: scope)) }
        guard let path = AgentToolPath.normalize(raw) else { return failed(AgentToolPath.message(.outsideProject, path: raw, scope: scope)) }
        let parts = path.split(separator: "/")
        if let refusal = AgentWritePolicy.refusal(path: parts, raw: raw) { return failed(refusal) }
        let folders = parts.dropLast().map(String.init), name = String(parts.last!)

        // The folders that exist, opened one by one; the first missing one and those after it are created on commit.
        let (opened, reached) = openFolders(root: root, folders)
        guard let fd = opened.fd else { return failure(opened.code) }
        defer { close(fd) }

        var original: AgentOriginalFile?
        if reached == folders.count {
            var info = stat()
            if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                guard info.st_mode & S_IFMT != S_IFLNK else { return failure(ELOOP) }
                guard info.st_mode & S_IFMT == S_IFREG else { return failed("not a regular file: \(raw)") }
                guard info.st_mode & 0o111 == 0 else {
                    return failed("executable files are not written, since what is written would run as a program: \(raw)")
                }
                guard info.st_size <= maxFileBytes else { return failed("file exceeds 4 MiB: \(raw)") }
                hooks.beforeReading()
                switch read(fd, name, path: root + "/" + path) {
                case .success(let file): original = file
                case .failure(let error): return failure(error.code)
                }
            } else if errno != ENOENT {
                return failure(errno)
            }
        }

        let content: Data
        switch change {
        case .replace(let text):
            content = Data(text.utf8)
        case .edit(let old, let new):
            guard let original else { return failure(ENOENT) }
            switch edited(original.data, old: old, new: new, raw: raw) {
            case .success(let data): content = data
            case .failure(let failure): return failed(failure.detail)
            }
        case .derive(let derive):
            switch derive(original?.data) {
            case .success(let data): content = data
            case .failure(let failure): return .failure(failure)
            }
        }
        guard content.count <= maxFileBytes else { return failed("the file would exceed 4 MiB: \(raw)") }
        let action = switch change {
        case .edit: "edited"
        case .replace, .derive: original == nil ? "created" : "overwritten"
        }
        return .success(Plan(root: root, path: path, raw: raw, scope: scope, folders: folders, firstMissing: reached, name: name,
                             original: original, content: content, action: action))
    }

    /// Keeps a copy of the original, or for a new file a record that it is new, then puts the new
    /// content in place, carrying over the original's permission bits, extended attributes, access
    /// control list and creation date. The folders and the target are checked again: a target that changed since it
    /// was read is left as it is. `backup` gets nil for a new file.
    static func commit(_ plan: Plan, hooks: AgentWriteHooks = AgentWriteHooks(),
                       backup: (AgentOriginalFile?) throws -> Void) -> String {
        changes.withLock { _ in commitHoldingChanges(plan, hooks: hooks, backup: backup) }
    }

    private static func commitHoldingChanges(_ plan: Plan, hooks: AgentWriteHooks, backup: (AgentOriginalFile?) throws -> Void) -> String {
        let raw = plan.raw
        func failure(_ code: Int32) -> String { AgentToolResult.failed(AgentToolPath.message(.system(code), path: raw, scope: plan.scope)) }
        let (opened, reached) = openFolders(root: plan.root, plan.folders)
        guard var fd = opened.fd else { return failure(opened.code) }
        defer { close(fd) }
        let changed = AgentToolResult.failed("\(raw) changed while it was being written, so nothing was written; read it again")
        var info = stat()
        let found = reached == plan.folders.count && fstatat(fd, plan.name, &info, AT_SYMLINK_NOFOLLOW) == 0
        if let original = plan.original {
            guard found, info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o111 == 0, original.isSame(as: info) else { return changed }
            do { try backup(original) }
            catch { return AgentToolResult.failed("could not keep a copy of the original, so nothing was written: \(raw) (\(error.localizedDescription))") }
        } else if found || reached < plan.firstMissing {
            return changed
        } else {
            do { try backup(nil) }
            catch { return AgentToolResult.failed("could not keep a record of the new file, so nothing was written: \(raw) (\(error.localizedDescription))") }
        }
        hooks.beforeReplacing()
        for folder in plan.folders[reached...] {
            if mkdirat(fd, folder, 0o755) != 0, errno != EEXIST { return failure(errno) }
            let next = openat(fd, folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { return failure(errno) }
            close(fd); fd = next
        }
        switch replace(in: fd, name: plan.name, with: plan.content, like: plan.original?.description, skipping: attributesNotCarried) {
        case .none: break
        case .system(let code): return failure(code)
        case .attribute(let name, let code):
            return AgentToolResult.failed("could not carry the file's attribute \(name) over, so nothing was written: \(raw) (\(String(cString: strerror(code))))")
        }
        return AgentToolResult.object(["action": plan.action, "bytes": plan.content.count, "path": plan.path])
    }

    /// Both steps at once, for callers already off the main actor. `beforeChange` runs between
    /// them; what it throws ends the call with nothing done.
    static func write(root: String, path raw: String, change: AgentWriteRequest.Change, scope: AgentReadScope = .project,
                      hooks: AgentWriteHooks = AgentWriteHooks(), beforeChange: () throws -> Void,
                      backup: (AgentOriginalFile?) throws -> Void) throws -> String {
        switch prepare(root: root, path: raw, change: change, scope: scope, hooks: hooks) {
        case .failure(let failure): return failure.result
        case .success(let plan):
            try beforeChange()
            return commit(plan, hooks: hooks, backup: backup)
        }
    }

    /// What a write keeps of the content it wrote, so an undo can tell whether the file still has it.
    static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The deepest of `folders` that opens under `root`, and how many opened. A failure other than a
    /// missing folder has no descriptor.
    static func openFolders(root: String, _ folders: [String]) -> (opened: (fd: Int32?, code: Int32), reached: Int) {
        var fd = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return ((nil, errno), 0) }
        for (index, folder) in folders.enumerated() {
            let next = openat(fd, folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 {
                let code = errno
                guard code == ENOENT else { close(fd); return ((nil, code), index) }
                return ((fd, 0), index)
            }
            close(fd); fd = next
        }
        return ((fd, 0), folders.count)
    }

    struct EditFailure: Error { let detail: String }

    /// The file with `old`'s one occurrence replaced by `new`. Bytes are compared as they are, so
    /// text that only looks the same, such as another Unicode normalization, does not match.
    static func edited(_ data: Data, old: String, new: String, raw: String) -> Result<Data, EditFailure> {
        guard String(validating: data, as: UTF8.self) != nil else {
            return .failure(.init(detail: "not a UTF-8 text file, so it was not changed: \(raw)"))
        }
        guard !old.isEmpty else { return .failure(.init(detail: "old_text must not be empty")) }
        let matches = occurrences(of: old, in: data)
        switch matches.count {
        case 0:
            return .failure(.init(detail: "old_text was not found in \(raw), so nothing was changed; it must match the file exactly, including spaces and line breaks"))
        case 1:
            var result = data
            result.replaceSubrange(matches[0], with: Data(new.utf8))
            return .success(result)
        default:
            return .failure(.init(detail: "old_text appears \(matches.count) times in \(raw), so nothing was changed; it must appear exactly once, so include more of the text around it"))
        }
    }

    /// Every place `needle` appears in `data`, overlapping ones included, its bytes compared as they are.
    static func occurrences(of needle: String, in data: Data) -> [Range<Data.Index>] {
        let needle = Data(needle.utf8)
        var matches: [Range<Data.Index>] = []
        var start = data.startIndex
        while let found = data.range(of: needle, in: start..<data.endIndex) {
            matches.append(found)
            start = data.index(after: found.lowerBound)
        }
        return matches
    }

    struct Errno: Error { let code: Int32 }

    /// The file and what describes it. The file is checked again once open, since it may have been
    /// replaced after it was looked at. Reading a file that is not downloaded yet waits for it. A
    /// file over `limit` bytes is not read.
    static func read(_ directory: Int32, _ name: String, path: String, limit: Int = maxFileBytes) -> Result<AgentOriginalFile, Errno> {
        let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { return .failure(Errno(code: errno)) }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0 else { return .failure(Errno(code: errno)) }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o111 == 0, info.st_size <= limit else { return .failure(Errno(code: EPERM)) }
        var data = Data(count: Int(info.st_size))
        var total = 0
        while total < data.count {
            let count = data.withUnsafeMutableBytes { Darwin.read(file, $0.baseAddress!.advanced(by: total), $0.count - total) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { return .failure(Errno(code: errno)) }
            guard count > 0 else { break }
            total += count
        }
        guard let attributes = attributes(of: file) else { return .failure(Errno(code: errno)) }
        let acl: String?
        switch accessControlList(of: file) {
        case .success(let text): acl = text
        case .failure(let error): return .failure(error)
        }
        return .success(AgentOriginalFile(data: data.prefix(total), mode: info.st_mode & 0o777, path: path, attributes: attributes,
                                          created: info.st_birthtimespec, device: info.st_dev, inode: info.st_ino, modified: info.st_mtimespec,
                                          acl: acl))
    }

    /// An open file's access control list as text, nil when it has none.
    private static func accessControlList(of file: Int32) -> Result<String?, Errno> {
        guard let acl = acl_get_fd_np(file, ACL_TYPE_EXTENDED) else {
            return errno == ENOENT ? .success(nil) : .failure(Errno(code: errno))
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        guard acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry) == 0 else { return .success(nil) }
        guard let text = acl_to_text(acl, nil) else { return .failure(Errno(code: errno)) }
        defer { acl_free(text) }
        return .success(String(cString: text))
    }

    /// Every extended attribute of an open file, or nil with errno set.
    private static func attributes(of file: Int32) -> [String: Data]? {
        let size = flistxattr(file, nil, 0, 0)
        guard size >= 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard flistxattr(file, &buffer, size, 0) == size else { return nil }
        var result: [String: Data] = [:]
        for raw in buffer.split(separator: 0) {
            let name = String(decoding: raw.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let length = fgetxattr(file, name, nil, 0, 0, 0)
            guard length >= 0 else { return nil }
            var value = Data(count: length)
            let read = value.withUnsafeMutableBytes { fgetxattr(file, name, $0.baseAddress, length, 0, 0) }
            guard read == length else { return nil }
            result[name] = value
        }
        return result
    }

    enum ReplaceFailure { case none, system(Int32), attribute(String, Int32) }

    /// Writes `content` to a temporary file in `directory`, gives it what describes `original` but
    /// the attributes `skipping` names, then renames it over `name`. A new file gets 0644 less the
    /// umask, never an executable bit.
    static func replace(in directory: Int32, name: String, with content: Data, like original: AgentFileDescription?,
                        skipping: Set<String>) -> ReplaceFailure {
        let temporary = ".echo-write-\(UUID().uuidString)"
        let file = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard file >= 0 else { return .system(errno) }
        func fail(_ failure: ReplaceFailure) -> ReplaceFailure { close(file); unlinkat(directory, temporary, 0); return failure }
        var written = 0
        while written < content.count {
            let count = content.withUnsafeBytes { Darwin.write(file, $0.baseAddress!.advanced(by: written), content.count - written) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return fail(.system(count < 0 ? errno : EIO)) }
            written += count
        }
        if let original {
            guard fchmod(file, original.mode) == 0 else { return fail(.system(errno)) }
            for (attribute, value) in original.attributes.sorted(by: { $0.key < $1.key }) where !skipping.contains(attribute) {
                let set = value.withUnsafeBytes { fsetxattr(file, attribute, $0.baseAddress, value.count, 0, 0) }
                guard set == 0 else { return fail(.attribute(attribute, errno)) }
            }
            var list = attrlist()
            list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
            list.commonattr = attrgroup_t(ATTR_CMN_CRTIME)
            var created = original.created
            guard fsetattrlist(file, &list, &created, MemoryLayout<timespec>.size, 0) == 0 else { return fail(.system(errno)) }
            // The new file has only what the folder passes on; the original's own entries go with it too.
            if let text = original.acl {
                guard let acl = acl_from_text(text) else { return fail(.attribute("ACL", errno)) }
                defer { acl_free(UnsafeMutableRawPointer(acl)) }
                guard acl_set_fd_np(file, acl, ACL_TYPE_EXTENDED) == 0 else { return fail(.attribute("ACL", errno)) }
            }
        }
        guard fsync(file) == 0 else { return fail(.system(errno)) }
        close(file)
        // A new file must not replace one that appeared meanwhile.
        let renamed = original == nil
            ? renameatx_np(directory, temporary, directory, name, UInt32(RENAME_EXCL))
            : renameat(directory, temporary, directory, name)
        guard renamed == 0 else { let code = errno; unlinkat(directory, temporary, 0); return .system(code) }
        return .none
    }
}
