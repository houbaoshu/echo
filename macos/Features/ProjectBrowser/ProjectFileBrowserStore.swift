import Foundation
import Observation
import CoreGraphics

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
@MainActor @Observable final class ProjectFileBrowserStore {
    struct Location: Hashable, Sendable {
        let projectID: UUID
        let root: String
    }
    struct BrowsingState {
        var directories: [String: ProjectDirectoryState] = [:]
        var expanded: Set<String> = []
        /// The tree's highlight: one row, several, or none.
        var selection: Set<String> = []
        /// The one selected row, which is also the file the preview page shows. Nil while
        /// several rows or none are selected.
        var selectedPath: String? { selection.count == 1 ? selection.first : nil }
        var showingFile = false
        var preview: ProjectFilePreview = .loading
        var scrollID: String?
    }
    private(set) var location: Location?
    private(set) var state = BrowsingState()
    // Temporary presentation state, deliberately excluded from the per-project cache.
    private(set) var isPreviewExpanded = false
    @ObservationIgnored private var watcher: ProjectFileWatcher?
    @ObservationIgnored private var watchID = UUID()
    @ObservationIgnored private var cache: [Location: BrowsingState] = [:]
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var directoryRequests: [String: UUID] = [:]
    @ObservationIgnored private var refreshing: Set<Location> = []
    @ObservationIgnored private var pendingRefresh: Set<Location> = []
    @ObservationIgnored private var previewRequest = UUID()
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
        if let location {
            // Not a decoded image, which can take 64 MiB and would stay for as long as Echo runs:
            // coming back to the project reads it again, as its refresh does anyway.
            var kept = state
            if case .image = kept.preview { kept.preview = .loading }
            cache[location] = kept
        }
        watcher = nil; watchID = UUID()
        generation = UUID(); directoryRequests = [:]; previewRequest = UUID()
        location = next
        state = next.flatMap { cache[$0] } ?? BrowsingState()
        guard let next else { return }
        let watchID = watchID
        watcher = ProjectFileWatcher(root: next.root) { [weak self] in
            Task { @MainActor [weak self] in
                // watchID is renewed with every location, so it also rules out a later project.
                guard let self, self.watchID == watchID else { return }
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
    /// The tree's highlight, which the pointer, ⇧ / ⌘ clicks and the arrow keys move.
    /// Opening a file is a separate step, so walking the tree never replaces it with a
    /// preview. The row to scroll back to is the first one a change added, so a range
    /// comes back from its top.
    func setSelection(_ paths: Set<String>) {
        let added = paths.subtracting(state.selection)
        state.selection = paths
        if let first = inTreeOrder(added).first { state.scrollID = first }
    }
    /// The paths among `paths` that the tree shows, in the order it shows them.
    func inTreeOrder(_ paths: Set<String>) -> [String] {
        var ordered: [String] = []
        func walk(_ directory: String) {
            guard case .loaded(let entries) = state.directories[directory] else { return }
            for entry in entries where ordered.count < paths.count {
                if paths.contains(entry.path) { ordered.append(entry.path) }
                if entry.kind == .directory, state.expanded.contains(entry.path) { walk(entry.path) }
            }
        }
        walk("")
        return ordered
    }
    /// What a drag that starts on `path` carries, as in Finder: the whole selection when
    /// the row is part of it, otherwise that row alone.
    func draggedPaths(from path: String) -> [String] {
        state.selection.contains(path) ? inTreeOrder(state.selection) : [path]
    }
    /// A click, Return or an accessibility press activates a row: a folder opens or
    /// closes, a file opens its preview. The list's own triangle only ever discloses, and
    /// it is also what a folder row's accessibility press reaches.
    func activate(_ entry: ProjectFileEntry) {
        if entry.kind == .directory { activateDirectory(entry.path) }
        else { openFile(entry.path) }
    }
    /// Return activates the one selected row; over several it does nothing.
    func activateSelection() {
        guard let path = state.selectedPath,
              case .loaded(let entries) = state.directories[(path as NSString).deletingLastPathComponent],
              let entry = entries.first(where: { $0.path == path }) else { return }
        activate(entry)
    }
    /// A click on a folder: it alone is selected, the way Finder selects it, whether it
    /// opens or closes. In the tree the selection is only the highlight; the preview page
    /// reads selectedPath solely while showingFile is set, so a folder never becomes a
    /// previewed file.
    func activateDirectory(_ path: String) {
        state.selection = [path]
        toggleDirectory(path)
    }
    /// Opening or closing alone, as the disclosure triangle and ← / → do: the list keeps
    /// whatever is selected, several rows included.
    func toggleDirectory(_ path: String) {
        if state.expanded.contains(path) { state.expanded.remove(path) }
        else {
            state.expanded.insert(path)
            if state.directories[path] == nil { loadDirectory(path) }
        }
    }
    func togglePreviewExpansion() {
        // showingFile is only ever set while a project is.
        guard state.showingFile, state.selectedPath != nil else { return }
        isPreviewExpanded.toggle()
    }
    func collapsePreview() {
        if isPreviewExpanded { isPreviewExpanded = false }
    }
    func returnToDirectory() { collapsePreview(); state.showingFile = false }
    func openFile(_ path: String) {
        guard location != nil else { return }
        if state.selectedPath != path { collapsePreview() }
        state.selection = [path]; state.showingFile = true
        state.preview = .loading
        reloadPreview(path)
    }
    /// Reads `path` into the preview, which keeps showing what it has until the read lands.
    private func reloadPreview(_ path: String) {
        guard let location else { return }
        let request = UUID(), generation = generation, readPreview = readPreview
        previewRequest = request
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                readPreview(location.root, path)
            }.value
            guard let self, self.location == location, self.generation == generation,
                  self.previewRequest == request, self.state.preview != result else { return }
            self.state.preview = result
        }
    }
    func loadDirectory(_ path: String) {
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
    /// callbacks — see tests/tools/SwiftUIOutlineListReentrancy.swift. Reading every
    /// directory concurrently but committing the results one at a time keeps each group's
    /// insertion in an update of its own.
    func refresh() {
        guard let location else { return }
        generation = UUID(); directoryRequests = [:]
        guard refreshing.insert(location).inserted else {
            pendingRefresh.insert(location)
            return
        }
        if state.showingFile, let path = state.selectedPath { reloadPreview(path) }
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
