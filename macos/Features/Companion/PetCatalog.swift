import AppKit

struct PetEntry: Identifiable {
    let id: String
    let directory: URL
    let name: String
    let description: String
    let preview: CGImage
    let fingerprint: String
    let builtin: Bool
}

@MainActor @Observable final class PetCatalog {
    private(set) var entries: [PetEntry] = []
    var notice: String?
    private(set) var selectedID = PetCatalog.defaultID
    private(set) var highlightedID: String?
    @ObservationIgnored private(set) var activeStore: PetStore?
    @ObservationIgnored var onActivate: ((PetStore) -> Void)?
    @ObservationIgnored var onFailure: ((Error) -> Void)?
    private let settings: SettingsStore
    private let builtinRoot: URL?
    private let importedRoot: URL?
    private let trash: AgentTrash
    /// The pet a deleted pet in use gives way to, as on a first launch.
    static let defaultID = "builtin:chiyan"
    init(settings: SettingsStore, builtinRoot: URL? = nil, importedRoot: URL? = nil, trash: AgentTrash = .system) {
        self.settings = settings; self.builtinRoot = builtinRoot; self.importedRoot = importedRoot; self.trash = trash
        selectedID = settings.snapshot.selectedPetID
        reload()
    }
    /// List the bundled pets, then the imported ones, so a folder put back from the Trash shows up
    /// without a relaunch. A pet already listed is kept as it is rather than read again, so opening
    /// the page never re-reads its sheet; the pet in use is never touched.
    func reload() {
        var loaded: [PetEntry] = []
        for (root, builtin) in [(builtinRoot, true), (importedRoot, false)] {
            guard let root else { continue }
            let directories = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for directory in directories.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where !directory.lastPathComponent.hasPrefix(".") {
                let id = "\(builtin ? "builtin" : "imported"):\(directory.lastPathComponent)"
                if let listed = entries.first(where: { $0.id == id }) { loaded.append(listed); continue }
                do {
                    loaded.append(try read(directory, id: id, builtin: builtin))
                } catch { notice = String(localized: "部分精灵素材无法加载，已跳过。可重新导入有效的精灵文件夹。") }
            }
        }
        entries = loaded
    }
    private func read(_ directory: URL, id: String, builtin: Bool) throws -> PetEntry {
        let contents = try SpriteFolder.read(directory)
        let store = try PetStore(directory: directory)
        defer { store.stop() }
        return PetEntry(id: id, directory: directory, name: store.displayName, description: contents.description ?? "",
                        preview: store.image, fingerprint: contents.fingerprint, builtin: builtin)
    }
    func loadInitial() throws -> PetStore {
        if let selected = entries.first(where: { $0.id == selectedID }), let store = try? PetStore(directory: selected.directory) {
            activeStore = store; store.onFailure = onFailure; return store
        }
        guard let fallback = entries.first(where: { $0.id == Self.defaultID }) else { throw SettingsError(localized: "应用内缺少有效的赤焰精灵素材。") }
        let store = try PetStore(directory: fallback.directory)
        activeStore = store; store.onFailure = onFailure; selectedID = fallback.id
        notice = String(localized: "上次选择的精灵无法加载，已恢复为赤焰。")
        do { try settings.selectPet(fallback.id) } catch { notice = String(localized: "已恢复为赤焰，但无法保存选择。") }
        return store
    }
    @discardableResult func activate(_ id: String) -> Bool {
        guard id != selectedID || activeStore == nil else { return true }
        guard let entry = entries.first(where: { $0.id == id }) else { notice = String(localized: "所选精灵不存在，请重新导入。"); return false }
        do {
            _ = try SpriteFolder.read(entry.directory)
            let next = try PetStore(directory: entry.directory)
            do { try settings.selectPet(id) } catch { next.stop(); throw error }
            let previous = activeStore
            next.onFailure = onFailure; activeStore = next; selectedID = id
            onActivate?(next)
            previous?.stop(); next.start(); notice = nil
            return true
        } catch { notice = String(localized: "切换失败，保留当前精灵：\(error.localizedDescription)"); return false }
    }
    @discardableResult func importPet(from directory: URL) -> String? {
        guard let importedRoot else { notice = String(localized: "精灵导入目录不可用。"); return nil }
        do {
            let candidate = try read(directory, id: "candidate", builtin: false)
            if let existing = entries.first(where: { $0.fingerprint == candidate.fingerprint }) {
                highlightedID = existing.id; notice = String(localized: "这只精灵已在列表中。"); return existing.id
            }
            let entry = try SpriteFolder.install(directory, into: importedRoot) { folder, name in
                try read(folder, id: name.map { "imported:\($0)" } ?? "staging", builtin: false)
            }
            entries.append(entry); highlightedID = entry.id
            notice = String(localized: "已导入“\(entry.name)”，点击卡片即可切换。")
            return entry.id
        } catch {
            notice = String(localized: "导入失败：%@|精灵", defaultValue: "导入失败：\(error.localizedDescription)"); return nil
        }
    }
    /// Move an imported pet's folder to the Trash, under its own name so Put Back restores it. The
    /// pet in use first gives way to 赤焰, so the desktop never shows a pet whose folder is gone.
    @discardableResult func moveToTrash(_ id: String) -> Bool {
        guard let entry = entries.first(where: { $0.id == id }), !entry.builtin, id.hasPrefix("imported:") else { return false }
        if id == selectedID, !activate(Self.defaultID) {
            notice = String(localized: "无法先换回赤焰，未移到废纸篓。"); return false
        }
        do {
            guard let importedRoot, let directory = SpriteFolder.child(named: String(id.dropFirst("imported:".count)), of: importedRoot)
            else { throw CocoaError(.fileNoSuchFile) }
            try trash.move(directory)
        } catch {
            notice = String(localized: "无法移到废纸篓：\(error.localizedDescription)"); return false
        }
        entries.removeAll { $0.id == id }
        if highlightedID == id { highlightedID = nil }
        notice = nil
        return true
    }
    func stop() { activeStore?.stop() }
}
