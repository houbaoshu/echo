import AppKit
import CryptoKit
import ImageIO

struct PetEntry: Identifiable {
    let id: String
    let directory: URL
    let name: String
    let description: String
    let preview: CGImage
    let fingerprint: String
    let builtin: Bool
}

@MainActor final class PetCatalog: ObservableObject {
    @Published private(set) var entries: [PetEntry] = []
    @Published var notice: String?
    @Published private(set) var selectedID = "builtin:chiyan"
    @Published private(set) var highlightedID: String?
    private(set) var activeStore: PetStore?
    var onActivate: ((PetStore) -> Void)?
    var onFailure: ((Error) -> Void)?
    private let settings: SettingsStore
    private let importedRoot: URL?
    init(settings: SettingsStore, builtinRoot: URL? = nil, importedRoot: URL? = nil) {
        self.settings = settings; self.importedRoot = importedRoot
        selectedID = settings.snapshot.selectedPetID
        for (root, builtin) in [(builtinRoot, true), (importedRoot, false)] {
            guard let root else { continue }
            let directories = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for directory in directories.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where !directory.lastPathComponent.hasPrefix(".") {
                do {
                    let id = "\(builtin ? "builtin" : "imported"):\(directory.lastPathComponent)"
                    entries.append(try read(directory, id: id, builtin: builtin))
                } catch { notice = "部分精灵素材无法加载，已跳过。可重新导入有效的精灵文件夹。" }
            }
        }
    }
    private struct Manifest: Decodable {
        let displayName: String
        let description: String?
        let spritesheetPath: String?
    }
    private func files(_ directory: URL) throws -> (Data, Data, URL, Manifest) {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let manifestURL = root.appendingPathComponent("pet.json").resolvingSymlinksInPath()
        guard manifestURL.path.hasPrefix(root.path + "/") else { throw SettingsError("pet.json 必须位于所选文件夹内。") }
        let manifestSize = try manifestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard manifestSize <= 1_048_576 else { throw SettingsError("pet.json 文件过大。") }
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        let relative = manifest.spritesheetPath ?? "spritesheet.webp"
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else {
            throw SettingsError("精灵图必须使用文件夹内的相对路径。")
        }
        let sheetURL = root.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
        guard sheetURL.path.hasPrefix(root.path + "/"), sheetURL.pathExtension.lowercased() == "webp" else {
            throw SettingsError("精灵图必须是所选文件夹内的 WebP 文件。")
        }
        let size = try sheetURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 33_554_432 else { throw SettingsError("精灵图文件不能超过 32 MB。") }
        let sheet = try Data(contentsOf: sheetURL)
        guard let source = CGImageSourceCreateWithData(sheet as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 16_777_216 else {
            throw SettingsError("精灵图损坏或尺寸过大（最多 1600 万像素）。")
        }
        return (data, sheet, sheetURL, manifest)
    }
    private func read(_ directory: URL, id: String, builtin: Bool) throws -> PetEntry {
        let (manifestData, sheet, _, manifest) = try files(directory)
        var hash = SHA256(); hash.update(data: manifestData); hash.update(data: Data([0])); hash.update(data: sheet)
        let fingerprint = hash.finalize().map { String(format: "%02x", $0) }.joined()
        let store = try PetStore(directory: directory)
        defer { store.stop() }
        return PetEntry(id: id, directory: directory, name: store.displayName,
                        description: manifest.description ?? "", preview: store.image, fingerprint: fingerprint, builtin: builtin)
    }
    func loadInitial() throws -> PetStore {
        if let selected = entries.first(where: { $0.id == selectedID }), let store = try? PetStore(directory: selected.directory) {
            activeStore = store; store.onFailure = onFailure; return store
        }
        guard let fallback = entries.first(where: { $0.id == "builtin:chiyan" }) else { throw SettingsError("应用内缺少有效的赤焰精灵素材。") }
        let store = try PetStore(directory: fallback.directory)
        activeStore = store; store.onFailure = onFailure; selectedID = fallback.id
        notice = "上次选择的精灵无法加载，已恢复为赤焰。"
        do { try settings.selectPet(fallback.id) } catch { notice = "已恢复为赤焰，但无法保存选择。" }
        return store
    }
    @discardableResult func activate(_ id: String) -> Bool {
        guard id != selectedID || activeStore == nil else { return true }
        guard let entry = entries.first(where: { $0.id == id }) else { notice = "所选精灵不存在，请重新导入。"; return false }
        do {
            _ = try files(entry.directory)
            let next = try PetStore(directory: entry.directory)
            do { try settings.selectPet(id) } catch { next.stop(); throw error }
            let previous = activeStore
            next.onFailure = onFailure; activeStore = next; selectedID = id
            onActivate?(next)
            previous?.stop(); next.start(); notice = nil
            return true
        } catch { notice = "切换失败，保留当前精灵：\(error.localizedDescription)"; return false }
    }
    @discardableResult func importPet(from directory: URL) -> String? {
        guard let importedRoot else { notice = "精灵导入目录不可用。"; return nil }
        let fm = FileManager.default
        var staging: URL?
        do {
            let candidate = try read(directory, id: "candidate", builtin: false)
            if let existing = entries.first(where: { $0.fingerprint == candidate.fingerprint }) {
                highlightedID = existing.id; notice = "这只精灵已在列表中。"; return existing.id
            }
            let (manifest, sheet, _, metadata) = try files(directory)
            try fm.createDirectory(at: importedRoot, withIntermediateDirectories: true)
            let temporary = importedRoot.appendingPathComponent(".import-\(UUID().uuidString)")
            staging = temporary
            try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
            try manifest.write(to: temporary.appendingPathComponent("pet.json"))
            let sheetDestination = temporary.appendingPathComponent(metadata.spritesheetPath ?? "spritesheet.webp")
            try fm.createDirectory(at: sheetDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try sheet.write(to: sheetDestination)
            // Validate copied bytes as well, so a changed source cannot install a broken pet.
            _ = try read(temporary, id: "staging", builtin: false)
            let name = UUID().uuidString
            let destination = importedRoot.appendingPathComponent(name)
            let id = "imported:\(name)"
            try fm.moveItem(at: temporary, to: destination)
            staging = destination
            let entry = try read(destination, id: id, builtin: false)
            entries.append(entry); highlightedID = id; staging = nil
            notice = "已导入“\(entry.name)”，点击卡片即可切换。"
            return id
        } catch {
            if let staging { try? fm.removeItem(at: staging) }
            notice = "导入失败：\(error.localizedDescription)"; return nil
        }
    }
    func stop() { activeStore?.stop() }
}
