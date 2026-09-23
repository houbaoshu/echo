import AppKit
import Combine
import ImageIO

/// One bundled planet. A planet directory is a pet directory: the same `pet.json` manifest and the
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
@MainActor final class PlanetStore: ObservableObject {
    /// Filled the first time the settings page asks; the app itself only needs the selected one.
    @Published private(set) var entries: [PlanetEntry] = []
    @Published private(set) var selectedID: String
    /// Loaded only while Live Voice runs. Dropping it frees the frames on both sides of the FFI.
    @Published private(set) var active: PetStore?
    @Published var notice: String?
    /// The clip the planet is playing, so a test can assert a swap kept the current state.
    private(set) var playing: String?

    nonisolated static let defaultID = SettingsSnapshot.defaultPlanetID

    private let settings: SettingsStore?
    private let root: URL?
    private var current: PetSurfacePresentation.VoiceIndicator = .inactive
    /// Standard clips come from the Rust runtime; manifest clips can override or extend them.
    private var available: Set<String> = []
    private weak var voice: VoiceSessionController?
    private var voiceObservation: AnyCancellable?
    private var reduceMotionObservation: AnyCancellable?

    init(settings: SettingsStore? = nil, root: URL? = nil, voice: VoiceSessionController? = nil) {
        self.settings = settings
        self.root = root
        self.voice = voice
        selectedID = settings?.snapshot.selectedPlanetID ?? Self.defaultID
        voiceObservation = voice?.$snapshot
            .map { PetSurfacePresentation.indicator(for: $0) }
            .removeDuplicates()
            .sink { [weak self] indicator in
                MainActor.assumeIsolated { self?.apply(indicator) }
            }
        reduceMotionObservation = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.active?.isPaused = Self.reduceMotion }
            }
    }

    // MARK: - State

    /// Standard animation names are supplied by the Rust runtime even when absent from pet.json.
    static func animationName(for indicator: PetSurfacePresentation.VoiceIndicator,
                              available: Set<String>) -> String {
        let preferred: String
        switch indicator {
        case .inactive: preferred = "idle"
        case .connecting: preferred = "waiting"
        case .listening: preferred = "idle"
        case .thinking: preferred = "running"
        case .speaking: preferred = "spinning"
        case .ending: preferred = "review"
        }
        // `idle` is the one clip the runtime guarantees, so it is always a safe fallback.
        return available.contains(preferred) ? preferred : "idle"
    }

    private func apply(_ indicator: PetSurfacePresentation.VoiceIndicator, force: Bool = false) {
        current = indicator
        guard indicator != .inactive else { release(); return }
        guard let store = load() else { return }
        let name = Self.animationName(for: indicator, available: available)
        guard force || name != playing else { return }
        playing = name
        store.play(name)
    }

    private func release() {
        guard active != nil else { return }
        active?.stop()
        active = nil
        playing = nil
        available = []
        voice?.endingAnimationDuration = .zero
    }

    // MARK: - Selection

    func select(_ id: String) {
        guard id != selectedID else { return }
        guard let directory = directory(for: id) else {
            notice = "所选星球不存在，请重新选择。"
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
            available = animationNames(at: directory)
            voice?.endingAnimationDuration = .milliseconds(1030)
            next.start()
            // The indicator stream is de-duplicated, so a swap has to replay the current state
            // itself. Without this the new planet sits in idle until Live Voice happens to move.
            apply(current, force: true)
        } catch {
            notice = "切换失败，保留当前星球：\(error.localizedDescription)"
        }
    }

    /// Read the bundled planets for the settings grid.
    func loadEntries() {
        guard entries.isEmpty, let root else { return }
        var loaded: [PlanetEntry] = []
        var skipped = false
        for directory in directories(in: root) {
            if let entry = entry(at: directory) { loaded.append(entry) } else { skipped = true }
        }
        entries = loaded
        if skipped { notice = "部分星球素材无法读取，已跳过。" }
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
            available = animationNames(at: directory)
            voice?.endingAnimationDuration = .milliseconds(1030)
            playing = nil
            store.start()
            return store
        } catch {
            // Every later voice state change retries the load; one line per retry shows if that happens.
            VoiceDiagnostics.shared.mark("PlanetStore.load 失败，下一次状态变化会重试")
            notice = "星球素材无法加载：\(error.localizedDescription)"
            return nil
        }
    }

    private func makeStore(at directory: URL) throws -> PetStore {
        let store = try PetStore(directory: directory)
        store.onFailure = { [weak self] error in
            MainActor.assumeIsolated {
                self?.notice = "星球动画已停止：\(error.localizedDescription)"
                self?.active = nil
                self?.playing = nil
                self?.voice?.endingAnimationDuration = .zero
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
        notice = "上次选择的星球无法加载，已换成另一颗。"
        try? settings?.selectPlanet(selectedID)
        return first
    }

    private func directories(in root: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return contents.filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Resolve an id to a bundled directory. The id comes from `settings.json`, so it is treated
    /// as untrusted input and may only name a direct child of the planets folder.
    private func directory(for id: String) -> URL? {
        let prefix = "builtin:"
        guard let root, id.hasPrefix(prefix) else { return nil }
        let name = String(id.dropFirst(prefix.count))
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/") else { return nil }
        let directory = root.appendingPathComponent(name, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return directory
    }

    // MARK: - Manifest

    private struct Manifest: Decodable {
        struct Ignored: Decodable {}
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
        /// Only the keys matter here: which clips this planet declares.
        var animations: [String: Ignored]?
    }

    private func manifest(at directory: URL) -> Manifest? {
        let url = directory.appendingPathComponent("pet.json")
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    private func animationNames(at directory: URL) -> Set<String> {
        let manifest = manifest(at: directory)
        let grid = manifest?.frame ?? Self.defaultFrame(version: manifest?.spriteVersionNumber ?? 1)
        var standard: Set<String> = ["idle", "waiting", "running", "review"]
        if manifest?.spriteVersionNumber == 2 && grid.columns == 8 && grid.rows >= 11 {
            standard.insert("spinning")
        }
        return Set(manifest?.animations?.keys ?? [:].keys).union(standard)
    }

    /// Mirrors the runtime's implicit grid, `runtime/src/model.rs:87-97`.
    private static func defaultFrame(version: Int) -> Manifest.Frame {
        Manifest.Frame(width: 192, height: 208, columns: 8, rows: version == 2 ? 11 : 9)
    }

    private func entry(at directory: URL) -> PlanetEntry? {
        guard let manifest = manifest(at: directory) else { return nil }
        let relative = manifest.spritesheetPath ?? "spritesheet.webp"
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { return nil }
        let sheet = directory.appendingPathComponent(relative)
        guard let source = CGImageSourceCreateWithURL(sheet as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 16_777_216 else { return nil }
        let grid = manifest.frame ?? Self.defaultFrame(version: manifest.spriteVersionNumber ?? 1)
        guard grid.width > 0, grid.height > 0, grid.columns > 0, grid.rows > 0,
              width == grid.width * grid.columns, height == grid.height * grid.rows else { return nil }
        // Frame 0 alone is the card's preview. Decoding the sheet once here is far cheaper than
        // building a PetStore, which slices and keeps every frame just to hand back one image.
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let preview = image.cropping(to: CGRect(x: 0, y: 0, width: grid.width, height: grid.height)) else { return nil }
        let name = manifest.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return PlanetEntry(id: "builtin:\(directory.lastPathComponent)",
                           name: name.flatMap { $0.isEmpty ? nil : $0 } ?? directory.lastPathComponent,
                           description: manifest.description ?? "",
                           directory: directory, preview: preview)
    }
}
