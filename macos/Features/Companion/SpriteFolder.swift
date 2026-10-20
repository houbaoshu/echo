import CryptoKit
import Foundation
import ImageIO

/// A sprite folder: a `pet.json` manifest and the WebP sheet it names. Pets and planets share the
/// format, so they share the checks an imported folder has to pass and the way it lands on disk.
enum SpriteFolder {
    struct Contents {
        let manifest: Data
        let sheet: Data
        /// Where the sheet sits inside the folder, as the manifest names it.
        let sheetPath: String
        let description: String?
        /// The folder's bytes, so the same sprite is never imported twice.
        var fingerprint: String {
            var hash = SHA256(); hash.update(data: manifest); hash.update(data: Data([0])); hash.update(data: sheet)
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }
    private struct Manifest: Decodable {
        let displayName: String
        let description: String?
        let spritesheetPath: String?
        let spriteVersionNumber: Int?
    }

    /// Read a folder the user chose. Both files must stay inside it, within the size limits.
    static func read(_ directory: URL) throws -> Contents {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let manifestURL = root.appendingPathComponent("pet.json").resolvingSymlinksInPath()
        guard manifestURL.path.hasPrefix(root.path + "/") else { throw SettingsError(localized: "pet.json 必须位于所选文件夹内。") }
        let manifestSize = try manifestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard manifestSize <= manifestSizeLimit else { throw SettingsError(localized: "pet.json 文件过大。") }
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        // The 8 × 11 sheet with look directions. Older pets leave the field out and have 9 rows.
        guard manifest.spriteVersionNumber == supportedVersion else {
            throw SettingsError(localized: "仅支持第 2 版精灵格式（pet.json 中的 spriteVersionNumber 须为 2）。")
        }
        guard let relative = sheetPath(manifest.spritesheetPath) else {
            throw SettingsError(localized: "精灵图必须使用文件夹内的相对路径。")
        }
        let sheetURL = root.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
        guard sheetURL.path.hasPrefix(root.path + "/"), sheetURL.pathExtension.lowercased() == "webp" else {
            throw SettingsError(localized: "精灵图必须是所选文件夹内的 WebP 文件。")
        }
        let size = try sheetURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 33_554_432 else { throw SettingsError(localized: "精灵图文件不能超过 32 MB。") }
        let sheet = try Data(contentsOf: sheetURL)
        guard let source = CGImageSourceCreateWithData(sheet as CFData, nil), pixelSize(of: source) != nil else {
            throw SettingsError(localized: "精灵图损坏或尺寸过大（最多 1600 万像素）。")
        }
        return Contents(manifest: data, sheet: sheet, sheetPath: relative, description: manifest.description)
    }

    /// The largest `pet.json` read.
    static let manifestSizeLimit = 1_048_576
    /// The one sprite format read; see `read`.
    static let supportedVersion = 2

    /// The sheet's path as a manifest declares it, or nil unless it is relative and stays inside the folder.
    static func sheetPath(_ declared: String?) -> String? {
        let relative = declared ?? "spritesheet.webp"
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { return nil }
        return relative
    }

    /// A sheet's size in pixels, or nil when it cannot be read or is too large to load.
    static func pixelSize(of source: CGImageSource) -> (width: Int, height: Int)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 16_777_216 else { return nil }
        return (width, height)
    }

    /// A manifest's display name without the whitespace around it, or nil when that leaves nothing.
    static func displayName(_ declared: String?) -> String? {
        guard let name = declared?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return name
    }

    /// The sprite folders in `root`, by name. Hidden ones, such as an import being staged, are left out.
    static func folders(in root: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return contents.filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The folder a `builtin:` or `imported:` id names, which may only be a direct child of its own root.
    static func directory(for id: String, builtinRoot: URL?, importedRoot: URL?) -> URL? {
        let roots = [("builtin:", builtinRoot), ("imported:", importedRoot)]
        guard let (prefix, root) = roots.first(where: { id.hasPrefix($0.0) }), let root else { return nil }
        return child(named: String(id.dropFirst(prefix.count)), of: root)
    }

    /// The folder an id's name points at, which may only be a direct child of `root`. Ids come from
    /// `settings.json` and from the settings grid, so the name is untrusted.
    static func child(named name: String, of root: URL) -> URL? {
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/") else { return nil }
        let directory = root.appendingPathComponent(name, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return directory
    }

    /// Copy a folder into `root` under a fresh UUID name. The copy is staged in a hidden folder and
    /// only moved into place once `entry` accepts it, so a source that changed after its checks
    /// cannot install a broken sprite. `entry` reads a folder the way the caller lists it: first the
    /// staged copy (name nil), then the installed folder with its name, whose entry is returned.
    /// Nothing is left behind when any step fails.
    static func install<Entry>(_ directory: URL, into root: URL, entry: (URL, _ name: String?) throws -> Entry) throws -> Entry {
        let fm = FileManager.default
        let contents = try read(directory)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var staging = root.appendingPathComponent(".import-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            try contents.manifest.write(to: staging.appendingPathComponent("pet.json"))
            let sheetDestination = staging.appendingPathComponent(contents.sheetPath)
            try fm.createDirectory(at: sheetDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.sheet.write(to: sheetDestination)
            _ = try entry(staging, nil)
            let name = UUID().uuidString
            let destination = root.appendingPathComponent(name)
            try fm.moveItem(at: staging, to: destination)
            staging = destination
            return try entry(destination, name)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }
}
