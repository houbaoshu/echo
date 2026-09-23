import Foundation
import Combine
import Darwin
import ImageIO
import UniformTypeIdentifiers

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
    case image(CGImage)
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
    private var refreshing: Set<Location> = []
    private var pendingRefresh: Set<Location> = []
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
    /// The entry's place on disk, for Finder and the pasteboard. Reads still go through
    /// ProjectFileIO's descriptor-relative opens, which refuse links at every component.
    func url(for path: String) -> URL? {
        guard let location else { return nil }
        return URL(fileURLWithPath: location.root).appendingPathComponent(path)
    }
    /// The tree's highlight, which the pointer and the arrow keys move. Opening a file
    /// is a separate step, so walking the tree never replaces it with a preview.
    func highlight(_ path: String) { state.selectedPath = path }
    func toggleDirectory(_ path: String) {
        // A click selects the row whether it opens or closes, the way Finder does. In the
        // tree the selection is only the highlight; the preview page reads selectedPath
        // solely while showingFile is set, so a folder never becomes a previewed file.
        state.selectedPath = path
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
    func loadDirectory(_ path: String = "") {
        guard let location else { return }
        let request = UUID(), generation = generation, readDirectory = readDirectory
        directoryRequests[path] = request
        state.directories[path] = .loading
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
    /// Re-reads every directory the tree knows about, without ever showing `.loading`
    /// over content that is already on screen.
    ///
    /// Results are applied one per run loop turn, and only where the listing actually
    /// changed. The sidebar list is an NSOutlineView, and two of its groups gaining rows
    /// in a single SwiftUI update make it insert rows from inside its own delegate
    /// callbacks — see docs/repros/swiftui-outline-list-reentrancy.swift. Reading every
    /// directory concurrently but committing the results one at a time keeps each group's
    /// insertion in an update of its own.
    func refresh() {
        guard let location else { return }
        generation = UUID(); directoryRequests = [:]
        guard refreshing.insert(location).inserted else {
            pendingRefresh.insert(location)
            return
        }
        if state.showingFile, let path = state.selectedPath { openFile(path, preservingContent: true) }
        let paths = Set(state.directories.keys).union(state.expanded).union([""])
        let request = UUID(), generation = generation, readDirectory = readDirectory
        for path in paths { directoryRequests[path] = request }
        Task { [weak self] in
            let results = await withTaskGroup(of: (String, ProjectDirectoryState).self) { group in
                for path in paths {
                    group.addTask(priority: .userInitiated) { (path, readDirectory(location.root, path)) }
                }
                var results: [(String, ProjectDirectoryState)] = []
                for await result in group { results.append(result) }
                return results
            }
            for (path, result) in results {
                // A newer selection or refresh abandons everything still unapplied; a newer
                // load of one directory only abandons that directory.
                guard let self, self.location == location, self.generation == generation else { break }
                guard self.directoryRequests[path] == request else { continue }
                self.directoryRequests[path] = nil
                guard self.state.directories[path] != result else { continue }
                self.state.directories[path] = result
                await Self.commitSeparately()
            }
            self?.finishRefresh(at: location)
        }
    }
    private func finishRefresh(at location: Location) {
        refreshing.remove(location)
        if pendingRefresh.remove(location) != nil, self.location == location { refresh() }
    }
    /// Hands back one run loop turn, so the list applies the directory just written before
    /// the next one changes.
    private static func commitSeparately() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

// All entry inspection and reads run off the main actor. Descriptor-relative opens
// refuse links at every path component, including directories replaced after listing.
enum ProjectFileIO {
    static let previewLimit = 1_048_576
    static let imagePreviewLimit = 32 * 1_048_576
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
            guard info.st_mode & S_IFMT == S_IFREG else { return .information("仅支持预览普通文本和图片文件。") }
            let ext = (path as NSString).pathExtension.lowercased()
            let isImage = UTType(filenameExtension: ext)?.conforms(to: .image) == true
                || ["png", "jpg", "jpeg", "webp", "gif"].contains(ext)
            let limit = isImage ? imagePreviewLimit : previewLimit
            let sizeMessage = isImage ? "图片超过 32 MiB，无法预览。" : "文件超过 1 MiB，无法预览。"
            guard info.st_size <= limit else { return .information(sizeMessage) }
            var bytes = [UInt8](repeating: 0, count: limit + 1)
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
            guard total <= limit else { return .information(sizeMessage) }
            let data = Data(bytes.prefix(total))
            if isImage {
                // Decode off the main actor, apply orientation and bound decoded memory.
                // GIFs use their first frame; no animation or editing state is needed.
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 4096,
                        kCGImageSourceShouldCacheImmediately: true
                      ] as CFDictionary) else {
                    return .information("无法预览图片：文件已损坏或格式不受支持。")
                }
                return .image(image)
            }
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
