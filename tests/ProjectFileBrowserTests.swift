import Foundation
import Darwin

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
        guard case .loaded(let entries) = ProjectFileIO.directory(root: root.path, path: "", showHidden: false) else {
            preconditionFailure("Root must load")
        }
        precondition(entries.first?.name == "dir")
        precondition(entries.firstIndex { $0.name == "file2.txt" }! < entries.firstIndex { $0.name == "file10.txt" }!)
        precondition(!entries.contains { $0.name == ".hidden" })
        precondition(entries.first { $0.name == "cycle" }?.kind == .symbolicLink)
        precondition(ProjectFileIO.directory(root: root.path, path: "dir/empty", showHidden: true) == .loaded([]))
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: root.appendingPathComponent("dir/empty").path)
        guard case .failed(let permission) = ProjectFileIO.directory(root: root.path, path: "dir/empty", showHidden: false) else {
            preconditionFailure("Unreadable directory must fail")
        }
        precondition(permission.contains("权限"))
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("dir/empty").path)

        let project = WorkspaceProject(name: "A", path: root.path)
        let browser = ProjectFileBrowserStore()
        precondition(browser.location == nil)
        browser.select(project: project)
        try await wait("root loaded") { if case .loaded = browser.state.directories[""] { return true }; return false }
        precondition(browser.state.directories["dir"] == nil, "No eager recursion")
        browser.toggleDirectory("dir")
        try await wait("expanded") { if case .loaded = browser.state.directories["dir"] { return true }; return false }
        browser.setScrollID("dir")
        browser.openFile("file2.txt")
        try await wait("preview") { browser.state.preview == .text("你好\nsecond\tline") }
        browser.returnToDirectory()
        precondition(browser.state.expanded == ["dir"] && browser.state.selectedPath == "file2.txt" && browser.state.scrollID == "dir")
        browser.select(project: nil)
        precondition(browser.location == nil && browser.state.directories.isEmpty && browser.state.selectedPath == nil)
        browser.select(project: project)
        precondition(browser.state.expanded == ["dir"] && browser.state.selectedPath == "file2.txt")
        browser.setShowHidden(true)
        try await wait("hidden switch") {
            if case .loaded(let values) = browser.state.directories[""] { return values.contains { $0.name == ".hidden" } }; return false
        }
        browser.openFile("file2.txt")
        try await wait("preview after return") { browser.state.preview == .text("你好\nsecond\tline") }
        try write("file2.txt", Data("updated".utf8))
        browser.refresh(projectID: UUID())
        precondition(browser.state.preview == .text("你好\nsecond\tline"), "Unrelated background task does not refresh or switch project")
        browser.refresh(projectID: project.id)
        try await wait("refresh preview") { browser.state.preview == .text("updated") }
        try fm.removeItem(at: root.appendingPathComponent("file2.txt"))
        browser.refresh()
        try await wait("deleted preview") { if case .failed = browser.state.preview { return true }; return false }
        var relocated = project; relocated.path = root.appendingPathComponent("missing").path
        browser.select(project: relocated)
        precondition(browser.state.selectedPath == nil && browser.state.expanded.isEmpty)
        try await wait("missing root") { if case .failed = browser.state.directories[""] { return true }; return false }

        // Inject slow readers to force old root, old project and old preview results
        // to finish after a newer selection, with no main-thread blocking.
        let slow = ProjectFileBrowserStore(readDirectory: { root, _, _ in
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
        print("PASS: file browser encodings, limits, links, permissions, lazy tree, memory navigation, refresh and late-result isolation")
    }
}
