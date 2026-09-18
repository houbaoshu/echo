import Foundation
import Combine
import Darwin
import AppKit

@MainActor enum ProjectFileBrowserTests {
    static func wait(_ label: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            precondition(Date() < deadline, "Timed out: \(label)")
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    static func run() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("echo-files-\(UUID())").resolvingSymlinksInPath()
        try fm.createDirectory(at: root.appendingPathComponent("dir/empty"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func write(_ path: String, _ data: Data) throws { try data.write(to: root.appendingPathComponent(path)) }
        try write("file10.txt", Data("ten".utf8)); try write("file2.txt", Data("你好\nsecond\tline".utf8))
        for directory in ["target", "build", ".git", ".local-signing"] {
            try fm.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        try write(".DS_Store", Data())
        try write(".hidden", Data()); try write("dir/empty.txt", Data())
        try write("utf16le", Data([0xFF, 0xFE]) + "文本".data(using: .utf16LittleEndian)!)
        try write("utf16be", Data([0xFE, 0xFF]) + "文本".data(using: .utf16BigEndian)!)
        try write("utf8bom", Data([0xEF, 0xBB, 0xBF]) + Data("BOM".utf8))
        try write("binary", Data([0, 1, 2, 3])); try write("unsupported", Data([0xFF, 0x80]))
        try write("limit", Data(repeating: 65, count: ProjectFileIO.previewLimit))
        try write("oversized", Data(repeating: 65, count: ProjectFileIO.previewLimit + 1))
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "file2.txt")
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("cycle").path, withDestinationPath: ".")
        precondition(mkfifo(root.appendingPathComponent("pipe").path, 0o600) == 0)
        func preview(_ path: String) -> ProjectFilePreview { ProjectFileIO.preview(root: root.path, path: path) }
        precondition(preview("file2.txt") == .text("你好\nsecond\tline"))
        precondition(preview("dir/empty.txt") == .text(""))
        precondition(preview("utf16le") == .text("文本") && preview("utf16be") == .text("文本"))
        precondition(preview("utf8bom") == .text("BOM"))
        for path in ["binary", "unsupported", "oversized", "link", "cycle", "pipe"] {
            guard case .information = preview(path) else { preconditionFailure("Must not preview \(path)") }
        }
        guard case .text(let limit) = preview("limit") else { preconditionFailure("Exact size limit supported") }
        precondition(limit.utf8.count == ProjectFileIO.previewLimit)
        for path in ["deleted", "../outside", "/etc/passwd", "cycle/file2.txt"] {
            guard case .failed = preview(path) else { preconditionFailure("Invalid path or ancestor must fail: \(path)") }
        }
        guard case .loaded(let entries) = ProjectFileIO.directory(root: root.path, path: "") else {
            preconditionFailure("Root must load")
        }
        precondition(entries.first?.name == "build")
        precondition(entries.firstIndex { $0.name == "file2.txt" }! < entries.firstIndex { $0.name == "file10.txt" }!)
        precondition(!entries.contains { $0.name.hasPrefix(".") })
        for name in ["target", "build", "binary", "unsupported", "oversized", "pipe"] {
            precondition(entries.contains { $0.name == name }, "Visible content stays in tree: \(name)")
        }
        precondition(entries.first { $0.name == "cycle" }?.kind == .symbolicLink)
        precondition(ProjectFileIO.directory(root: root.path, path: "dir/empty") == .loaded([]))
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: root.appendingPathComponent("dir/empty").path)
        guard case .failed(let permission) = ProjectFileIO.directory(root: root.path, path: "dir/empty") else {
            preconditionFailure("Unreadable directory must fail")
        }
        precondition(permission.contains("权限"))
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("dir/empty").path)
        try testImages(root: root)

        let project = WorkspaceProject(name: "A", path: root.path)
        let browser = ProjectFileBrowserStore()
        precondition(browser.location == nil)
        browser.togglePreviewExpansion()
        precondition(!browser.isPreviewExpanded, "No preview cannot expand")
        browser.select(project: project)
        try await wait("root loaded") { if case .loaded = browser.state.directories[""] { return true }; return false }
        precondition(browser.state.directories["dir"] == nil, "No eager recursion")
        browser.toggleDirectory("dir")
        try await wait("expanded") { if case .loaded = browser.state.directories["dir"] { return true }; return false }
        browser.setScrollID("dir")
        browser.openFile("file2.txt")
        try await wait("preview") { browser.state.preview == .text("你好\nsecond\tline") }
        browser.togglePreviewExpansion()
        precondition(browser.isPreviewExpanded)
        browser.refresh()
        precondition(browser.isPreviewExpanded, "Content refresh preserves expansion")
        browser.returnToDirectory()
        precondition(!browser.isPreviewExpanded, "Returning to tree collapses preview")
        browser.togglePreviewExpansion()
        precondition(!browser.isPreviewExpanded, "A remembered selection in the tree cannot expand")
        precondition(browser.state.expanded == ["dir"] && browser.state.selectedPath == "file2.txt" && browser.state.scrollID == "dir")
        browser.select(project: nil)
        precondition(browser.location == nil && browser.state.directories.isEmpty && browser.state.selectedPath == nil)
        browser.select(project: project)
        precondition(browser.state.expanded == ["dir"] && browser.state.selectedPath == "file2.txt")
        browser.openFile("file2.txt")
        try await wait("preview after return") { browser.state.preview == .text("你好\nsecond\tline") }
        browser.togglePreviewExpansion()
        browser.openFile("file10.txt")
        precondition(!browser.isPreviewExpanded, "Changing file clears expansion")
        browser.openFile("file2.txt")
        try await wait("original preview") { browser.state.preview == .text("你好\nsecond\tline") }
        try write("file2.txt", Data("updated".utf8))
        browser.refresh(projectID: UUID())
        precondition(browser.state.preview == .text("你好\nsecond\tline"), "Unrelated background task does not refresh or switch project")
        try await wait("automatic preview update") { browser.state.preview == .text("updated") }
        try fm.removeItem(at: root.appendingPathComponent("file2.txt"))
        try await wait("automatic deleted preview") { if case .failed = browser.state.preview { return true }; return false }
        browser.returnToDirectory()
        func names(_ path: String = "") -> [String] {
            guard case .loaded(let entries) = browser.state.directories[path] else { return [] }
            return entries.map(\.name)
        }
        try write("dir/new.txt", Data("new".utf8))
        try await wait("nested file creation") { names("dir").contains("new.txt") }
        try fm.moveItem(at: root.appendingPathComponent("dir/new.txt"), to: root.appendingPathComponent("dir/renamed.txt"))
        try await wait("nested file rename") { names("dir").contains("renamed.txt") && !names("dir").contains("new.txt") }
        try fm.removeItem(at: root.appendingPathComponent("dir/renamed.txt"))
        try await wait("nested file deletion") { !names("dir").contains("renamed.txt") }
        try fm.createDirectory(at: root.appendingPathComponent("created/child"), withIntermediateDirectories: true)
        try await wait("directory creation") { names().contains("created") }
        browser.toggleDirectory("created")
        try await wait("new directory expands") { names("created").contains("child") }
        try fm.moveItem(at: root.appendingPathComponent("created"), to: root.appendingPathComponent("renamed"))
        try await wait("directory rename") { names().contains("renamed") && !names().contains("created") }
        try fm.removeItem(at: root.appendingPathComponent("renamed"))
        try await wait("directory deletion") { !names().contains("renamed") }
        browser.toggleDirectory("dir")
        precondition(!browser.state.expanded.contains("dir"))
        try write("dir/collapsed.txt", Data())
        try await wait("loaded collapsed directory updates") { names("dir").contains("collapsed.txt") }
        browser.toggleDirectory("dir")
        precondition(browser.state.expanded.contains("dir") && browser.state.scrollID == "dir")
        let otherRoot = root.appendingPathComponent("other")
        try fm.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        let other = WorkspaceProject(name: "B", path: otherRoot.path)
        browser.openFile("file10.txt")
        browser.togglePreviewExpansion()
        browser.select(project: other)
        precondition(!browser.isPreviewExpanded, "Changing project clears expansion")
        browser.select(project: project)
        precondition(!browser.isPreviewExpanded, "Cached project cannot restore expansion")
        browser.select(project: other)
        try await wait("switch project") { browser.state.directories[""] == .loaded([]) }
        try write("old-project.txt", Data())
        try await Task.sleep(for: .milliseconds(500))
        precondition(browser.location?.projectID == other.id && browser.state.directories[""] == .loaded([]))
        try write("other/current.txt", Data())
        try await wait("new project watcher") { names().contains("current.txt") }
        browser.select(project: nil)
        try write("other/after-detach.txt", Data())
        try await Task.sleep(for: .milliseconds(500))
        precondition(browser.location == nil && browser.state.directories.isEmpty)
        var relocated = project; relocated.path = root.appendingPathComponent("missing").path
        browser.select(project: relocated)
        precondition(browser.state.selectedPath == nil && browser.state.expanded.isEmpty)
        try await wait("missing root") { if case .failed = browser.state.directories[""] { return true }; return false }

        // Inject slow readers to force old root, old project and old preview results
        // to finish after a newer selection, with no main-thread blocking.
        let slow = ProjectFileBrowserStore(readDirectory: { root, _ in
            if root == "/slow" { usleep(150_000) }
            return .loaded([.init(path: root, name: root, kind: .file)])
        }, readPreview: { root, path in
            if path == "old" { usleep(150_000) }
            return .text(root + path)
        })
        let old = WorkspaceProject(name: "old", path: "/slow")
        var moved = old; moved.path = "/fast"
        slow.select(project: old); slow.openFile("old")
        slow.select(project: moved); slow.openFile("new")
        try await wait("new result") { slow.state.preview == .text("/fastnew") }
        try await Task.sleep(for: .milliseconds(250))
        precondition(slow.location?.root == "/fast" && slow.state.preview == .text("/fastnew"))
        precondition(slow.state.directories[""] == .loaded([.init(path: "/fast", name: "/fast", kind: .file)]))
        slow.openFile("old"); slow.openFile("new")
        try await Task.sleep(for: .milliseconds(250))
        precondition(slow.state.preview == .text("/fastnew"))
        slow.select(project: old); slow.select(project: nil)
        try await Task.sleep(for: .milliseconds(250))
        precondition(slow.location == nil && slow.state.directories.isEmpty)
        print("PASS: file browser encodings, limits, links, permissions, lazy tree, memory navigation, filesystem watching and late-result isolation")
        try await testRefreshCommitsDirectoriesSeparately()
    }

    /// Records what each run loop turn changed, so a refresh that alters several
    /// directories can be checked for how it reaches the list.
    @MainActor private final class CommitRecorder {
        var turn = 0
        var previous: [String: ProjectDirectoryState] = [:]
        var changesPerTurn: [Int: Int] = [:]
        var busiestTurn: Int { changesPerTurn.values.max() ?? 0 }
        var changedDirectories: Int { changesPerTurn.values.reduce(0, +) }
        func record(_ directories: [String: ProjectDirectoryState]) {
            let changed = Set(previous.keys).union(directories.keys).count { previous[$0] != directories[$0] }
            if changed > 0 { changesPerTurn[turn, default: 0] += changed }
            previous = directories
        }
    }
    /// A thread-safe switch for the injected reader, which runs off the main actor.
    private final class ContentFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }

    /// Several directories changing in one refresh must reach the list in separate run loop
    /// turns. The sidebar list is an NSOutlineView, and two of its groups gaining rows in a
    /// single SwiftUI update make it insert rows from inside its own delegate callbacks —
    /// see docs/repros/swiftui-outline-list-reentrancy.swift, which logs
    /// "Application performed a reentrant operation in its NSTableView delegate".
    static func testRefreshCommitsDirectoriesSeparately() async throws {
        let folders = (0..<6).map { "folder\($0)" }
        let grown = ContentFlag()
        // Returns immediately, so every directory's read finishes in the same instant and
        // the results would land in one update unless refresh separates them.
        let browser = ProjectFileBrowserStore(readDirectory: { _, path in
            if path.isEmpty {
                return .loaded(folders.map { .init(path: $0, name: $0, kind: .directory) })
            }
            var entries: [ProjectFileEntry] = [.init(path: path + "/seed.txt", name: "seed.txt", kind: .file)]
            if grown.isSet { entries.append(.init(path: path + "/added.txt", name: "added.txt", kind: .file)) }
            return .loaded(entries)
        }, readPreview: { _, _ in .text("") })

        browser.select(project: WorkspaceProject(name: "commits", path: "/commits"))
        try await wait("root loaded") { if case .loaded = browser.state.directories[""] { return true }; return false }
        for folder in folders { browser.toggleDirectory(folder) }
        try await wait("all expanded") {
            folders.allSatisfy { if case .loaded = browser.state.directories[$0] { return true }; return false }
        }

        let recorder = CommitRecorder()
        recorder.previous = browser.state.directories
        guard let observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0, { _, _ in
                MainActor.assumeIsolated { recorder.turn += 1 }
            }) else { preconditionFailure("Could not observe the run loop") }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        defer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        let subscription = browser.$state.sink { state in
            MainActor.assumeIsolated { recorder.record(state.directories) }
        }
        defer { subscription.cancel() }

        grown.set()
        browser.refresh()
        try await wait("every folder grew") {
            folders.allSatisfy { folder in
                guard case .loaded(let entries) = browser.state.directories[folder] else { return false }
                return entries.contains { $0.name == "added.txt" }
            }
        }
        try await Task.sleep(for: .milliseconds(200))
        precondition(recorder.changedDirectories >= folders.count,
                     "Every grown folder is observed: \(recorder.changedDirectories)")
        precondition(recorder.busiestTurn == 1,
                     "A run loop turn carries at most one changed directory, saw \(recorder.busiestTurn) in one turn")

        // An unchanged refresh must not rewrite anything: a rewrite rebuilds the subtree
        // and, with several directories, is the update shape the list cannot take.
        let quiet = CommitRecorder()
        quiet.previous = browser.state.directories
        let quietSubscription = browser.$state.sink { state in
            MainActor.assumeIsolated { quiet.record(state.directories) }
        }
        defer { quietSubscription.cancel() }
        browser.refresh()
        try await Task.sleep(for: .milliseconds(300))
        precondition(quiet.changedDirectories == 0,
                     "An unchanged refresh rewrites no directory, saw \(quiet.changedDirectories)")
        print("PASS: refresh commits each changed directory in its own run loop turn and rewrites nothing unchanged")
    }

    private static func testImages(root: URL) throws {
        func preview(_ path: String, _ data: Data) throws -> ProjectFilePreview {
            try data.write(to: root.appendingPathComponent(path))
            return ProjectFileIO.preview(root: root.path, path: path)
        }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 768, pixelsHigh: 512,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        // Incompressible pixels produce a real PNG above the text size limit.
        var seed: UInt32 = 42
        for index in 0..<(bitmap.bytesPerRow * bitmap.pixelsHigh) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            bitmap.bitmapData![index] = UInt8(truncatingIfNeeded: seed >> 24)
        }
        for (ext, format) in [("PNG", NSBitmapImageRep.FileType.png), ("jpg", .jpeg), ("jpeg", .jpeg), ("gif", .gif)] {
            let data = bitmap.representation(using: format, properties: [:])!
            if ext == "PNG" { precondition(data.count > ProjectFileIO.previewLimit) }
            guard case .image(let image) = try preview("sample.\(ext)", data) else {
                preconditionFailure("Must decode \(ext), independently of the text limit")
            }
            precondition(image.width == 768 && image.height == 512)
        }
        let webp = try Data(contentsOf: URL(fileURLWithPath: "assets/pets/chiyan/spritesheet.webp"))
        guard case .image = try preview("sample.webp", webp) else { preconditionFailure("System supports WebP") }
        let wide = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8192, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        wide.bitmapData!.initialize(repeating: 0, count: wide.bytesPerRow * wide.pixelsHigh)
        guard case .image(let reduced) = try preview("wide.png", wide.representation(using: .png, properties: [:])!) else {
            preconditionFailure("Large dimensions must be downsampled")
        }
        precondition(reduced.width == 4096 && reduced.height == 8)
        for (name, data) in [("broken.png", Data("invalid image".utf8)), ("empty.jpg", Data()),
                             ("unsupported.svg", Data("<svg></svg>".utf8))] {
            guard case .information(let message) = try preview(name, data) else { preconditionFailure(name) }
            precondition(message.contains("无法预览图片"))
        }
        let oversized = root.appendingPathComponent("large.png")
        try Data().write(to: oversized)
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(ProjectFileIO.imagePreviewLimit + 1))
        try handle.close()
        precondition(ProjectFileIO.preview(root: root.path, path: "large.png") == .information("图片超过 32 MiB，无法预览。"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link.png").path,
                                                 withDestinationPath: "sample.PNG")
        guard case .information(let message) = ProjectFileIO.preview(root: root.path, path: "link.png") else {
            preconditionFailure("Images must retain descriptor-relative link protection")
        }
        precondition(message.contains("符号链接"))
        print("PASS: PNG above 1 MiB, JPEG/JPG, GIF, WebP, image downsampling, corrupt/unsupported images, image size limit and links")
    }
}
