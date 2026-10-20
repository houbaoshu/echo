import AppKit
import Combine
import CoreServices
import Foundation
import FoundationModels
import Synchronization
import Testing

/// write_file and edit_file on disk, through `AgentFileWriter` alone: what each writes, every
/// refusal, and that a refusal, a failed save or a failed backup leaves the disk as it was.
@Suite struct AgentWriteToolTests {
    /// A canonical temporary folder holding root/ and outside/.
    struct Folders {
        let base: String
        var root: String { base + "/root" }
        var outside: String { base + "/outside" }
        func remove() { try? FileManager.default.removeItem(atPath: base) }
        func file(_ path: String, _ text: String, mode: Int = 0o644) throws {
            let url = URL(fileURLWithPath: root).appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
        func text(_ path: String) -> String? { try? String(contentsOfFile: root + "/" + path, encoding: .utf8) }
        func mode(_ path: String) -> Int? {
            (try? FileManager.default.attributesOfItem(atPath: root + "/" + path))?[.posixPermissions] as? Int
        }
        /// Every entry under the base, with its content, to show that nothing changed.
        func contents() -> [String: Data] {
            let fm = FileManager.default
            var result: [String: Data] = [:]
            for path in (fm.subpaths(atPath: base) ?? []) {
                let attributes = try? fm.attributesOfItem(atPath: base + "/" + path)
                result[path] = attributes?[.type] as? FileAttributeType == .typeRegular ? fm.contents(atPath: base + "/" + path) ?? Data() : Data()
            }
            return result
        }
    }

    static func folders() throws -> Folders {
        let fm = FileManager.default
        let url = fm.temporaryDirectory.appendingPathComponent("echo-write-\(UUID())")
        try fm.createDirectory(at: url.appendingPathComponent("root"), withIntermediateDirectories: true)
        try fm.createDirectory(at: url.appendingPathComponent("outside"), withIntermediateDirectories: true)
        return Folders(base: try #require(ProjectPath.canonical(url.path)))
    }

    /// What one write did: its result, whether it got as far as the save, and what it backed up.
    struct Run {
        var result: String
        var saved = false
        var backups: [AgentOriginalFile] = []
        /// Records kept of new files, which have no original to copy.
        var newFiles = 0
    }

    static func run(_ f: Folders, _ path: String, _ change: AgentWriteRequest.Change, backupFails: Bool = false) throws -> Run {
        var run = Run(result: "")
        run.result = try AgentFileWriter.write(root: f.root, path: path, change: change, beforeChange: { run.saved = true }, backup: { original in
            if backupFails { throw CocoaError(.fileWriteOutOfSpace) }
            if let original { run.backups.append(original) } else { run.newFiles += 1 }
        })
        return run
    }

    @Test func writeCreatesFoldersAndReplacesKeepingPermissions() throws {
        let f = try Self.folders()
        defer { f.remove() }
        let created = try Self.run(f, "./a/b/new.txt", .replace("hello"))
        #expect(created.result == #"{"action":"created","bytes":5,"path":"a/b/new.txt"}"#)
        #expect(f.text("a/b/new.txt") == "hello" && created.saved && created.backups.isEmpty && created.newFiles == 1,
                "A new file needs no copy, only a record")
        let umask = { let old = Darwin.umask(0); Darwin.umask(old); return Int(old) }()
        #expect(f.mode("a/b/new.txt") == 0o644 & ~umask, "A new file is never executable")

        try f.file("kept.txt", "old", mode: 0o640)
        let replaced = try Self.run(f, "kept.txt", .replace("新内容"))
        #expect(replaced.result == #"{"action":"overwritten","bytes":9,"path":"kept.txt"}"#)
        #expect(f.text("kept.txt") == "新内容" && f.mode("kept.txt") == 0o640, "The permission bits stay")
        #expect(replaced.backups.map(\.data) == [Data("old".utf8)] && replaced.backups.first?.mode == 0o640
                && replaced.backups.first?.path == f.root + "/kept.txt")

        // The new content replaces the name: another hard link to the old file keeps the old content.
        try Data("shared".utf8).write(to: URL(fileURLWithPath: f.outside + "/target.txt"))
        try FileManager.default.linkItem(atPath: f.outside + "/target.txt", toPath: f.root + "/linked.txt")
        #expect(try Self.run(f, "linked.txt", .replace("mine")).result.contains(#""action":"overwritten""#))
        #expect(f.text("linked.txt") == "mine" && (try? String(contentsOfFile: f.outside + "/target.txt", encoding: .utf8)) == "shared")
        #expect(!(FileManager.default.subpaths(atPath: f.base) ?? []).contains { $0.contains(".echo-write-") }, "No temporary file is left")
    }

    @Test func editReplacesExactlyOnePassage() throws {
        let f = try Self.folders()
        defer { f.remove() }
        try f.file("doc.txt", "one two three\n", mode: 0o600)
        let edited = try Self.run(f, "doc.txt", .edit(old: "two", new: "2"))
        #expect(edited.result == #"{"action":"edited","bytes":12,"path":"doc.txt"}"#)
        #expect(f.text("doc.txt") == "one 2 three\n" && f.mode("doc.txt") == 0o600)
        #expect(edited.backups.map(\.data) == [Data("one two three\n".utf8)])

        try f.file("twice.txt", "a b a")
        try f.file("overlap.txt", "aaa")
        try f.file("composed.txt", "caf\u{E9}")
        try Data([0x61, 0xFF, 0xFE]).write(to: URL(fileURLWithPath: f.root + "/binary.txt"))
        let before = f.contents()
        let cases: [(String, AgentWriteRequest.Change, String)] = [
            ("doc.txt", .edit(old: "four", new: "4"), "old_text was not found in doc.txt"),
            ("twice.txt", .edit(old: "a", new: "x"), "old_text appears 2 times in twice.txt"),
            ("overlap.txt", .edit(old: "aa", new: "b"), "old_text appears 2 times in overlap.txt"),
            ("composed.txt", .edit(old: "cafe\u{301}", new: "x"), "old_text was not found"),
            ("binary.txt", .edit(old: "a", new: "b"), "not a UTF-8 text file, so it was not changed: binary.txt"),
            ("doc.txt", .edit(old: "", new: "x"), "old_text must not be empty"),
            ("missing.txt", .edit(old: "a", new: "b"), "no such file or directory: missing.txt"),
            ("new-folder/missing.txt", .edit(old: "a", new: "b"), "no such file or directory: new-folder/missing.txt"),
        ]
        for (path, change, expected) in cases {
            let run = try Self.run(f, path, change)
            #expect(run.result.contains(#""status":"failed""#) && run.result.contains(expected), "\(path): \(run.result)")
            #expect(!run.saved && run.backups.isEmpty && run.newFiles == 0, "\(path): nothing was saved or copied")
        }
        #expect(f.contents() == before, "A failed edit changes nothing")
    }

    @Test func refusalsChangeNothing() throws {
        let f = try Self.folders()
        defer { f.remove() }
        let fm = FileManager.default
        try Data("secret".utf8).write(to: URL(fileURLWithPath: f.outside + "/secret.txt"))
        try fm.createSymbolicLink(atPath: f.root + "/link", withDestinationPath: f.outside)
        try fm.createSymbolicLink(atPath: f.root + "/file-link", withDestinationPath: f.outside + "/secret.txt")
        try f.file("dir/inside.txt", "inside")
        try f.file("script.sh", "echo hi\n", mode: 0o755)
        try f.file("group-runs.txt", "x", mode: 0o654)
        try fm.createDirectory(atPath: f.root + "/folder", withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: AgentFileWriter.maxFileBytes + 1).write(to: URL(fileURLWithPath: f.root + "/huge.txt"))
        try f.file("small.txt", "small")
        let before = f.contents()
        let cases: [(String, String)] = [
            ("/etc/x.txt", "path must stay inside the project: /etc/x.txt"),
            ("../x.txt", "path must stay inside the project"),
            ("dir/../../x.txt", "path must stay inside the project"),
            // Read only up to the NUL, these would be "../x.txt" and "dir/x.txt".
            ("..\u{0}/x.txt", "path must stay inside the project"),
            ("dir\u{0}/x.txt", "path must stay inside the project"),
            ("link/x.txt", "not a directory: link/x.txt"),
            ("link/new/x.txt", "not a directory: link/new/x.txt"),
            ("file-link", "symbolic links are not followed: file-link"),
            (".env", "hidden files and folders are not written: .env"),
            ("dir/.hidden.txt", "hidden files and folders are not written"),
            (".git/hooks/pre-commit", "hidden files and folders are not written"),
            (".github/workflows/x.yml", "hidden files and folders are not written"),
            ("Tool.app/Contents/MacOS/Tool", "nothing inside an application bundle (.app) is written"),
            ("dir/Other.APP/x.txt", "nothing inside an application bundle (.app) is written"),
            ("run.terminal", "Terminal settings files (.terminal) are not written"),
            ("dir/Run.TERMINAL", "Terminal settings files (.terminal) are not written"),
            ("script.sh", "executable files are not written"),
            ("group-runs.txt", "executable files are not written"),
            ("folder", "not a regular file: folder"),
            ("huge.txt", "file exceeds 4 MiB: huge.txt"),
            (".", "path must name a file: ."),
        ]
        for (path, expected) in cases {
            for change in [AgentWriteRequest.Change.replace("x"), .edit(old: "x", new: "y")] {
                let run = try Self.run(f, path, change)
                #expect(run.result.contains(#""status":"failed""#) && run.result.contains(expected), "\(path): \(run.result)")
                #expect(!run.saved && run.backups.isEmpty && run.newFiles == 0, "\(path): refused before anything was saved")
            }
        }
        let big = String(repeating: "b", count: AgentFileWriter.maxFileBytes + 1)
        #expect(try Self.run(f, "big.txt", .replace(big)).result.contains("the file would exceed 4 MiB: big.txt"))
        #expect(try Self.run(f, "small.txt", .edit(old: "small", new: big)).result.contains("the file would exceed 4 MiB: small.txt"))
        #expect(f.contents() == before, "No refusal changes anything, inside the root or out")
    }

    @Test func aFailedBackupOrSaveWritesNothing() throws {
        let f = try Self.folders()
        defer { f.remove() }
        try f.file("kept.txt", "original")
        let before = f.contents()
        for change in [AgentWriteRequest.Change.replace("new"), .edit(old: "original", new: "new")] {
            let run = try Self.run(f, "kept.txt", change, backupFails: true)
            #expect(run.result.contains("could not keep a copy of the original, so nothing was written: kept.txt"), "\(run.result)")
        }
        #expect(f.contents() == before)
        // A new file has nothing to copy, but without its record it is not created either.
        #expect(try Self.run(f, "fresh.txt", .replace("x"), backupFails: true).result
                    .contains("could not keep a record of the new file, so nothing was written: fresh.txt"))
        #expect(f.contents() == before)

        // The save before the change failed: the error ends the call and the disk is as it was.
        for (path, change) in [("kept.txt", AgentWriteRequest.Change.replace("new")), ("new/dir/file.txt", .replace("x"))] {
            #expect(throws: CocoaError.self) {
                try AgentFileWriter.write(root: f.root, path: path, change: change,
                                          beforeChange: { throw CocoaError(.fileWriteNoPermission) }, backup: { _ in Issue.record("no copy") })
            }
        }
        #expect(f.contents() == before, "Missing folders are not created before the save")
    }

    static func attribute(_ path: String, _ name: String) -> Data? {
        let length = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard length >= 0 else { return nil }
        var value = Data(count: length)
        _ = value.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, length, 0, XATTR_NOFOLLOW) }
        return value
    }
    static func setAttribute(_ path: String, _ name: String, _ text: String) throws {
        let value = Data(text.utf8)
        let result = value.withUnsafeBytes { setxattr(path, name, $0.baseAddress, value.count, 0, XATTR_NOFOLLOW) }
        try #require(result == 0, "setxattr \(name): \(String(cString: strerror(errno)))")
    }

    /// A replaced file keeps what describes it: Finder tags, Finder info, other extended attributes
    /// and its creation date, besides its permission bits. Its old text encoding goes with the old
    /// bytes. The copy kept before the change records all of it.
    @Test func replacingKeepsTheFilesAttributesAndCreationDate() throws {
        let f = try Self.folders()
        defer { f.remove() }
        let created = Date(timeIntervalSince1970: 978_307_200)   // 2001-01-01
        for (path, change) in [("written.txt", AgentWriteRequest.Change.replace("新内容")), ("edited.txt", .edit(old: "old", new: "new"))] {
            try f.file(path, "old text", mode: 0o640)
            let full = f.root + "/" + path
            var url = URL(fileURLWithPath: full)
            var values = URLResourceValues()
            values.tagNames = ["红色", "Echo"]
            values.creationDate = created
            try url.setResourceValues(values)
            try Self.setAttribute(full, "org.example.note", "keep me")
            try Self.setAttribute(full, "com.apple.quarantine", "0081;00000000;Safari;")
            try Self.setAttribute(full, "com.apple.TextEncoding", "MACINTOSH;0")
            let finderInfo = try #require(Self.attribute(full, "com.apple.FinderInfo"), "Tags set the Finder info's color")
            let inode = try #require(FileManager.default.attributesOfItem(atPath: full)[.systemFileNumber] as? Int)

            let run = try Self.run(f, path, change)
            #expect(run.result.contains(#""status""#) == false, "\(path): \(run.result)")
            let after = try URL(fileURLWithPath: full).resourceValues(forKeys: [.tagNamesKey, .creationDateKey])
            #expect(after.tagNames == ["红色", "Echo"] && after.creationDate == created, "\(path)")
            #expect(Self.attribute(full, "com.apple.FinderInfo") == finderInfo && Self.attribute(full, "org.example.note") == Data("keep me".utf8))
            #expect(Self.attribute(full, "com.apple.quarantine") == Data("0081;00000000;Safari;".utf8), "A downloaded file stays marked as one")
            #expect(Self.attribute(full, "com.apple.TextEncoding") == nil, "The old bytes' encoding does not describe the new ones")
            #expect(f.mode(path) == 0o640)
            #expect(try FileManager.default.attributesOfItem(atPath: full)[.systemFileNumber] as? Int != inode, "The content was replaced, not rewritten in place")

            // The copy records the original's attributes, the encoding among them, and its creation date.
            let original = try #require(run.backups.first)
            #expect(original.attributes["org.example.note"] == Data("keep me".utf8) && original.attributes["com.apple.TextEncoding"] == Data("MACINTOSH;0".utf8))
            #expect(original.created.tv_sec == 978_307_200)
        }
        #expect(AgentFileWriter.attributesNotCarried == ["com.apple.TextEncoding", "com.apple.provenance", "com.apple.macl"])
    }

    static func accessControlList(_ path: String) -> String? {
        guard let acl = acl_get_file(path, ACL_TYPE_EXTENDED) else { return nil }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard let text = acl_to_text(acl, nil) else { return nil }
        defer { acl_free(text) }
        return String(cString: text)
    }
    static func setAccessControlList(_ path: String, _ text: String) throws {
        let acl = try #require(acl_from_text(text))
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        try #require(acl_set_file(path, ACL_TYPE_EXTENDED, acl) == 0, "acl_set_file: \(String(cString: strerror(errno)))")
    }

    /// A replaced file keeps its own access control list, which the extended attributes do not
    /// show, and its copy records the list for an undo to put back.
    @Test func writesAndUndoKeepTheFilesAccessControlList() throws {
        let f = try Self.folders()
        defer { f.remove() }
        let store = AgentBackupStore(directory: URL(fileURLWithPath: f.base + "/backups"))
        try f.file("shared.txt", "old")
        let full = f.root + "/shared.txt"
        try Self.setAccessControlList(full, "!#acl 1\ngroup:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:everyone:12:allow:read,readattr\n")
        let list = try #require(Self.accessControlList(full))
        let result = try AgentFileWriter.write(root: f.root, path: "shared.txt", change: .edit(old: "old", new: "new"), beforeChange: {}) { original in
            try store.save(original, record: .init(path: full, root: f.root, rootKind: "project", relativePath: "shared.txt", chat: UUID(),
                                                   toolRecord: "1:0:acl", tool: "edit_file", savedAt: Date(), original: original,
                                                   action: "edited", written: Data("new".utf8)))
        }
        #expect(result.contains(#""action":"edited""#) && f.text("shared.txt") == "new")
        #expect(Self.accessControlList(full) == list, "The new file has the original's list: \(Self.accessControlList(full) ?? "none")")

        // Lost since, as another app's save may lose it: the undo puts it back with the content.
        let none = try #require(acl_init(0))
        defer { acl_free(UnsafeMutableRawPointer(none)) }
        #expect(acl_set_file(full, ACL_TYPE_EXTENDED, none) == 0 && Self.accessControlList(full) == nil)
        let (record, folder) = try #require(store.find(toolRecord: "1:0:acl"))
        #expect(record.acl == list)
        #expect(AgentFileUndo.undo(record, copy: folder, policy: AgentWritePolicy(home: "/nonexistent")) == nil)
        #expect(f.text("shared.txt") == "old" && Self.accessControlList(full) == list)

        // A record kept before lists were carried over still reads, with none to put back.
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var json = try #require(try JSONSerialization.jsonObject(with: encoder.encode(record)) as? [String: Any])
        json["acl"] = nil
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let older = try decoder.decode(AgentBackupStore.Record.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(older.acl == nil && older.original != nil && older.original?.acl == nil)
    }

    /// Writes and undos from different chats to one file come one at a time from the check to the
    /// rename: the later finds the earlier's file and refuses, rather than replace it unseen. Each
    /// chat runs its own calls in turn already; these come from two.
    @Test func changesFromTwoChatsToOneFileComeOneAtATime() throws {
        let f = try Self.folders()
        defer { f.remove() }
        try f.file("shared.txt", "v0")
        let results = Mutex([String: String]())
        let done = DispatchGroup()
        func commit(_ key: String, _ plan: AgentFileWriter.Plan, _ hooks: AgentWriteHooks) {
            done.enter()
            DispatchQueue.global().async {
                let result = AgentFileWriter.commit(plan, hooks: hooks) { _ in }
                results.withLock { $0[key] = result }
                done.leave()
            }
        }
        func plan(_ text: String) throws -> AgentFileWriter.Plan {
            try AgentFileWriter.prepare(root: f.root, path: "shared.txt", change: .replace(text)).get()
        }
        let first = try plan("A"), second = try plan("B")
        let firstInside = DispatchSemaphore(value: 0), releaseFirst = DispatchSemaphore(value: 0), secondInside = DispatchSemaphore(value: 0)
        commit("A", first, AgentWriteHooks(beforeReplacing: { firstInside.signal(); releaseFirst.wait() }))
        #expect(firstInside.wait(timeout: .now() + 5) == .success)
        commit("B", second, AgentWriteHooks(beforeReplacing: { secondInside.signal() }))
        #expect(secondInside.wait(timeout: .now() + 0.3) == .timedOut, "The second write waits before its check while the first changes the file")
        releaseFirst.signal()
        #expect(done.wait(timeout: .now() + 5) == .success)
        let both = results.withLock { $0 }
        #expect(both["A"]?.contains(#""action":"overwritten""#) == true, "\(both)")
        #expect(both["B"]?.contains("changed while it was being written") == true, "\(both)")
        #expect(f.text("shared.txt") == "A")

        // An undo of an earlier change waits the same way, and then finds the file changed.
        let store = AgentBackupStore(directory: URL(fileURLWithPath: f.base + "/backups"))
        _ = try AgentFileWriter.write(root: f.root, path: "shared.txt", change: .replace("C"), beforeChange: {}) { original in
            try store.save(original, record: .init(path: f.root + "/shared.txt", root: f.root, rootKind: "project", relativePath: "shared.txt",
                                                   chat: UUID(), toolRecord: "1:0:u", tool: "write_file", savedAt: Date(), original: original,
                                                   action: "overwritten", written: Data("C".utf8)))
        }
        let (record, folder) = try #require(store.find(toolRecord: "1:0:u"))
        let later = try plan("D")
        commit("D", later, AgentWriteHooks(beforeReplacing: { firstInside.signal(); releaseFirst.wait() }))
        #expect(firstInside.wait(timeout: .now() + 5) == .success)
        let undone = Mutex<AgentUndoRefusal??>(nil), undoEnded = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let refusal = AgentFileUndo.undo(record, copy: folder, policy: AgentWritePolicy(home: "/nonexistent"))
            undone.withLock { $0 = .some(refusal) }
            undoEnded.signal()
        }
        #expect(undoEnded.wait(timeout: .now() + 0.3) == .timedOut, "The undo waits while the other chat's write changes the file")
        releaseFirst.signal()
        #expect(undoEnded.wait(timeout: .now() + 5) == .success && done.wait(timeout: .now() + 5) == .success)
        #expect(undone.withLock { $0 } == .some(.changed) && f.text("shared.txt") == "D", "The undo finds the write's file and leaves it")
    }

    @Test func foldersThatCanOnlyBeRead() {
        let policy = AgentWritePolicy(home: "/Users/someone")
        let readOnly = [
            "/Users/someone", "/Users", "/", "/Users/someone/Library", "/Users/someone/Library/Caches",
            "/Users/someone/Library/LaunchAgents", "/Users/someone/Library/Mobile Documents", "/Users/someone/Library/CloudStorage",
            "/Users/someone/.ssh", "/Users/someone/.config/fish", "/Users/someone/Projects/.venv/lib",
            "/Users/someone/Library/Mobile Documents/com~apple~CloudDocs/.hidden",
            "/Users/someone/Library/CloudStorage/GoogleDrive-x/.Trash",
        ]
        for folder in readOnly {
            let refusal = policy.refusal(folder: folder, scope: .finder)
            #expect(refusal?.contains("can only be read") == true && refusal?.contains("Nothing was written") == true, "\(folder): \(refusal ?? "nil")")
            #expect(refusal?.contains("finder_location") == true, "Finder's side says how to move on")
            #expect(policy.refusal(folder: folder, scope: .project)?.contains("The conversation's project folder") == true)
        }
        for folder in ["/Applications/Tool.app/Contents/Resources", "/Users/someone/Library/Mobile Documents/com~apple~CloudDocs/Tool.app"] {
            #expect(policy.refusal(folder: folder, scope: .finder)?.contains("inside an application bundle (.app)") == true, "\(folder)")
        }
        for folder in ["/Users/someone/Documents", "/Users/someone/Desktop/Notes", "/Users/someone2", "/Volumes/USB", "/private/tmp/x",
                       "/Users/someone/Library/Mobile Documents/com~apple~CloudDocs", "/Users/someone/Library/Mobile Documents/com~apple~CloudDocs/Notes",
                       "/Users/someone/Library/CloudStorage/GoogleDrive-x/My Drive"] {
            #expect(policy.refusal(folder: folder, scope: .finder) == nil, "\(folder)")
        }
        #expect(AgentWritePolicy().home == ProjectPath.canonical(NSHomeDirectory()), "By default the person's own home folder")
    }
}

/// The write tools in a turn: saved before they run, ordered within their batch, superseded only
/// before they start, kept when a Stop or a crash cuts the turn, and copied before they replace.
@MainActor @Suite(.serialized) struct WriteToolHarnessTests {
    typealias Chat = AgentHarnessTests.Chat
    typealias FakeFinder = AgentHarnessTests.FakeFinder

    static func project(_ files: [String: String] = ["notes.txt": "alpha\n"]) throws -> URL {
        let fm = FileManager.default
        let url = fm.temporaryDirectory.appendingPathComponent("echo-write-project-\(UUID())")
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: try #require(ProjectPath.canonical(url.path)))
        for (path, text) in files {
            try fm.createDirectory(at: root.appendingPathComponent(path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: root.appendingPathComponent(path))
        }
        return root
    }

    static func text(_ root: URL, _ path: String) -> String? { try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }

    /// The copies in a chat's backup folder: each record with the original's bytes.
    /// The records in a chat's backup folder, oldest first: each with the original's bytes, or nil for a new file.
    static func backups(_ chat: Chat) throws -> [(record: AgentBackupStore.Record, original: Data?)] {
        let fm = FileManager.default
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try (fm.contentsOfDirectory(at: chat.backups, includingPropertiesForKeys: nil)).sorted { $0.path < $1.path }.map { folder in
            (try decoder.decode(AgentBackupStore.Record.self, from: Data(contentsOf: folder.appendingPathComponent(AgentBackupStore.recordName))),
             try? Data(contentsOf: folder.appendingPathComponent(AgentBackupStore.originalName)))
        }
    }

    /// Whether a saved state holds a call to `tool` without a result.
    static func holdsDangling(_ state: TaskStore.Snapshot, _ tool: String) -> Bool {
        AgentHarness.danglingCalls(state.native?.entries ?? []).contains { $0.toolName == tool }
    }

    @Test func aWriteAndAnEditThroughATurn() async throws {
        let root = try Self.project()
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = Chat(FinderRootTests.oneByOne([
            ("write_file", ##"{"path":"drafts/plan.md","content":"# 计划\n"}"##),
            ("edit_file", #"{"path":"notes.txt","old_text":"alpha","new_text":"beta"}"#),
        ]), project: root)
        defer { try? FileManager.default.removeItem(at: chat.backups) }
        // Every save before a write lands while the call has no result and the disk is unchanged.
        var seenBefore: [String] = []
        chat.saveFailure = { state in
            if Self.holdsDangling(state, "write_file") && Self.text(root, "drafts/plan.md") == nil { seenBefore.append("write_file") }
            if Self.holdsDangling(state, "edit_file") && Self.text(root, "notes.txt") == "alpha\n" { seenBefore.append("edit_file") }
            return false
        }
        try await FinderRootTests.run(chat, "写个计划，再改笔记")
        #expect(seenBefore == ["write_file", "edit_file"], "Each call was saved before its write: \(seenBefore)")
        #expect(Self.text(root, "drafts/plan.md") == "# 计划\n" && Self.text(root, "notes.txt") == "beta\n")
        let tools = chat.store.tools
        #expect(tools.map(\.tool) == ["write_file", "edit_file"] && tools.map(\.command) == ["drafts/plan.md", "notes.txt"])
        #expect(tools.map(\.state) == [.finished, .finished] && tools.allSatisfy { $0.directory == nil }, "As for reads of the project")
        #expect(tools.map(\.edit) == [nil, AgentToolRecord.Edit(old: "alpha", new: "beta")], "The edit card keeps what it replaced")
        #expect(tools.map(\.result) == [#"{"action":"created","bytes":9,"path":"drafts/plan.md"}"#,
                                       #"{"action":"edited","bytes":5,"path":"notes.txt"}"#])
        #expect(chat.model.requests.last?.toolOutputs == tools.compactMap(\.result))
        #expect(!tools.contains { $0.result?.contains(root.path) == true }, "No result carries an absolute path")
        #expect(AgentToolRecord.summary(Transcript.ToolCall(id: "x", toolName: "edit_file", arguments: try GeneratedContent(json: #"{"path":"notes.txt"}"#)))
                == "正在修改文件 · notes.txt")

        let backups = try Self.backups(chat)
        #expect(backups.map(\.original) == [nil, Data("alpha\n".utf8)], "Only the edit replaced a file; the new file has a record alone")
        let created = try #require(backups.first).record
        #expect(created.action == "created" && created.toolRecord == tools[0].id && created.mode == nil && created.attributes == nil)
        #expect(created.written == AgentFileWriter.fingerprint(Data("# 计划\n".utf8)) && created.relativePath == "drafts/plan.md")
        let backup = try #require(backups.last)
        #expect(backup.record.action == "edited" && backup.record.written == AgentFileWriter.fingerprint(Data("beta\n".utf8)))
        #expect(backup.record.path == root.path + "/notes.txt" && backup.record.root == root.path && backup.record.rootKind == "project")
        #expect(backup.record.relativePath == "notes.txt" && backup.record.tool == "edit_file" && backup.record.size == 6)
        #expect(backup.record.chat == chat.store.sessionID && backup.record.toolRecord == tools[1].id, "The copy names its chat and its card")
        #expect(backup.record.mode == 0o644 && abs(backup.record.savedAt.timeIntervalSinceNow) < 60)
    }

    @Test func writesInTheFinderFolderNameIt() async throws {
        let f = try FinderRootTests.folders()
        defer { f.remove() }
        let chat = Chat(FinderRootTests.oneByOne([
            ("write_file", #"{"path":"new.txt","content":"hi"}"#),
            ("edit_file", #"{"path":"note.txt","old_text":"from","new_text":"to"}"#),
        ]), finder: FakeFinder { .folder(f.finder) })
        defer { try? FileManager.default.removeItem(at: chat.backups) }
        try await FinderRootTests.run(chat)
        #expect(chat.store.tools.map(\.result) == [#"{"action":"created","bytes":2,"in_folder":"finder","path":"new.txt"}"#,
                                                  #"{"action":"edited","bytes":9,"in_folder":"finder","path":"note.txt"}"#])
        #expect(chat.store.tools.allSatisfy { $0.directory == f.finder }, "The card keeps the folder's path")
        #expect(try String(contentsOfFile: f.finder + "/note.txt", encoding: .utf8) == "to finder")
        #expect(try Self.backups(chat).map(\.record.rootKind) == ["finder", "finder"])
    }

    /// A home folder of its own for the folders that can only be read, so a write that wrongly goes
    /// through lands in a temporary folder.
    struct Home {
        let base: String
        var home: String { base + "/home" }
        var policy: AgentWritePolicy { AgentWritePolicy(home: home) }
        func folder(_ path: String) throws -> String {
            let full = path.isEmpty ? home : home + "/" + path
            try FileManager.default.createDirectory(atPath: full, withIntermediateDirectories: true)
            try Data("here".utf8).write(to: URL(fileURLWithPath: full + "/existing.txt"))
            return full
        }
        func remove() { try? FileManager.default.removeItem(atPath: base) }
    }

    static func home() throws -> Home {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("echo-home-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return Home(base: try #require(ProjectPath.canonical(url.path)))
    }

    /// One batch per Finder folder: switch to it, write a new file, edit one, read one.
    static func writesIn(_ count: Int) -> ScriptedAgentModel.Step {
        { _, emit, index in
            guard index < count else { return try await emit.text("done") }
            await emit.calls([
                ("finder_location", "{}", "f\(index)"),
                ("write_file", #"{"path":"new.txt","content":"x"}"#, "w\(index)"),
                ("edit_file", #"{"path":"existing.txt","old_text":"here","new_text":"changed"}"#, "e\(index)"),
                ("read_file", #"{"path":"existing.txt"}"#, "r\(index)"),
            ])
        }
    }

    @Test func homeAndLibraryFoldersCanOnlyBeRead() async throws {
        let h = try Self.home()
        defer { h.remove() }
        try Data("here".utf8).write(to: URL(fileURLWithPath: h.base + "/existing.txt"))
        let folders = [try h.folder(""), h.base, try h.folder("Library"), try h.folder("Library/Caches"), try h.folder("Library/LaunchAgents"),
                       try h.folder(".config/fish"), try h.folder("Documents/.secret"), try h.folder("Library/Mobile Documents")]
        let chat = Chat(Self.writesIn(folders.count), finder: .answering(folders.map(FinderLocation.folder)), writePolicy: h.policy)
        try await FinderRootTests.run(chat)
        try #require(chat.store.tools.count == folders.count * 4 && chat.store.task?.status == .completed)
        for (index, folder) in folders.enumerated() {
            let calls = chat.store.tools[(index * 4)..<(index * 4 + 4)].map { $0.result ?? "" }
            #expect(calls[1].contains("can only be read") && calls[2].contains("can only be read"), "\(folder): \(calls)")
            #expect(calls[1].contains("Ask the person to open a more specific folder in Finder, then call finder_location."))
            #expect(calls[3].contains(#""content":"here""#), "\(folder): reading is unaffected")
            #expect(chat.store.tools[(index * 4)..<(index * 4 + 4)].map(\.state) == [.finished, .notWritten, .notWritten, .finished],
                    "Refused writes say so on their cards; reads are as before")
            #expect(!FileManager.default.fileExists(atPath: folder + "/new.txt"))
            #expect(try String(contentsOfFile: folder + "/existing.txt", encoding: .utf8) == "here")
        }
        #expect(!FileManager.default.fileExists(atPath: chat.backups.path), "Nothing was copied")

        // The project side has the same folders.
        let project = Chat(FinderRootTests.oneByOne([("write_file", #"{"path":"new.txt","content":"x"}"#)]),
                           project: URL(fileURLWithPath: h.home + "/Library/Caches"), writePolicy: h.policy)
        try await FinderRootTests.run(project)
        #expect(project.store.tools.first?.result?.contains("The conversation's project folder, Caches, can only be read") == true)
        #expect(!FileManager.default.fileExists(atPath: h.home + "/Library/Caches/new.txt"))
    }

    @Test func iCloudDriveFoldersCanBeWritten() async throws {
        let h = try Self.home()
        defer { h.remove() }
        let drive = try h.folder("Library/Mobile Documents/com~apple~CloudDocs/Notes")
        let hidden = try h.folder("Library/Mobile Documents/com~apple~CloudDocs/.hidden")
        let chat = Chat(Self.writesIn(2), finder: .answering([.folder(drive), .folder(hidden)]), writePolicy: h.policy)
        defer { try? FileManager.default.removeItem(at: chat.backups) }
        try await FinderRootTests.run(chat)
        let results = chat.store.tools.map { $0.result ?? "" }
        #expect(results[1].contains(#""action":"created""#) && results[2].contains(#""action":"edited""#), "\(results)")
        #expect(try String(contentsOfFile: drive + "/existing.txt", encoding: .utf8) == "changed")
        #expect(results[5].contains("can only be read") && results[6].contains("can only be read"), "Hidden folders stay read-only: \(results)")
        #expect(!FileManager.default.fileExists(atPath: hidden + "/new.txt"))
    }

    @Test func cloudStorageFoldersCanBeWritten() async throws {
        let h = try Self.home()
        defer { h.remove() }
        let drive = try h.folder("Library/CloudStorage/GoogleDrive-someone@example.com/My Drive")
        let hidden = try h.folder("Library/CloudStorage/GoogleDrive-someone@example.com/.Trash")
        let chat = Chat(Self.writesIn(2), finder: .answering([.folder(drive), .folder(hidden)]), writePolicy: h.policy)
        defer { try? FileManager.default.removeItem(at: chat.backups) }
        try await FinderRootTests.run(chat)
        let results = chat.store.tools.map { $0.result ?? "" }
        #expect(results[1].contains(#""action":"created""#) && results[2].contains(#""action":"edited""#), "\(results)")
        #expect(try String(contentsOfFile: drive + "/existing.txt", encoding: .utf8) == "changed")
        #expect(results[5].contains("can only be read") && results[6].contains("can only be read"), "Hidden folders stay read-only: \(results)")
        #expect(!FileManager.default.fileExists(atPath: hidden + "/new.txt"))
    }

    @Test func aFolderInsideAnApplicationCanOnlyBeRead() async throws {
        let root = try Self.project(["Tool.app/Contents/Info.plist": "plist"])
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = Chat(FinderRootTests.oneByOne([("finder_location", "{}"), ("write_file", #"{"path":"x.txt","content":"x"}"#)]),
                        finder: FakeFinder { .folder(root.path + "/Tool.app/Contents") })
        try await FinderRootTests.run(chat)
        #expect(chat.store.tools.last?.result?.contains("is inside an application bundle (.app), so nothing was written") == true)
        #expect(!FileManager.default.fileExists(atPath: root.path + "/Tool.app/Contents/x.txt"))
    }

    @Test func withoutACopyNoFileIsReplaced() async throws {
        let root = try Self.project()
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = [("write_file", #"{"path":"notes.txt","content":"gone"}"#), ("edit_file", #"{"path":"notes.txt","old_text":"alpha","new_text":"x"}"#),
                     ("write_file", #"{"path":"fresh.txt","content":"new"}"#)]
        let unset = Chat(FinderRootTests.oneByOne(calls), project: root)
        unset.store.backupDirectory = nil
        try await FinderRootTests.run(unset)
        try FileManager.default.removeItem(at: root.appendingPathComponent("fresh.txt"))
        // A backup folder that cannot be made: a file stands where it would go.
        let blocked = Chat(FinderRootTests.oneByOne(calls), project: root)
        try Data().write(to: blocked.backups)
        defer { try? FileManager.default.removeItem(at: blocked.backups) }
        try await FinderRootTests.run(blocked)
        for chat in [unset, blocked] {
            let results = chat.store.tools.map { $0.result ?? "" }
            #expect(results[0].contains("could not keep a copy of the original, so nothing was written: notes.txt"), "\(results)")
            #expect(results[1].contains("could not keep a copy of the original, so nothing was written: notes.txt"))
            #expect(chat.store.task?.status == .completed)
        }
        // A chat that keeps no records still creates new files, which then have no undo.
        #expect(unset.store.tools[2].result?.contains(#""action":"created""#) == true)
        #expect(unset.store.tools.map(\.state) == [.notWritten, .notWritten, .finished] && unset.store.tools[2].undo == nil)
        // A record that cannot be kept stops a new file too.
        #expect(blocked.store.tools[2].result?.contains("could not keep a record of the new file, so nothing was written: fresh.txt") == true)
        #expect(blocked.store.tools.map(\.state) == [.notWritten, .notWritten, .notWritten])
        #expect(Self.text(root, "notes.txt") == "alpha\n")
    }

    /// Input that arrives before a write starts supersedes it; nothing is written.
    @Test func pendingInputSupersedesAWriteNotYetStarted() async throws {
        let root = try Self.project()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = ScriptGate()
        let chat = Chat({ _, emit, index in
            if index == 0 {
                await emit.calls([("finder_location", "{}", "c0"), ("write_file", #"{"path":"late.txt","content":"x"}"#, "c1")])
            } else { try await emit.text("ok") }
        }, finder: FakeFinder { try? await gate.wait(); return .folder(root.path) })
        #expect(chat.store.send("写一个"))
        try await eventually("asking Finder") { gate.arrivals == 1 }
        #expect(chat.store.tools.last?.result == nil, "The write waits for finder_location")
        try await chat.run("算了")
        gate.open()
        #expect(chat.store.tools.map(\.result) == [AgentToolResult.superseded, AgentToolResult.superseded])
        #expect(!FileManager.default.fileExists(atPath: root.path + "/late.txt"))
    }

    /// A batch runs as written: a write waits for the calls before it, and a read for the writes before it.
    @Test func aBatchRunsInTheOrderWritten() async throws {
        let root = try Self.project(["a.txt": "1"])
        defer { try? FileManager.default.removeItem(at: root) }
        let read = #"{"path":"a.txt"}"#
        let chat = Chat({ _, emit, index in
            if index == 0 {
                await emit.calls([
                    ("read_file", read, "r1"), ("write_file", #"{"path":"a.txt","content":"2"}"#, "w1"), ("read_file", read, "r2"),
                    ("edit_file", #"{"path":"a.txt","old_text":"2","new_text":"3"}"#, "e1"), ("read_file", read, "r3"),
                    ("read_file", #"{"file":"wrong"}"#, "bad"), ("write_file", #"{"path":"b.txt","content":"after"}"#, "w2"),
                ])
            } else { try await emit.text("done") }
        }, project: root)
        defer { try? FileManager.default.removeItem(at: chat.backups) }
        try await FinderRootTests.run(chat)
        let results = chat.store.tools.map { $0.result ?? "" }
        #expect([results[0], results[2], results[4]] == [FinderRootTests.content("1"), FinderRootTests.content("2"), FinderRootTests.content("3")], "\(results)")
        #expect(results[5].contains("invalid arguments for read_file") && results[6].contains(#""action":"created""#),
                "A call the tool could not read still takes its turn")
        #expect(Self.text(root, "a.txt") == "3" && Self.text(root, "b.txt") == "after")
    }

    /// A crash after a write call was saved and before its result was: reopened, the call is unknown
    /// and its card says it may have changed something. A write that finished earlier in the batch
    /// keeps its result in that save.
    @Test func aWriteSavedBeforeItsResultReopensAsUnknown() async throws {
        let root = try Self.project()
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = Chat({ _, emit, index in
            if index == 0 {
                await emit.calls([("write_file", #"{"path":"one.txt","content":"1"}"#, "w1"), ("write_file", #"{"path":"two.txt","content":"2"}"#, "w2"),
                                  ("read_file", #"{"path":"notes.txt"}"#, "r1")])
            } else { try await emit.text("done") }
        }, project: root)
        var crashed: TaskStore.Snapshot?
        chat.saveFailure = { state in
            // The save before the second write: the first one's result is in, the second has none.
            if crashed == nil, let entries = state.native?.entries,
               AgentHarness.danglingCalls(entries).map(\.id) == ["w2", "r1"] { crashed = state }
            return false
        }
        try await FinderRootTests.run(chat)
        let saved = try #require(crashed)
        #expect(saved.native?.entries.toolOutputs == [#"{"action":"created","bytes":1,"path":"one.txt"}"#])
        let reopened = Chat({ _, emit, _ in try await emit.text("x") }, project: root,
                            snapshot: try JSONDecoder().decode(TaskStore.Snapshot.self, from: JSONEncoder().encode(saved)))
        let tools = reopened.store.tools
        #expect(tools.map(\.state) == [.finished, .unknown, .unknown] && reopened.store.task?.status == .interrupted)
        #expect(tools[1].result == AgentToolResult.unknownAfterInterruption)
        #expect(tools.map(\.mayHaveChanged) == [true, true, false], "Only a write cut off may have changed something")
    }

    /// A Stop keeps a write that finished, and the calls after it that never started are not run.
    @Test func stopKeepsAFinishedWriteAndSkipsTheRest() async throws {
        let root = try Self.project()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = ScriptGate()
        // The first write anchors the chat on the folder at once; finder_location then waits.
        let asked = Mutex(0)
        let chat = Chat({ _, emit, index in
            if index == 0 {
                await emit.calls([("write_file", #"{"path":"one.txt","content":"1"}"#, "w1"), ("finder_location", "{}", "f1"),
                                  ("write_file", #"{"path":"two.txt","content":"2"}"#, "w2")])
            } else { try await emit.text("must not run") }
        }, finder: FakeFinder {
            if asked.withLock({ count in defer { count += 1 }; return count }) > 0 { try? await gate.wait() }
            return .folder(root.path)
        })
        #expect(chat.store.send("写两个"))
        try await eventually("asking Finder") { gate.arrivals == 1 }
        #expect(chat.store.tools.first?.result?.contains(#""action":"created""#) == true, "The card shows the write before the batch ends")
        chat.store.stopTask()
        try await chat.idle()
        gate.open()
        let tools = chat.store.tools
        #expect(tools[0].state == .finished
                && tools[0].result == #"{"action":"created","bytes":1,"in_folder":"\#(root.lastPathComponent)","path":"one.txt"}"#)
        #expect(tools[2].result == AgentToolResult.cancelledBefore && tools[2].state == .notExecuted)
        #expect(Self.text(root, "one.txt") == "1" && Self.text(root, "two.txt") == nil)
        #expect(chat.native.entries.toolOutputs.first == tools[0].result, "The model's context keeps what the write did")
    }

    @Test func aFailedSaveBeforeAWriteWritesNothing() async throws {
        let root = try Self.project()
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = Chat(FinderRootTests.oneByOne([("write_file", #"{"path":"notes.txt","content":"gone"}"#)]), project: root)
        chat.saveFailure = { state in Self.holdsDangling(state, "write_file") }
        try await chat.run("覆盖")
        #expect(Self.text(root, "notes.txt") == "alpha\n" && chat.model.requests.count == 1)
        #expect(chat.store.task?.status == .failed && chat.store.notice?.contains("保存失败") == true)
        #expect(!FileManager.default.fileExists(atPath: chat.backups.path))
    }

    @Test func instructionsDescribeTheWriteTools() async throws {
        let all = AgentInstructions.text(tools: ["list_files", "read_file", "finder_location", "write_file", "edit_file"])
        let writes = all.components(separatedBy: "\n\n").filter { $0.contains("write_file") }
        #expect(writes.count == 1, "\(writes)")
        let paragraph = try #require(writes.first)
        #expect(paragraph.hasPrefix("write_file creates a UTF-8 text file or replaces one in full; edit_file replaces a passage that appears exactly once"))
        for fact in ["the same folder as list_files and read_file, with paths relative to it", "at most 4 MiB", "(names starting with .), executable files, .terminal files",
                     "application bundle (.app)", "~/Library outside iCloud Drive and cloud storage folders can only be read",
                     "Echo keeps a copy of the original", "No tool deletes, renames or moves files."] {
            #expect(paragraph.contains(fact), "\(fact)")
        }
        for word in ["must", "never", "always", "Never", "Always", "Do not", "do not", "should", "only when"] {
            #expect(!paragraph.contains(word), "The paragraph states facts, not orders: \(word)")
        }
        #expect(all.contains("Paths are relative to the Finder folder, . is its root, and only what is inside it can be read or written."))
        let readOnly = AgentInstructions.text(tools: ["list_files", "read_file", "finder_location"])
        #expect(!readOnly.contains("write_file") && readOnly.contains("only what is inside it can be read."))
        #expect(WriteFileTool(access: NoWrites()).description == "Create a UTF-8 text file in the workspace, or replace one in full")
        #expect(EditFileTool(access: NoWrites()).description == "Replace one exact passage of a UTF-8 text file in the workspace")
    }

    /// Holds a write at one of its hooks until the test lets it go; counts the arrivals.
    final class Hold: Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private let count = Mutex(0)
        var arrivals: Int { count.withLock { $0 } }
        func wait() { count.withLock { $0 += 1 }; semaphore.wait() }
        func release() { semaphore.signal() }
    }

    /// Reading the original, which waits for a file that is not downloaded yet, runs off the main
    /// actor: the chat stays usable, and newer input or a Stop ends the call at once with nothing
    /// changed, even when the read finishes later.
    @Test func readingTheOriginalHoldsNeitherTheMainActorNorTheTurn() async throws {
        let root = try Self.project()
        defer { try? FileManager.default.removeItem(at: root) }
        let edit = [("edit_file", #"{"path":"notes.txt","old_text":"alpha","new_text":"beta"}"#)]
        for ending in ["follow-up", "stop"] {
            let hold = Hold()
            let chat = Chat(FinderRootTests.oneByOne(edit), project: root, writeHooks: AgentWriteHooks(beforeReading: { hold.wait() }))
            #expect(chat.store.send("改一下"))
            // Polling here runs on the main actor while the read is held.
            try await eventually("reading the original") { hold.arrivals == 1 }
            #expect(chat.store.tools.first?.state == .running && chat.store.isGenerating)
            if ending == "follow-up" { #expect(chat.store.send("算了")) } else { chat.store.stopTask() }
            try await chat.idle()
            #expect(hold.arrivals == 1, "The turn ended while the read was still held")
            let expected = ending == "follow-up" ? AgentToolResult.superseded : AgentToolResult.cancelledBefore
            #expect(chat.store.tools.first?.result == expected, "\(ending): \(chat.store.tools.first?.result ?? "nil")")
            #expect(chat.store.task?.status == (ending == "follow-up" ? .completed : .stopped))
            hold.release()
            try await Task.sleep(for: .milliseconds(200))
            #expect(Self.text(root, "notes.txt") == "alpha\n" && !FileManager.default.fileExists(atPath: chat.backups.path),
                    "\(ending): a read that finishes after its call ended changes nothing")
        }
    }

    /// Once the call is saved and its change under way, a Stop waits for the change to end: the
    /// result reaches the card and the model's context, and the call after it in the batch does
    /// not run in the middle of it.
    @Test func aStopWhileTheChangeIsUnderWayWaitsForIt() async throws {
        let root = try Self.project()
        defer { try? FileManager.default.removeItem(at: root) }
        let hold = Hold()
        let chat = Chat({ _, emit, index in
            if index == 0 {
                await emit.calls([("edit_file", #"{"path":"notes.txt","old_text":"alpha","new_text":"beta"}"#, "e1"),
                                  ("read_file", #"{"path":"notes.txt"}"#, "r1")])
            } else { try await emit.text("must not run") }
        }, project: root, writeHooks: AgentWriteHooks(beforeReplacing: { hold.wait() }))
        defer { try? FileManager.default.removeItem(at: chat.backups) }
        #expect(chat.store.send("改一下"))
        try await eventually("the change under way") { hold.arrivals == 1 }
        #expect(chat.saved.contains { WriteToolHarnessTests.holdsDangling($0, "edit_file") }, "Saved before the change")
        #expect(try Self.backups(chat).count == 1, "The copy is kept before the change")
        #expect(chat.store.tools.map(\.result) == [nil, nil], "The read waits for the write")
        chat.store.stopTask()
        try await Task.sleep(for: .milliseconds(300))
        #expect(chat.store.isGenerating && chat.store.task?.status == .stopping, "The turn waits for the change")
        hold.release()
        try await chat.idle()
        let tools = chat.store.tools
        #expect(tools[0].state == .finished && tools[0].result == #"{"action":"edited","bytes":5,"path":"notes.txt"}"#)
        #expect(tools[1].result == AgentToolResult.cancelledBefore)
        #expect(Self.text(root, "notes.txt") == "beta\n" && chat.native.entries.toolOutputs.first == tools[0].result)
        #expect(chat.store.task?.status == .stopped && chat.model.requests.count == 1)
    }

    /// A file that changed between the read and the change is left as it is.
    @Test func aFileChangedSinceItWasReadIsLeftAlone() throws {
        let f = try AgentWriteToolTests.folders()
        defer { f.remove() }
        try f.file("notes.txt", "alpha")
        guard case .success(let plan) = AgentFileWriter.prepare(root: f.root, path: "notes.txt", change: .edit(old: "alpha", new: "beta")) else {
            Issue.record("prepare failed"); return
        }
        try f.file("notes.txt", "someone else's alpha")
        let result = AgentFileWriter.commit(plan) { _ in Issue.record("no copy of a file that changed") }
        #expect(result.contains("notes.txt changed while it was being written, so nothing was written"), "\(result)")
        #expect(f.text("notes.txt") == "someone else's alpha")

        guard case .success(let fresh) = AgentFileWriter.prepare(root: f.root, path: "new/fresh.txt", change: .replace("mine")) else {
            Issue.record("prepare failed"); return
        }
        try f.file("new/fresh.txt", "theirs")
        #expect(AgentFileWriter.commit(fresh) { _ in }.contains("changed while it was being written"))
        #expect(f.text("new/fresh.txt") == "theirs", "A file that appeared meanwhile is not replaced")
    }

    /// A write card that ran says whether it wrote: a result that says what it did is finished,
    /// any other is not written. Reads, and calls that never ran, are labelled as before.
    @Test func writeCardsSayWhenNothingWasWritten() throws {
        let written = #"{"action":"edited","bytes":5,"path":"a.txt"}"#
        let refused = AgentToolResult.failed("hidden files and folders are not written: .env")
        let finder = FinderLocation.permissionDenied.toolResult
        for tool in ["write_file", "edit_file"] {
            #expect(AgentToolRecord.state(forResult: written, tool: tool) == .finished)
            #expect(AgentToolRecord.state(forResult: refused, tool: tool) == .notWritten)
            #expect(AgentToolRecord.state(forResult: finder, tool: tool) == .notWritten, "No Finder folder, nothing written")
            #expect(AgentToolRecord.state(forResult: AgentToolResult.superseded, tool: tool) == .notExecuted)
            #expect(AgentToolRecord.state(forResult: AgentToolResult.unknownAfterInterruption, tool: tool) == .unknown)
        }
        for tool in ["read_file", "list_files", nil] {
            #expect(AgentToolRecord.state(forResult: refused, tool: tool) == .finished, "\(tool ?? "bash")")
        }
        #expect(AgentToolRecord.State.notWritten.label == "未写入")

        // The edit's two sides, cut when long; a card saved by an earlier build has none.
        let long = String(repeating: "长", count: AgentToolRecord.editPreviewLimit + 100)
        let call = Transcript.ToolCall(id: "e", toolName: "edit_file", arguments: try GeneratedContent(
            json: String(decoding: JSONSerialization.data(withJSONObject: ["path": "a.txt", "old_text": long, "new_text": "短"]), as: UTF8.self)))
        let edit = try #require(AgentToolRecord.edit(call))
        #expect(edit.old == String(long.prefix(AgentToolRecord.editPreviewLimit)) + "…" && edit.new == "短")
        #expect(AgentToolRecord.edit(Transcript.ToolCall(id: "w", toolName: "write_file", arguments: try GeneratedContent(json: #"{"path":"a"}"#))) == nil)
        let record = AgentToolRecord(callID: "e", entryID: 1, turnID: 1, command: "a.txt", result: refused, state: .notWritten, tool: "edit_file", edit: edit)
        #expect(try JSONDecoder().decode(AgentToolRecord.self, from: JSONEncoder().encode(record)) == record)
        let older = #"{"callID":"e","entryID":1,"turnID":1,"command":"a.txt","result":"{\"status\":\"failed\"}","tool":"edit_file"}"#
        let decoded = try JSONDecoder().decode(AgentToolRecord.self, from: Data(older.utf8))
        #expect(decoded.edit == nil && decoded.state == .notWritten, "A state not saved is worked out with the tool")
    }

    struct NoWrites: AgentWriteAccess {
        func write(call: GenerationID?, _ request: Result<AgentWriteRequest, AgentInvalidArguments>) async throws -> String { "" }
    }

    /// Through the workspace: the copies live beside the saved chats and go with their chat, and a
    /// file the Agent creates shows in the file browser once the turn ends, and leaves it when undone.
    @Test func backupsLiveWithTheWorkspaceAndTheFileTreeShowsNewFiles() async throws {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: try #require(ProjectPath.canonical(fm.temporaryDirectory.path)))
            .appendingPathComponent("echo-write-workspace-\(UUID())")
        let project = base.appendingPathComponent("project")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("alpha".utf8).write(to: project.appendingPathComponent("old.txt"))
        defer { try? fm.removeItem(at: base) }
        let persistence = WorkspacePersistence(url: base.appendingPathComponent("workspace.json"))
        let model = ScriptedAgentModel(step: FinderRootTests.oneByOne([
            ("write_file", #"{"path":"new.txt","content":"created by Echo"}"#),
            ("edit_file", #"{"path":"old.txt","old_text":"alpha","new_text":"beta"}"#),
        ]))
        let ws = WorkspaceStore(persistence: persistence, harnessFactory: {
            AgentHarness(resolveModel: { model.factory }, finder: NoFinder(), trash: .into(base.appendingPathComponent("trash")))
        })
        defer { ws.shutdown() }
        let chat = try #require(ws.selected)
        #expect(ws.associateProject(ws.addProject(url: project), conversationID: chat.id))
        #expect(chat.store.backupDirectory == persistence.backupDirectory(chat.id)
                && persistence.backupDirectory(chat.id).path.hasPrefix(base.path), "Beside the saved chats, never the real data folder")
        func rootNames() -> [String] {
            if case .loaded(let entries)? = ws.fileBrowser.state.directories[""] { entries.map(\.name) } else { [] }
        }
        try await eventually("file tree") { rootNames() == ["old.txt"] }
        #expect(ws.send("写个文件", conversationID: chat.id))
        try await eventually("turn ends") { !chat.store.isGenerating }
        #expect(chat.store.task?.status == .completed)
        try await eventually("the new file shows in the tree") { rootNames() == ["new.txt", "old.txt"] }
        let records = try fm.contentsOfDirectory(at: persistence.backupDirectory(chat.id), includingPropertiesForKeys: nil)
        #expect(records.count == 2 && records.compactMap { try? Data(contentsOf: $0.appendingPathComponent(AgentBackupStore.originalName)) } == [Data("alpha".utf8)])
        // Undoing the new file takes it out of the tree.
        chat.store.undo(chat.store.tools[0].id)
        try await eventually("the undone file leaves the tree") { rootNames() == ["old.txt"] }
        #expect(chat.store.tools[0].undo == .undone)
        ws.deleteConversation(chat.id)
        #expect(!fm.fileExists(atPath: persistence.backupDirectory(chat.id).path), "Deleting the chat deletes its copies")
    }
}

extension AgentTrash {
    /// Moves files into `folder` instead of the Trash, keeping their names.
    static func into(_ folder: URL) -> AgentTrash {
        AgentTrash { url in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: folder.appendingPathComponent(url.lastPathComponent))
        }
    }
}

/// Undo on write cards: each change comes off on its own, only while the file still has what the
/// call wrote; the card and the model's context say so, and both survive reopening.
@MainActor @Suite(.serialized) struct WriteUndoTests {
    typealias Chat = AgentHarnessTests.Chat

    /// A chat that ran `calls` one by one in a turn, in a project holding `files`.
    static func chat(_ calls: [(String, String)], files: [String: String] = ["notes.txt": "alpha\n"],
                     trash: AgentTrash? = nil) async throws -> (chat: Chat, root: URL) {
        let root = try WriteToolHarnessTests.project(files)
        let chat = Chat(FinderRootTests.oneByOne(calls), project: root, trash: trash)
        try await FinderRootTests.run(chat, "改文件")
        #expect(chat.store.tools.allSatisfy { $0.state == .finished && $0.undo == .available }, "\(chat.store.tools.map(\.result))")
        return (chat, root)
    }
    static func remove(_ chat: Chat, _ root: URL) {
        for url in [root, chat.backups, chat.trash] { try? FileManager.default.removeItem(at: url) }
    }

    /// Undoes card `index` and waits for the outcome.
    @discardableResult static func undo(_ chat: Chat, _ index: Int) async throws -> AgentToolRecord.Undo? {
        let id = chat.store.tools[index].id
        chat.store.undo(id)
        try await eventually("undo ends") { chat.store.undoingTools.isEmpty }
        return chat.store.tools.first { $0.id == id }?.undo
    }

    static func text(_ root: URL, _ path: String) -> String? { WriteToolHarnessTests.text(root, path) }

    @Test func eachKindOfChangeComesOff() async throws {
        let (chat, root) = try await Self.chat([
            ("write_file", #"{"path":"a/b/new.txt","content":"hi"}"#),
            ("write_file", #"{"path":"notes.txt","content":"replaced"}"#),
            ("edit_file", #"{"path":"other.txt","old_text":"two","new_text":"2"}"#),
        ], files: ["notes.txt": "alpha\n", "other.txt": "one two\n"])
        defer { Self.remove(chat, root) }
        var refreshes = 0
        chat.store.onFilesChanged = { refreshes += 1 }
        #expect(chat.store.tools.allSatisfy { chat.store.offersUndo($0) && chat.store.canUndo($0) })

        #expect(try await Self.undo(chat, 0) == .undone)
        #expect(Self.text(root, "a/b/new.txt") == nil && (try? String(contentsOf: chat.trash.appendingPathComponent("new.txt"), encoding: .utf8)) == "hi",
                "The new file went to the Trash")
        var isFolder: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("a/b").path, isDirectory: &isFolder) && isFolder.boolValue,
                "The folders made for it stay")
        #expect(try await Self.undo(chat, 1) == .undone && Self.text(root, "notes.txt") == "alpha\n")
        #expect(try await Self.undo(chat, 2) == .undone && Self.text(root, "other.txt") == "one two\n")
        #expect(refreshes == 3, "The file browser reads the folder again after each undo")
        #expect(chat.store.tools.allSatisfy { !chat.store.offersUndo($0) }, "An undone card has no button: there is no redo")
        #expect(try WriteToolHarnessTests.backups(chat).count == 3, "The records stay")
        #expect(!(FileManager.default.subpaths(atPath: root.path) ?? []).contains { $0.contains(".echo-write-") }, "No temporary file is left")
        // Undo on an undone card does nothing more.
        chat.store.undo(chat.store.tools[1].id)
        #expect(chat.store.undoingTools.isEmpty)
    }

    /// The model hears of the undo through the call's result, in every later request, and through a
    /// notice before the person's next message, where it is now.
    @Test func theNextRequestSaysTheChangeWasUndone() async throws {
        let (chat, root) = try await Self.chat([
            ("write_file", #"{"path":"new.txt","content":"hi"}"#),
            ("edit_file", #"{"path":"notes.txt","old_text":"alpha","new_text":"beta"}"#),
        ])
        defer { Self.remove(chat, root) }
        let before = chat.store.tools.compactMap(\.result)
        try await Self.undo(chat, 0)
        try await Self.undo(chat, 1)
        try await FinderRootTests.run(chat, "现在呢？")
        let outputs = try #require(chat.model.requests.last).toolOutputs
        #expect(outputs == [AgentToolResult.undone(before[0]), AgentToolResult.undone(before[1])])
        let notes = try outputs.map { try #require((try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["undone"] as? String) }
        #expect(notes[0].contains("the file it created was moved to the Trash") && notes[1].contains("put back as it was before this call"))
        #expect(outputs.allSatisfy { $0.contains(#""action":"#) }, "What the call did stays as it was")
        #expect(chat.native.entries.toolOutputs == outputs, "The saved transcript carries the note")
        let notice = AgentToolResult.undoNotice([
            "new.txt: the file your write_file call created was moved to the Trash.",
            "notes.txt: put back as it was before your edit_file call.",
        ])
        #expect(try #require(chat.model.requests.last).userTexts.last == notice + "现在呢？", "The notice comes first, in the same message")
        #expect(notice.hasPrefix("[Echo: after your last reply, the person used Undo in Echo"))
        #expect(chat.native.undoNotices.isEmpty && chat.userTexts.last == "现在呢？", "Told once; the chat shows what the person wrote")
        try await FinderRootTests.run(chat, "再问一次")
        #expect(try #require(chat.model.requests.last).userTexts.suffix(2) == [notice + "现在呢？", "再问一次"], "Not repeated")
    }

    /// A file that is no longer exactly what the call wrote is left as it is, and the card says why.
    @Test func aFileChangedSinceIsLeftAlone() async throws {
        let names = ["changed", "deleted", "linked", "folder", "executable"]
        var files = Dictionary(uniqueKeysWithValues: names.map { ("\($0).txt", "original") })
        files["outside/linked.txt"] = "mine"
        let (chat, root) = try await Self.chat(names.map { ("write_file", #"{"path":"\#($0).txt","content":"mine"}"#) }
                                               + [("write_file", #"{"path":"sub/new.txt","content":"mine"}"#)], files: files)
        defer { Self.remove(chat, root) }
        let fm = FileManager.default
        let path = { (name: String) in root.appendingPathComponent(name).path }
        try Data("someone else's".utf8).write(to: root.appendingPathComponent("changed.txt"))
        try fm.removeItem(atPath: path("deleted.txt"))
        // A link to a file that has exactly what the call wrote: following it would undo through it.
        try fm.removeItem(atPath: path("linked.txt"))
        try fm.createSymbolicLink(atPath: path("linked.txt"), withDestinationPath: path("outside/linked.txt"))
        try fm.removeItem(atPath: path("folder.txt"))
        try fm.createDirectory(atPath: path("folder.txt"), withIntermediateDirectories: false)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path("executable.txt"))
        // A folder on the way replaced by a link to where the file now is.
        try fm.moveItem(atPath: path("sub"), toPath: path("moved"))
        try fm.createSymbolicLink(atPath: path("sub"), withDestinationPath: path("moved"))

        var outcomes: [AgentToolRecord.Undo?] = []
        for index in chat.store.tools.indices { outcomes.append(try await Self.undo(chat, index)) }
        #expect(outcomes == [.refused(.changed), .refused(.missing), .refused(.symbolicLink), .refused(.notFile), .refused(.changed),
                             .refused(.symbolicLink)])
        #expect(Self.text(root, "changed.txt") == "someone else's" && !fm.fileExists(atPath: path("deleted.txt")))
        #expect((try? fm.destinationOfSymbolicLink(atPath: path("linked.txt"))) == path("outside/linked.txt") && Self.text(root, "outside/linked.txt") == "mine")
        #expect(Self.text(root, "moved/new.txt") == "mine" && (try? fm.contentsOfDirectory(atPath: chat.trash.path)) == nil, "Nothing went to the Trash")
        #expect(Self.text(root, "executable.txt") == "mine" && (try? fm.attributesOfItem(atPath: path("executable.txt")))?[.posixPermissions] as? Int == 0o755)
        #expect(chat.store.tools.allSatisfy { chat.store.offersUndo($0) && $0.result.map(AgentToolResult.isUndone) == false },
                "The button stays, and the model is told nothing")
        #expect(AgentUndoRefusal.changed.message == "文件在写入之后又被改过，没有撤销。")
        #expect(AgentUndoRefusal.symbolicLink.message == "原来的位置现在是符号链接，没有撤销。")
    }

    /// Changes to one file come off from the latest back: an earlier one waits until the later is undone.
    @Test func onlyTheLatestChangeComesOff() async throws {
        let (chat, root) = try await Self.chat([
            ("write_file", #"{"path":"notes.txt","content":"v1"}"#),
            ("edit_file", #"{"path":"notes.txt","old_text":"v1","new_text":"v2"}"#),
            ("write_file", #"{"path":"new.txt","content":"a"}"#),
            ("edit_file", #"{"path":"new.txt","old_text":"a","new_text":"b"}"#),
        ])
        defer { Self.remove(chat, root) }
        #expect(try await Self.undo(chat, 0) == .refused(.changed) && Self.text(root, "notes.txt") == "v2")
        #expect(try await Self.undo(chat, 2) == .refused(.changed) && Self.text(root, "new.txt") == "b")
        #expect(try await Self.undo(chat, 1) == .undone && Self.text(root, "notes.txt") == "v1")
        #expect(try await Self.undo(chat, 0) == .undone && Self.text(root, "notes.txt") == "alpha\n")
        #expect(try await Self.undo(chat, 3) == .undone && Self.text(root, "new.txt") == "a")
        #expect(try await Self.undo(chat, 2) == .undone && Self.text(root, "new.txt") == nil)
    }

    /// What the card says of an undo is saved with the chat and there when it is opened again.
    @Test func undoStatesSurviveReopening() async throws {
        let (chat, root) = try await Self.chat([
            ("write_file", #"{"path":"new.txt","content":"hi"}"#),
            ("edit_file", #"{"path":"notes.txt","old_text":"alpha","new_text":"beta"}"#),
            ("write_file", #"{"path":"third.txt","content":"x"}"#),
        ])
        defer { Self.remove(chat, root) }
        try await Self.undo(chat, 0)
        try FileManager.default.removeItem(at: root.appendingPathComponent("notes.txt"))
        try await Self.undo(chat, 1)
        #expect(chat.saved.last?.native?.entries.toolOutputs.first.map(AgentToolResult.isUndone) == true, "The undo saved the chat")
        #expect(chat.saved.last?.native?.undoNotices == ["new.txt: the file your write_file call created was moved to the Trash."],
                "The notice waits for the next message, saved")
        let saved = try JSONDecoder().decode(TaskStore.Snapshot.self, from: JSONEncoder().encode(chat.store.snapshot))
        let reopened = Chat({ _, emit, _ in try await emit.text("ok") }, snapshot: saved)
        defer { try? FileManager.default.removeItem(at: reopened.backups) }
        #expect(reopened.store.tools.map(\.undo) == [.undone, .refused(.missing), .available])
        #expect(reopened.store.tools.map { reopened.store.offersUndo($0) } == [false, true, true])
        #expect(reopened.store.tools[0].result.map(AgentToolResult.isUndone) == true)
        #expect(reopened.native.undoNotices.count == 1)
    }

    /// While a turn runs, nothing can be undone; while an undo runs, no turn starts.
    @Test func undoAndTurnsDoNotOverlap() async throws {
        let root = try WriteToolHarnessTests.project()
        let gate = AsyncGate()
        let hold = WriteToolHarnessTests.Hold()
        let chat = Chat({ _, emit, index in
            switch index {
            case 0: await emit.call("write_file", #"{"path":"new.txt","content":"hi"}"#, id: "w")
            case 1: try await emit.text("done")
            default: await gate.wait(); try await emit.text("later")
            }
        }, project: root, trash: AgentTrash { url in hold.wait(); try AgentTrash.into(FileManager.default.temporaryDirectory.appendingPathComponent("echo-trash-\(UUID())")).move(url) })
        defer { Self.remove(chat, root) }
        try await FinderRootTests.run(chat, "写")
        let tool = chat.store.tools[0]
        #expect(chat.store.send("再说点"))
        #expect(chat.store.offersUndo(tool) && !chat.store.canUndo(tool), "The button shows but cannot be clicked")
        chat.store.undo(tool.id)
        #expect(chat.store.undoingTools.isEmpty && Self.text(root, "new.txt") == "hi")
        gate.open()
        try await chat.idle()
        #expect(chat.store.canUndo(chat.store.tools[0]))

        chat.store.undo(tool.id)
        try await eventually("undo under way") { hold.arrivals == 1 }
        #expect(!chat.store.canSubmit && !chat.store.send("现在") && !chat.store.canUndo(chat.store.tools[0]), "No turn starts during an undo")
        hold.release()
        try await eventually("undo ends") { chat.store.undoingTools.isEmpty }
        #expect(chat.store.tools[0].undo == .undone && chat.store.canSubmit)
    }

    /// Quitting waits for an undo under way, as for a turn, so the file put back and its card
    /// saying so are saved together, never the change on disk with the card still offering Undo.
    @Test func quittingWaitsForAnUndoUnderWay() async throws {
        let root = try WriteToolHarnessTests.project(["notes.txt": "alpha\n"])
        let hold = WriteToolHarnessTests.Hold()
        let chat = Chat(FinderRootTests.oneByOne([("write_file", #"{"path":"new.txt","content":"hi"}"#)]), project: root,
                        trash: AgentTrash { url in hold.wait(); try AgentTrash.into(FileManager.default.temporaryDirectory.appendingPathComponent("echo-trash-\(UUID())")).move(url) })
        defer { Self.remove(chat, root) }
        try await FinderRootTests.run(chat, "写")
        let workspace = WorkspaceStore(initialStore: chat.store)
        // An unsaved workspace keeps no copies; the chat's own folder holds the write's.
        chat.store.backupDirectory = chat.backups
        chat.store.undo(chat.store.tools[0].id)
        try await eventually("undo under way") { hold.arrivals == 1 }
        @MainActor final class Quit { var done = false }
        let quit = Quit()
        let quitting = Task { await workspace.prepareForTermination(); quit.done = true }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!quit.done, "Quitting waits while the undo runs")
        hold.release()
        await quitting.value
        #expect(chat.store.tools[0].undo == .undone && chat.store.undoingTools.isEmpty,
                "The undo's result reached the card before the conversation was shut down")
    }

    /// An overwrite or edit undone puts back the original's permission bits, extended attributes,
    /// text encoding among them, and creation date to the nanosecond, through a new file.
    @Test func undoPutsBackWhatDescribedTheFile() throws {
        let f = try AgentWriteToolTests.folders()
        defer { f.remove() }
        let store = AgentBackupStore(directory: URL(fileURLWithPath: f.base + "/backups"))
        let created = Date(timeIntervalSince1970: 978_307_200.25)
        for (index, (path, change)) in [("written.txt", AgentWriteRequest.Change.replace("新内容")), ("edited.txt", .edit(old: "old", new: "new"))].enumerated() {
            try f.file(path, "old text", mode: 0o640)
            let full = f.root + "/" + path
            var values = URLResourceValues()
            values.tagNames = ["红色"]
            values.creationDate = created
            var url = URL(fileURLWithPath: full)
            try url.setResourceValues(values)
            try AgentWriteToolTests.setAttribute(full, "org.example.note", "keep me")
            try AgentWriteToolTests.setAttribute(full, "com.apple.TextEncoding", "MACINTOSH;0")
            let finderInfo = AgentWriteToolTests.attribute(full, "com.apple.FinderInfo")
            let content = Data((index == 0 ? "新内容" : "new text").utf8)
            let result = try AgentFileWriter.write(root: f.root, path: path, change: change, beforeChange: {}) { original in
                try store.save(original, record: .init(path: full, root: f.root, rootKind: "project", relativePath: path, chat: UUID(),
                                                       toolRecord: "1:\(index):c", tool: "write_file", savedAt: Date(), original: original,
                                                       action: index == 0 ? "overwritten" : "edited", written: content))
            }
            #expect(result.contains(#""action""#) && FileManager.default.contents(atPath: full) == content)
            // Changed since in what describes it, not in its content.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: full)
            values = URLResourceValues(); values.tagNames = ["蓝色"]; values.creationDate = Date(timeIntervalSince1970: 0)
            url = URL(fileURLWithPath: full)
            try url.setResourceValues(values)
            removexattr(full, "org.example.note", XATTR_NOFOLLOW)
            let inode = try FileManager.default.attributesOfItem(atPath: full)[.systemFileNumber] as? Int

            let (record, folder) = try #require(store.find(toolRecord: "1:\(index):c"))
            #expect(AgentFileUndo.undo(record, copy: folder, policy: AgentWritePolicy(home: "/nonexistent")) == nil)
            #expect(f.text(path) == "old text" && f.mode(path) == 0o640, "\(path)")
            let after = try URL(fileURLWithPath: full).resourceValues(forKeys: [.tagNamesKey, .creationDateKey])
            #expect(after.tagNames == ["红色"] && after.creationDate == created, "\(path): \(String(describing: after.creationDate?.timeIntervalSince1970))")
            #expect(AgentWriteToolTests.attribute(full, "com.apple.FinderInfo") == finderInfo)
            #expect(AgentWriteToolTests.attribute(full, "org.example.note") == Data("keep me".utf8))
            #expect(AgentWriteToolTests.attribute(full, "com.apple.TextEncoding") == Data("MACINTOSH;0".utf8), "The encoding comes back with the bytes")
            #expect(try FileManager.default.attributesOfItem(atPath: full)[.systemFileNumber] as? Int != inode, "Put back through a new file")
        }
        #expect(!(FileManager.default.subpaths(atPath: f.root) ?? []).contains { $0.contains(".echo-write-") })
    }

    /// A location the write tools can only read is not undone in either; nor is a change from a
    /// build that kept no fingerprint, whose card has no button.
    @Test func readOnlyPlacesAndOlderRecordsAreNotUndone() throws {
        let f = try AgentWriteToolTests.folders()
        defer { f.remove() }
        try f.file("notes.txt", "mine")
        let directory = URL(fileURLWithPath: f.base + "/backups")
        let store = AgentBackupStore(directory: directory)
        let original = AgentOriginalFile(data: Data("before".utf8), mode: 0o644, path: f.root + "/notes.txt", attributes: [:],
                                         created: timespec(), device: 0, inode: 0, modified: timespec())
        try store.save(original, record: .init(path: f.root + "/notes.txt", root: f.root, rootKind: "finder", relativePath: "notes.txt",
                                               chat: UUID(), toolRecord: "1:1:a", tool: "write_file", savedAt: Date(), original: original,
                                               action: "overwritten", written: Data("mine".utf8)))
        let (record, folder) = try #require(store.find(toolRecord: "1:1:a"))
        // The root is the home folder itself, or inside a hidden folder.
        #expect(AgentFileUndo.undo(record, copy: folder, policy: AgentWritePolicy(home: f.root)) == .readOnly)
        var hidden = record; hidden.relativePath = ".git/notes.txt"
        #expect(AgentFileUndo.undo(hidden, copy: folder, policy: AgentWritePolicy(home: "/nonexistent")) == .readOnly)
        #expect(f.text("notes.txt") == "mine")

        // A record kept before undo existed: no action, no fingerprint.
        var older = record; older.action = nil; older.written = nil
        #expect(AgentFileUndo.undo(older, copy: folder, policy: AgentWritePolicy(home: "/nonexistent")) == .backupMissing)
        #expect(f.text("notes.txt") == "mine")
        let card = #"{"callID":"e","entryID":1,"turnID":1,"command":"a.txt","result":"{\"action\":\"edited\",\"bytes\":1,\"path\":\"a.txt\"}","state":"执行结束","tool":"edit_file"}"#
        let decoded = try JSONDecoder().decode(AgentToolRecord.self, from: Data(card.utf8))
        #expect(decoded.state == .finished && decoded.undo == nil && !TaskStore().offersUndo(decoded))
        // And with a fingerprint the same record undoes.
        #expect(AgentFileUndo.undo(record, copy: folder, policy: AgentWritePolicy(home: "/nonexistent")) == nil && f.text("notes.txt") == "before")
    }
}
