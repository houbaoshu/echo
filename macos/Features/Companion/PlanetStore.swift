import AppKit
import Combine
import Observation
import ImageIO

/// One bundled or imported planet. A planet directory is a pet directory: the same `pet.json` manifest and the
/// same sprite sheet, so the Rust runtime loads it without knowing the difference.
struct PlanetEntry: Identifiable {
    let id: String
    let name: String
    let description: String
    let directory: URL
    let preview: CGImage
}

/// Live Voice's planet, shared by the chat window and the pet's control strip.
///
/// It owns the one sprite instance both surfaces draw, and drives it straight from the voice
/// snapshot rather than from a view: two views driving it would fight over the animation clock,
/// because every `set_animation` restarts it.
@MainActor @Observable final class PlanetStore {
    /// Filled when the settings page opens; the app itself only needs the selected one.
    private(set) var entries: [PlanetEntry] = []
    private(set) var selectedID: String
    /// The card an import added or found already listed, so the grid can scroll to it.
    private(set) var highlightedID: String?
    /// Loaded only while Live Voice runs. Dropping it frees the frames on both sides of the FFI.
    private(set) var active: PetStore?
    var notice: String?
    /// The clip the planet is playing, so a test can assert a swap kept the current state.
    @ObservationIgnored private(set) var playing: String?
    /// How long the runtime's `review` clip plays once. The default follows its timing in
    /// runtime/src/model.rs:305: six frames, the first five 150 ms each and the last held 280 ms.
    private let endingDuration: Duration
    private let settings: SettingsStore?
    private let root: URL?
    private let importedRoot: URL?
    private let trash: AgentTrash
    @ObservationIgnored private var current: PetSurfacePresentation.VoiceIndicator = .inactive
    @ObservationIgnored private weak var voice: VoiceSessionController?
    @ObservationIgnored private var voiceObservation: ObservationHandle?
    @ObservationIgnored private var reduceMotionObservation: AnyCancellable?

    init(settings: SettingsStore? = nil, root: URL? = nil, importedRoot: URL? = nil, voice: VoiceSessionController? = nil,
         endingDuration: Duration = .milliseconds(1030), trash: AgentTrash = .system) {
        self.endingDuration = endingDuration
        self.trash = trash
        self.settings = settings
        self.root = root
        self.importedRoot = importedRoot
        self.voice = voice
        selectedID = settings?.snapshot.selectedPlanetID ?? SettingsSnapshot.defaultPlanetID
        if let voice {
            voiceObservation = observeChanges({ [weak voice] in
                voice.map { PetSurfacePresentation.indicator(for: $0.snapshot) } ?? .inactive
            }, initial: true) { [weak self] indicator in self?.apply(indicator) }
        }
        reduceMotionObservation = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.active?.isPaused = Self.reduceMotion }
            }
    }

    // MARK: - State

    /// The clip each state asks for. The runtime decides whether a sprite has it; `idle` is the
    /// one clip it guarantees, so that is what plays in its place.
    static func animationName(for indicator: PetSurfacePresentation.VoiceIndicator) -> String {
        switch indicator {
        case .inactive: "idle"
        case .connecting: "waiting"
        case .listening: "idle"
        case .thinking: "running"
        case .speaking: "spinning"
        case .ending: "review"
        }
    }

    private func apply(_ indicator: PetSurfacePresentation.VoiceIndicator, force: Bool = false) {
        current = indicator
        guard indicator != .inactive else { release(); return }
        guard let store = load() else { return }
        let name = Self.animationName(for: indicator)
        guard force || name != playing else { return }
        playing = store.play(name, fallback: "idle")
    }

    private func release() {
        guard let active else { return }
        active.stop()
        unload()
    }

    /// Forgets the sprite and everything derived from it.
    private func unload() {
        active = nil
        playing = nil
        voice?.endingAnimationDuration = .zero
    }

    // MARK: - Selection

    func select(_ id: String) {
        guard id != selectedID else { return }
        guard let directory = directory(for: id) else {
            notice = String(localized: "所选星球不存在，请重新选择。")
            return
        }
        do {
            // Build before persisting, the way the pet catalog does: a planet that cannot load
            // must not become the saved choice. Nothing is built while Live Voice is idle.
            let next = active == nil ? nil : try VoiceDiagnostics.shared.measure("PlanetStore.select 通话中换星球", id) {
                try makeStore(at: directory)
            }
            do { try settings?.selectPlanet(id) } catch { next?.stop(); throw error }
            selectedID = id
            notice = nil
            guard let next else { return }
            let previous = active
            active = next
            previous?.stop()
            voice?.endingAnimationDuration = endingDuration
            next.start()
            // The indicator stream is de-duplicated, so a swap has to replay the current state
            // itself. Without this the new planet sits in idle until Live Voice happens to move.
            apply(current, force: true)
        } catch {
            notice = String(localized: "切换失败，保留当前星球：\(error.localizedDescription)")
        }
    }

    /// Read the bundled planets, then the imported ones, for the settings grid. Each time the page
    /// opens, so a folder put back from the Trash shows up without a relaunch. A planet already
    /// listed is kept as it is rather than decoded again; the planet in use is never touched.
    func loadEntries() {
        var loaded: [PlanetEntry] = []
        var skipped = false
        for (root, prefix) in [(root, "builtin"), (importedRoot, "imported")] {
            guard let root else { continue }
            for directory in directories(in: root) {
                let id = "\(prefix):\(directory.lastPathComponent)"
                if let entry = entries.first(where: { $0.id == id }) ?? entry(at: directory, id: id) {
                    loaded.append(entry)
                } else { skipped = true }
            }
        }
        entries = loaded
        if skipped { notice = String(localized: "部分星球素材无法读取，已跳过。") }
    }

    /// Import a planet folder the way the pet catalog imports a pet: checked, compared with the
    /// listed planets, staged, checked again and only then installed. It is not selected.
    @discardableResult func importPlanet(from directory: URL) -> String? {
        guard let importedRoot else { notice = String(localized: "星球导入目录不可用。"); return nil }
        loadEntries()
        do {
            let fingerprint = try validated(directory, id: "candidate").fingerprint
            // Listed planets are fingerprinted only here, so opening the page never reads whole sheets.
            if let existing = entries.first(where: { (try? SpriteFolder.read($0.directory).fingerprint) == fingerprint }) {
                highlightedID = existing.id; notice = String(localized: "这颗星球已在列表中。"); return existing.id
            }
            let entry = try SpriteFolder.install(directory, into: importedRoot) { folder, name in
                try validated(folder, id: name.map { "imported:\($0)" } ?? "staging").entry
            }
            entries.append(entry); highlightedID = entry.id
            notice = String(localized: "已导入“\(entry.name)”，点击卡片即可切换。")
            return entry.id
        } catch {
            notice = String(localized: "导入失败：%@|星球", defaultValue: "导入失败：\(error.localizedDescription)"); return nil
        }
    }

    /// Move an imported planet's folder to the Trash, under its own name so Put Back restores it.
    /// The planet in use first gives way to the default one, swapped in at once during a call.
    @discardableResult func moveToTrash(_ id: String) -> Bool {
        guard id.hasPrefix("imported:") else { return false }
        if id == selectedID {
            select(SettingsSnapshot.defaultPlanetID)
            guard selectedID == SettingsSnapshot.defaultPlanetID else {
                notice = String(localized: "无法先换回默认星球，未移到废纸篓。"); return false
            }
        }
        do {
            guard let directory = directory(for: id) else { throw CocoaError(.fileNoSuchFile) }
            try trash.move(directory)
        } catch {
            notice = String(localized: "无法移到废纸篓：\(error.localizedDescription)"); return false
        }
        entries.removeAll { $0.id == id }
        if highlightedID == id { highlightedID = nil }
        notice = nil
        return true
    }

    /// What a folder must pass to be imported: the shared folder checks, a sprite the runtime
    /// loads, and a card this page can draw.
    private func validated(_ directory: URL, id: String) throws -> (entry: PlanetEntry, fingerprint: String) {
        let contents = try SpriteFolder.read(directory)
        try PetStore(directory: directory).stop()
        guard let entry = entry(at: directory, id: id) else { throw SettingsError(localized: "无法读取星球素材。") }
        return (entry, contents.fingerprint)
    }

    // MARK: - Loading

    private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func load() -> PetStore? {
        if let active { return active }
        guard let directory = resolvedDirectory() else { return nil }
        do {
            // Covers what the call waits for when a planet loads: the sprite, then its first frame.
            let store = try VoiceDiagnostics.shared.measure("PlanetStore.load", directory.lastPathComponent) {
                try makeStore(at: directory)
            }
            active = store
            voice?.endingAnimationDuration = endingDuration
            playing = nil
            store.start()
            return store
        } catch {
            // Every later voice state change retries the load; one line per retry shows if that happens.
            VoiceDiagnostics.shared.mark("PlanetStore.load 失败，下一次状态变化会重试")
            notice = String(localized: "星球素材无法加载：\(error.localizedDescription)")
            return nil
        }
    }

    private func makeStore(at directory: URL) throws -> PetStore {
        let store = try PetStore(directory: directory)
        store.onFailure = { [weak self] error in
            MainActor.assumeIsolated {
                self?.notice = String(localized: "星球动画已停止：\(error.localizedDescription)")
                self?.unload()
            }
        }
        store.isPaused = Self.reduceMotion
        return store
    }

    /// The selected planet, or the first bundled one if the saved choice is gone.
    private func resolvedDirectory() -> URL? {
        if let directory = directory(for: selectedID) { return directory }
        guard let root, let first = directories(in: root).first else { return nil }
        selectedID = "builtin:\(first.lastPathComponent)"
        notice = String(localized: "上次选择的星球无法加载，已换成另一颗。")
        try? settings?.selectPlanet(selectedID)
        return first
    }

    private func directories(in root: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return contents.filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Resolve an id to a bundled or imported directory. The id comes from `settings.json`, so it
    /// is treated as untrusted input and may only name a direct child of its own planets folder.
    private func directory(for id: String) -> URL? {
        let roots = [("builtin:", root), ("imported:", importedRoot)]
        guard let (prefix, root) = roots.first(where: { id.hasPrefix($0.0) }), let root else { return nil }
        return SpriteFolder.child(named: String(id.dropFirst(prefix.count)), of: root)
    }

    // MARK: - Manifest

    private struct Manifest: Decodable {
        struct Frame: Decodable {
            let width: Int
            let height: Int
            let columns: Int
            let rows: Int
        }
        var displayName: String?
        var description: String?
        var spritesheetPath: String?
        var spriteVersionNumber: Int?
        var frame: Frame?
    }

    private func manifest(at directory: URL) -> Manifest? {
        let url = directory.appendingPathComponent("pet.json")
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    /// Mirrors the runtime's implicit grid in `Pet::from_manifest`, `runtime/src/model.rs`.
    private static let defaultFrame = Manifest.Frame(width: 192, height: 208, columns: 8, rows: 11)

    private func entry(at directory: URL, id: String) -> PlanetEntry? {
        guard let manifest = manifest(at: directory), manifest.spriteVersionNumber == 2 else { return nil }
        let relative = manifest.spritesheetPath ?? "spritesheet.webp"
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { return nil }
        let sheet = directory.appendingPathComponent(relative)
        guard let source = CGImageSourceCreateWithURL(sheet as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 16_777_216 else { return nil }
        let grid = manifest.frame ?? Self.defaultFrame
        guard grid.width > 0, grid.height > 0, grid.columns > 0, grid.rows > 0,
              width == grid.width * grid.columns, height == grid.height * grid.rows else { return nil }
        // Frame 0 alone is the card's preview. Decoding the sheet once here is far cheaper than
        // building a PetStore, which slices and keeps every frame just to hand back one image.
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let preview = image.cropping(to: CGRect(x: 0, y: 0, width: grid.width, height: grid.height)) else { return nil }
        let name = manifest.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return PlanetEntry(id: id,
                           name: name.flatMap { $0.isEmpty ? nil : $0 } ?? directory.lastPathComponent,
                           description: manifest.description ?? "",
                           directory: directory, preview: preview)
    }
}
