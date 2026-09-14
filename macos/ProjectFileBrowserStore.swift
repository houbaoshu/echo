import Foundation
import Combine
import Darwin

struct ProjectFileEntry: Identifiable, Equatable, Sendable {
    enum Kind: Sendable { case directory, file, symbolicLink, other }
    var id: String { path }
    let path: String
    let name: String
    let kind: Kind
}

enum ProjectDirectoryState: Equatable, Sendable {
    case loading
    case loaded([ProjectFileEntry])
    case failed(String)
}

enum ProjectFilePreview: Equatable, Sendable {
    case loading
    case text(String)
    case information(String)
    case failed(String)
}

// No file content or navigation state is part of WorkspaceSnapshot.
@MainActor final class ProjectFileBrowserStore: ObservableObject {
    struct Location: Hashable, Sendable {
        let projectID: UUID
        let root: String
    }
    struct BrowsingState {
        var directories: [String: ProjectDirectoryState] = [:]
        var expanded: Set<String> = []
        var selectedPath: String?
        var showingFile = false
        var preview: ProjectFilePreview = .loading
        var scrollID: String?
    }
    @Published private(set) var location: Location?
    @Published private(set) var state = BrowsingState()
    // Temporary presentation state, deliberately excluded from the per-project cache.
    @Published private(set) var isPreviewExpanded = false
    private var watcher: ProjectFileWatcher?
    private var watchID = UUID()
    private var cache: [Location: BrowsingState] = [:]
    private var generation = UUID()
    private var directoryRequests: [String: UUID] = [:]
    private var previewRequest = UUID()
    private let readDirectory: @Sendable (String, String) -> ProjectDirectoryState
    private let readPreview: @Sendable (String, String) -> ProjectFilePreview

    init(readDirectory: @escaping @Sendable (String, String) -> ProjectDirectoryState = ProjectFileIO.directory,
         readPreview: @escaping @Sendable (String, String) -> ProjectFilePreview = ProjectFileIO.preview) {
        self.readDirectory = readDirectory; self.readPreview = readPreview
    }

    func select(project: WorkspaceProject?) {
        let next = project.map { Location(projectID: $0.id, root: URL(fileURLWithPath: $0.path).standardizedFileURL.path) }
        guard next != location else { return }
        collapsePreview()
        if let location { cache[location] = state }
        watcher = nil; watchID = UUID()
        generation = UUID(); directoryRequests = [:]; previewRequest = UUID()
        location = next
        state = next.flatMap { cache[$0] } ?? BrowsingState()
        guard let next else { return }
        let watchID = watchID
        watcher = ProjectFileWatcher(root: next.root) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.watchID == watchID, self.location == next else { return }
                self.refresh()
            }
        }
        // Refresh saved positions too: a project may have changed while off screen.
        refresh()
    }
    func setScrollID(_ path: String?) { state.scrollID = path }
    func toggleDirectory(_ path: String) {
        if state.expanded.contains(path) { state.expanded.remove(path) }
        else {
            state.expanded.insert(path)
            if state.directories[path] == nil { loadDirectory(path) }
        }
    }
    func togglePreviewExpansion() {
        guard location != nil, state.showingFile, state.selectedPath != nil else { return }
        isPreviewExpanded.toggle()
    }
    func collapsePreview() {
        if isPreviewExpanded { isPreviewExpanded = false }
    }
    func returnToDirectory() { collapsePreview(); state.showingFile = false }
    func openFile(_ path: String, preservingContent: Bool = false) {
        guard let location else { return }
        if state.selectedPath != path { collapsePreview() }
        state.selectedPath = path; state.showingFile = true
        if !preservingContent { state.preview = .loading }
        let request = UUID(), generation = generation, readPreview = readPreview
        previewRequest = request
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                readPreview(location.root, path)
            }.value
            guard let self, self.location == location, self.generation == generation,
                  self.previewRequest == request else { return }
            self.state.preview = result
        }
    }
    func loadDirectory(_ path: String = "", preservingContent: Bool = false) {
        guard let location else { return }
        let request = UUID(), generation = generation, readDirectory = readDirectory
        directoryRequests[path] = request
        if !preservingContent { state.directories[path] = .loading }
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                readDirectory(location.root, path)
            }.value
            guard let self, self.location == location, self.generation == generation,
                  self.directoryRequests[path] == request else { return }
            self.state.directories[path] = result
            self.directoryRequests[path] = nil
        }
    }
    func refresh(projectID: UUID?) {
        guard let projectID, projectID == location?.projectID else { return }
        refresh()
    }
    func refresh() {
        guard location != nil else { return }
        generation = UUID(); directoryRequests = [:]
        let paths = Set(state.directories.keys).union(state.expanded).union([""])
        for path in paths { loadDirectory(path, preservingContent: true) }
        if state.showingFile, let path = state.selectedPath { openFile(path, preservingContent: true) }
    }
}

// All entry inspection and reads run off the main actor. Descriptor-relative opens
// refuse links at every path component, including directories replaced after listing.
enum ProjectFileIO {
    static let previewLimit = 1_048_576
    private static func errorMessage(_ code: Int32) -> String {
        switch code {
        case ENOENT: return "文件或文件夹已删除或不可用。"
        case EACCES, EPERM: return "没有权限读取此文件或文件夹。"
        case ELOOP: return "符号链接不跟随，请在 Finder 中查看。"
        case ENOTDIR: return "文件夹不可用或已被替换。"
        default: return "读取失败：\(String(cString: strerror(code)))"
        }
    }
    private struct ReadError: Error { let message: String }
    private static func descriptor(root: String, path: String, directory: Bool) throws -> Int32 {
        let parts = path.split(separator: "/").map(String.init)
        guard !path.hasPrefix("/"), !parts.contains(".."), !parts.contains(".") else {
            throw ReadError(message: "路径不属于当前项目。")
        }
        var fd = Darwin.open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ReadError(message: errorMessage(errno)) }
        for (index, part) in parts.enumerated() {
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
                | (index < parts.count - 1 || directory ? O_DIRECTORY : 0)
            let next = openat(fd, part, flags)
            let code = errno
            close(fd)
            guard next >= 0 else { throw ReadError(message: errorMessage(code)) }
            fd = next
        }
        return fd
    }
    static func directory(root: String, path: String) -> ProjectDirectoryState {
        do {
            let fd = try descriptor(root: root, path: path, directory: true)
            guard let dir = fdopendir(fd) else { let code = errno; close(fd); throw ReadError(message: errorMessage(code)) }
            defer { closedir(dir) }
            var entries: [ProjectFileEntry] = []
            while true {
                errno = 0
                guard let entry = readdir(dir) else {
                    if errno != 0 { throw ReadError(message: errorMessage(errno)) }
                    break
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
                }
                if name.hasPrefix(".") { continue }
                var info = stat()
                guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                    if errno == ENOENT { continue }
                    throw ReadError(message: errorMessage(errno))
                }
                if info.st_flags & UInt32(UF_HIDDEN) != 0 { continue }
                let kind: ProjectFileEntry.Kind
                switch info.st_mode & S_IFMT {
                case S_IFDIR: kind = .directory
                case S_IFREG: kind = .file
                case S_IFLNK: kind = .symbolicLink
                default: kind = .other
                }
                entries.append(.init(path: path.isEmpty ? name : path + "/" + name, name: name, kind: kind))
            }
            return .loaded(entries.sorted {
                if ($0.kind == .directory) != ($1.kind == .directory) { return $0.kind == .directory }
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame ? $0.name < $1.name : order == .orderedAscending
            })
        } catch let error as ReadError { return .failed(error.message) }
        catch { return .failed(error.localizedDescription) }
    }
    static func preview(root: String, path: String) -> ProjectFilePreview {
        do {
            let fd = try descriptor(root: root, path: path, directory: false)
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw ReadError(message: errorMessage(errno)) }
            guard info.st_mode & S_IFMT == S_IFREG else { return .information("仅支持预览普通文本文件。") }
            guard info.st_size <= previewLimit else { return .information("文件超过 1 MiB，无法预览。") }
            var bytes = [UInt8](repeating: 0, count: previewLimit + 1)
            var total = 0
            while total < bytes.count {
                let count = bytes.withUnsafeMutableBytes { buffer in
                    Darwin.read(fd, buffer.baseAddress!.advanced(by: total), buffer.count - total)
                }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw ReadError(message: errorMessage(errno))
                }
                if count == 0 { break }
                total += count
            }
            guard total <= previewLimit else { return .information("文件超过 1 MiB，无法预览。") }
            let data = Data(bytes.prefix(total))
            let text: String?
            if data.starts(with: [0xFF, 0xFE]) { text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) }
            else if data.starts(with: [0xFE, 0xFF]) { text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
            else { text = String(data: data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data, encoding: .utf8) }
            guard let text, !text.unicodeScalars.contains(where: {
                ($0.value < 32 && $0.value != 9 && $0.value != 10 && $0.value != 13) || $0.value == 127
            }) else { return .information("二进制文件或不支持的文本编码。支持 UTF-8 和带 BOM 的 UTF-16。") }
            return .text(text)
        } catch let error as ReadError {
            if error.message.hasPrefix("符号链接") { return .information(error.message) }
            return .failed(error.message)
        } catch { return .failed(error.localizedDescription) }
    }
}
