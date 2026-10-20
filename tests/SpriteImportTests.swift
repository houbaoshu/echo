import Testing
import AppKit
import AVFoundation
import Combine
import Foundation
import ImageIO
import SwiftUI

extension EchoVoiceScenarios {
/// Importing a pet folder from 设置 › 精灵.
@Suite(.serialized) struct SpriteImportTests {
    /// A scratch folder holding the catalog's roots and the folders a test imports from.
    struct Sandbox {
        let root: URL
        let imported: URL
        let sources: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("echo-sprite-import-\(UUID())")
            imported = root.appendingPathComponent("imported")
            sources = root.appendingPathComponent("sources")
            try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        }
        /// A folder built from a bundled asset: its sheet, and its manifest with `edit` applied.
        func folder(_ name: String, from asset: String, sheetPath: String? = nil,
                    edit: (inout [String: Any]) -> Void = { _ in }) throws -> URL {
            let fm = FileManager.default
            let source = EchoTestResources.resource(asset)
            let directory = sources.appendingPathComponent(name)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: source.appendingPathComponent("pet.json"))) as! [String: Any]
            if let sheetPath { manifest["spritesheetPath"] = sheetPath }
            edit(&manifest)
            try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent("pet.json"))
            let sheet = directory.appendingPathComponent(manifest["spritesheetPath"] as? String ?? "spritesheet.webp")
            try fm.createDirectory(at: sheet.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source.appendingPathComponent("spritesheet.webp"), to: sheet)
            return directory
        }
        /// Everything in the import root, hidden staging folders included.
        func installed() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: imported.path)) ?? []).sorted()
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    /// The pet import as it behaved before planets shared its checks; the planet import must not change it.
    @Test @MainActor static func petImportTests() throws {
        _ = NSApplication.shared
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let fm = FileManager.default
        let settings = SettingsStore(url: sandbox.root.appendingPathComponent("settings.json"), secrets: TestBootstrap.Secrets())
        let builtin = EchoTestResources.resource("pets")

        let rootless = PetCatalog(settings: settings, builtinRoot: builtin)
        #expect(rootless.importPet(from: try sandbox.folder("rootless", from: "pets/chiyan")) == nil
              && rootless.notice == "精灵导入目录不可用。", "without an import root nothing is imported")

        let pets = PetCatalog(settings: settings, builtinRoot: builtin, importedRoot: sandbox.imported)
        let builtinCount = pets.entries.count
        let source = try sandbox.folder("renamed", from: "pets/chiyan") { $0["displayName"] = "测试精灵" }
        let id = try #require(pets.importPet(from: source))
        let name = String(id.dropFirst("imported:".count))
        #expect(id.hasPrefix("imported:") && UUID(uuidString: name) != nil, "an import is named by a fresh UUID")
        #expect(pets.entries.count == builtinCount + 1 && pets.entries.last?.id == id
              && pets.entries.last?.builtin == false && pets.entries.last?.name == "测试精灵",
              "the imported pet joins the end of the list")
        #expect(pets.highlightedID == id && pets.selectedID == "builtin:chiyan", "an import is highlighted, not selected")
        #expect(pets.notice == "已导入“测试精灵”，点击卡片即可切换。", "an import says how to switch to it")
        #expect(sandbox.installed() == [name], "the import leaves one folder and no staging folder")
        #expect(fm.contentsEqual(atPath: source.appendingPathComponent("spritesheet.webp").path,
                               andPath: sandbox.imported.appendingPathComponent("\(name)/spritesheet.webp").path)
              && fm.contentsEqual(atPath: source.appendingPathComponent("pet.json").path,
                                  andPath: sandbox.imported.appendingPathComponent("\(name)/pet.json").path),
              "the import copies the manifest and sheet byte for byte")

        pets.notice = nil
        #expect(pets.importPet(from: source) == id && pets.highlightedID == id && pets.notice == "这只精灵已在列表中。"
              && sandbox.installed() == [name], "importing the same folder again highlights the existing pet")
        let copy = sandbox.sources.appendingPathComponent("copy")
        try fm.copyItem(at: EchoTestResources.resource("pets/cangcang"), to: copy)
        #expect(pets.importPet(from: copy) == "builtin:cangcang" && pets.highlightedID == "builtin:cangcang"
              && sandbox.installed() == [name], "a copy of a bundled pet is the bundled pet")

        let nested = try sandbox.folder("nested", from: "pets/cangcang", sheetPath: "art/sheet.webp") { $0["displayName"] = "嵌套" }
        let nestedID = try #require(pets.importPet(from: nested))
        #expect(fm.fileExists(atPath: sandbox.imported.appendingPathComponent("\(nestedID.dropFirst("imported:".count))/art/sheet.webp").path),
              "a sheet in a subfolder keeps its relative path")
        let installed = sandbox.installed()

        // Each refusal names the problem and leaves the import root as it was.
        func refuses(_ folder: URL, _ reason: String?, _ message: String, sourceLocation: SourceLocation = #_sourceLocation) {
            pets.notice = nil
            let result = pets.importPet(from: folder)
            let notice = pets.notice ?? ""
            // The notice has its own catalog key, 导入失败：%@|精灵; the key itself must never show.
            #expect(result == nil && notice.hasPrefix("导入失败：") && !notice.contains("|")
                  && (reason.map { notice == "导入失败：\($0)" } ?? true),
                  "\(message): \(notice)", sourceLocation: sourceLocation)
            #expect(sandbox.installed() == installed, "\(message) leaves nothing behind", sourceLocation: sourceLocation)
        }
        let empty = sandbox.sources.appendingPathComponent("empty")
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        refuses(empty, nil, "a folder without pet.json")
        refuses(try sandbox.folder("unnamed", from: "pets/chiyan") { $0["displayName"] = nil }, nil, "a manifest without a name")
        // Only version 2: neither another version nor the older format, which leaves the field out.
        let onlyVersion2 = "仅支持第 2 版精灵格式（pet.json 中的 spriteVersionNumber 须为 2）。"
        for version in [3, 1, nil] as [Int?] {
            refuses(try sandbox.folder("version-\(version ?? 0)", from: "pets/chiyan") { $0["spriteVersionNumber"] = version; $0["displayName"] = "版本" },
                    onlyVersion2, "spriteVersionNumber \(version.map(String.init) ?? "missing")")
        }
        let escaping = try sandbox.folder("escaping", from: "pets/chiyan") { $0["displayName"] = "越界" }
        try JSONSerialization.data(withJSONObject: ["displayName": "越界", "spritesheetPath": "../renamed/spritesheet.webp", "spriteVersionNumber": 2])
            .write(to: escaping.appendingPathComponent("pet.json"))
        refuses(escaping, "精灵图必须使用文件夹内的相对路径。", "a sheet path that climbs out")
        let png = try sandbox.folder("png", from: "pets/chiyan", sheetPath: "sheet.png") { $0["displayName"] = "PNG" }
        refuses(png, "精灵图必须是所选文件夹内的 WebP 文件。", "a sheet that is not WebP")
        let linkedSheet = try sandbox.folder("linked-sheet", from: "pets/chiyan") { $0["displayName"] = "链接图" }
        try fm.removeItem(at: linkedSheet.appendingPathComponent("spritesheet.webp"))
        try fm.createSymbolicLink(at: linkedSheet.appendingPathComponent("spritesheet.webp"),
                                  withDestinationURL: source.appendingPathComponent("spritesheet.webp"))
        refuses(linkedSheet, "精灵图必须是所选文件夹内的 WebP 文件。", "a sheet linked from outside the folder")
        let linkedManifest = try sandbox.folder("linked-manifest", from: "pets/chiyan") { $0["displayName"] = "链接清单" }
        try fm.removeItem(at: linkedManifest.appendingPathComponent("pet.json"))
        try fm.createSymbolicLink(at: linkedManifest.appendingPathComponent("pet.json"),
                                  withDestinationURL: nested.appendingPathComponent("pet.json"))
        refuses(linkedManifest, "pet.json 必须位于所选文件夹内。", "a manifest linked from outside the folder")
        let large = try sandbox.folder("large", from: "pets/chiyan") { $0["displayName"] = "大清单" }
        var padded = try Data(contentsOf: large.appendingPathComponent("pet.json"))
        padded.append(Data(repeating: UInt8(ascii: " "), count: 1_048_576))
        try padded.write(to: large.appendingPathComponent("pet.json"))
        refuses(large, "pet.json 文件过大。", "a manifest over 1 MB")
        let corrupt = try sandbox.folder("corrupt", from: "pets/chiyan") { $0["displayName"] = "损坏" }
        try Data("not a webp".utf8).write(to: corrupt.appendingPathComponent("spritesheet.webp"))
        refuses(corrupt, "精灵图损坏或尺寸过大（最多 1600 万像素）。", "a sheet that does not decode")

        // A later launch lists what was imported, under the same id, and can switch to it.
        let reopened = PetCatalog(settings: settings, builtinRoot: builtin, importedRoot: sandbox.imported)
        #expect(Set(reopened.entries.map(\.id)) == Set(pets.entries.map(\.id))
              && reopened.entries.prefix(builtinCount).allSatisfy(\.builtin) && reopened.notice == nil,
              "the next launch lists the imported pets after the bundled ones")
        #expect(reopened.activate(id) && settings.snapshot.selectedPetID == id, "an imported pet can be selected")
        reopened.stop()
    }

    /// Importing a planet folder from 设置 › 星球, and Live Voice finding what was imported.
    @Test @MainActor static func planetImportTests() async throws {
        _ = NSApplication.shared
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let fm = FileManager.default
        let settings = SettingsStore(url: sandbox.root.appendingPathComponent("settings.json"), secrets: TestBootstrap.Secrets())
        let builtin = EchoTestResources.resource("planets")
        let voice = VoiceSessionController()
        defer { voice.shutdown() }

        let rootless = PlanetStore(settings: settings, root: builtin, voice: voice)
        #expect(rootless.importPlanet(from: try sandbox.folder("rootless", from: "planets/ember-planet")) == nil
              && rootless.notice == "星球导入目录不可用。", "without an import root nothing is imported")

        let planets = PlanetStore(settings: settings, root: builtin, importedRoot: sandbox.imported, voice: voice)
        planets.loadEntries()
        #expect(planets.entries.map(\.id) == ["builtin:ember-planet", "builtin:quiet-planet"], "the bundled planets come first")
        let source = try sandbox.folder("renamed", from: "planets/ember-planet") { $0["displayName"] = "测试星球" }
        let id = try #require(planets.importPlanet(from: source))
        let name = String(id.dropFirst("imported:".count))
        #expect(id.hasPrefix("imported:") && UUID(uuidString: name) != nil, "an import is named by a fresh UUID")
        #expect(planets.entries.count == 3 && planets.entries.last?.id == id && planets.entries.last?.name == "测试星球",
              "the imported planet joins the end of the list")
        #expect(planets.highlightedID == id && planets.selectedID == SettingsSnapshot.defaultPlanetID
              && settings.snapshot.selectedPlanetID == SettingsSnapshot.defaultPlanetID, "an import is highlighted, not selected")
        #expect(planets.notice == "已导入“测试星球”，点击卡片即可切换。", "an import says how to switch to it")
        #expect(sandbox.installed() == [name], "the import leaves one folder and no staging folder")
        #expect(fm.contentsEqual(atPath: source.appendingPathComponent("spritesheet.webp").path,
                               andPath: sandbox.imported.appendingPathComponent("\(name)/spritesheet.webp").path),
              "the import copies the sheet byte for byte")

        planets.notice = nil
        #expect(planets.importPlanet(from: source) == id && planets.highlightedID == id && planets.notice == "这颗星球已在列表中。"
              && sandbox.installed() == [name], "importing the same folder again highlights the existing planet")
        let copy = sandbox.sources.appendingPathComponent("copy")
        try fm.copyItem(at: EchoTestResources.resource("planets/quiet-planet"), to: copy)
        #expect(planets.importPlanet(from: copy) == "builtin:quiet-planet" && planets.highlightedID == "builtin:quiet-planet"
              && sandbox.installed() == [name], "a copy of a bundled planet is the bundled planet")
        // Planets and pets share the format, so a pet folder is a valid planet.
        let pet = try #require(planets.importPlanet(from: try sandbox.folder("pet", from: "pets/chiyan") { $0["displayName"] = "精灵星球" }))
        #expect(pet.hasPrefix("imported:") && planets.entries.last?.name == "精灵星球", "a pet folder imports as a planet")
        let installed = sandbox.installed()

        func refuses(_ folder: URL, _ message: String, reason: String? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
            planets.notice = nil
            let count = planets.entries.count
            let result = planets.importPlanet(from: folder)
            #expect(result == nil && planets.notice?.hasPrefix("导入失败：") == true && planets.notice?.contains("|") == false
                  && reason.map { planets.notice == "导入失败：\($0)" } ?? true && planets.entries.count == count,
                  "\(message): \(planets.notice ?? "")", sourceLocation: sourceLocation)
            #expect(sandbox.installed() == installed, "\(message) leaves nothing behind", sourceLocation: sourceLocation)
        }
        let empty = sandbox.sources.appendingPathComponent("empty")
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        refuses(empty, "a folder without pet.json")
        let corrupt = try sandbox.folder("corrupt", from: "planets/ember-planet") { $0["displayName"] = "损坏" }
        try Data("not a webp".utf8).write(to: corrupt.appendingPathComponent("spritesheet.webp"))
        refuses(corrupt, "a sheet that does not decode")
        for version in [3, 1, nil] as [Int?] {
            refuses(try sandbox.folder("version-\(version ?? 0)", from: "planets/ember-planet") { $0["spriteVersionNumber"] = version; $0["displayName"] = "版本" },
                    "spriteVersionNumber \(version.map(String.init) ?? "missing")",
                    reason: "仅支持第 2 版精灵格式（pet.json 中的 spriteVersionNumber 须为 2）。")
        }
        refuses(try sandbox.folder("grid", from: "planets/ember-planet") {
            $0["displayName"] = "网格"; $0["frame"] = ["width": 100, "height": 100, "columns": 8, "rows": 11]
        }, "a sheet whose size does not match its grid")
        let escaping = try sandbox.folder("escaping", from: "planets/ember-planet") { $0["displayName"] = "越界" }
        try JSONSerialization.data(withJSONObject: ["displayName": "越界", "spritesheetPath": "../renamed/spritesheet.webp", "spriteVersionNumber": 2])
            .write(to: escaping.appendingPathComponent("pet.json"))
        refuses(escaping, "a sheet path that climbs out")

        // A later launch lists the imports, and Live Voice resolves the saved imported id.
        let owner = VoiceSessionSnapshot.Owner(sessionID: UUID(), conversationID: UUID())
        let reopened = PlanetStore(settings: settings, root: builtin, importedRoot: sandbox.imported, voice: voice)
        reopened.loadEntries()
        #expect(Set(reopened.entries.map(\.id)) == Set(planets.entries.map(\.id))
              && reopened.entries.prefix(2).allSatisfy { $0.id.hasPrefix("builtin:") } && reopened.notice == nil,
              "the next launch lists the imported planets after the bundled ones")
        reopened.select(id)
        #expect(reopened.selectedID == id && settings.snapshot.selectedPlanetID == id && reopened.notice == nil,
              "an imported planet can be selected")
        voice.updateSnapshot { $0.session = .active(owner); $0.replyAudio = .playing(UUID()) }
        #expect(reopened.active?.displayName == "测试星球" && reopened.playing == "spinning",
              "Live Voice loads and plays the imported planet")
        reopened.select(pet)
        #expect(reopened.active?.displayName == "精灵星球" && reopened.playing == "spinning",
              "switching to another import during a call swaps the sprite")
        reopened.select(id)
        voice.updateSnapshot { $0 = VoiceSessionSnapshot() }
        #expect(reopened.active == nil, "ending the call unloads the planet")

        // Saved ids are untrusted: an imported id may only name a direct child of the import root.
        // Each prefix resolves only inside its own folder: a bundled planet's name is not an import, and the reverse.
        for bad in ["imported:", "imported:.hidden", "imported:../imported/\(name)", "imported:\(name)/..", "builtin:\(name)",
                    "imported:ember-planet", "imported:quiet-planet"] {
            reopened.notice = nil
            reopened.select(bad)
            #expect(reopened.selectedID == id && reopened.notice == "所选星球不存在，请重新选择。", "\(bad) is refused")
        }

        // The selected import's folder is deleted between launches: the next call falls back to a bundled planet.
        try fm.removeItem(at: sandbox.imported.appendingPathComponent(name))
        let relaunched = PlanetStore(settings: settings, root: builtin, importedRoot: sandbox.imported, voice: voice)
        #expect(relaunched.selectedID == id && relaunched.notice == nil, "launching alone does not look for the folder")
        voice.updateSnapshot { $0.session = .active(owner); $0.recognition = .listening }
        #expect(relaunched.selectedID == SettingsSnapshot.defaultPlanetID && relaunched.active?.displayName == "烬星"
              && settings.snapshot.selectedPlanetID == SettingsSnapshot.defaultPlanetID
              && relaunched.notice == "上次选择的星球无法加载，已换成另一颗。",
              "a missing imported planet falls back to a bundled one and says so")
        voice.updateSnapshot { $0 = VoiceSessionSnapshot() }
    }

    /// A Trash that is a folder in the sandbox, and one that refuses.
    static func trash(_ folder: URL) -> AgentTrash {
        AgentTrash { url in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: folder.appendingPathComponent(url.lastPathComponent))
        }
    }
    static let refusingTrash = AgentTrash { _ in throw CocoaError(.fileWriteNoPermission) }

    /// 移到废纸篓 on an imported pet's card, and the list finding it again once it is put back.
    @Test @MainActor static func petMoveToTrashTests() throws {
        _ = NSApplication.shared
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let fm = FileManager.default
        let settings = SettingsStore(url: sandbox.root.appendingPathComponent("settings.json"), secrets: TestBootstrap.Secrets())
        let builtin = EchoTestResources.resource("pets")
        let trashed = sandbox.root.appendingPathComponent("trash")
        let pets = PetCatalog(settings: settings, builtinRoot: builtin, importedRoot: sandbox.imported, trash: trash(trashed))
        _ = try pets.loadInitial()
        defer { pets.stop() }
        let kept = try #require(pets.importPet(from: try sandbox.folder("kept", from: "pets/chiyan") { $0["displayName"] = "保留" }))
        let other = try #require(pets.importPet(from: try sandbox.folder("other", from: "pets/cangcang") { $0["displayName"] = "其他" }))
        let keptName = String(kept.dropFirst("imported:".count)), otherName = String(other.dropFirst("imported:".count))

        // Not in use: only its folder goes, under its own name.
        #expect(pets.highlightedID == other && pets.moveToTrash(other), "an imported pet not in use is moved")
        #expect(!pets.entries.contains { $0.id == other } && pets.highlightedID == nil && pets.selectedID == PetCatalog.defaultID
              && sandbox.installed() == [keptName] && fm.fileExists(atPath: trashed.appendingPathComponent("\(otherName)/pet.json").path),
              "the card and the highlight go, and the folder lands in the Trash under its UUID")

        // In use: 赤焰 takes over on the desktop first.
        #expect(pets.activate(kept) && settings.snapshot.selectedPetID == kept)
        var shown: PetStore?
        pets.onActivate = { shown = $0 }
        #expect(pets.moveToTrash(kept), "the pet in use is moved")
        #expect(pets.selectedID == PetCatalog.defaultID && settings.snapshot.selectedPetID == PetCatalog.defaultID
              && shown === pets.activeStore && pets.activeStore?.displayName == "赤焰" && pets.notice == nil,
              "the desktop switches to 赤焰 and the choice is saved")
        #expect(sandbox.installed().isEmpty && !pets.entries.contains { $0.id == kept }, "its folder and card are gone")

        // Bundled pets have no menu, and the call refuses them as well.
        let count = pets.entries.count
        #expect(!pets.moveToTrash("builtin:cangcang") && !pets.moveToTrash(PetCatalog.defaultID) && pets.entries.count == count
              && fm.fileExists(atPath: builtin.appendingPathComponent("cangcang/pet.json").path), "a bundled pet cannot be moved")

        // Put back from the Trash: the next listing finds it under the same id, and a listed pet is not read again.
        try fm.moveItem(at: trashed.appendingPathComponent(keptName), to: sandbox.imported.appendingPathComponent(keptName))
        let otherFolder = trashed.appendingPathComponent(otherName)
        try fm.moveItem(at: otherFolder, to: sandbox.imported.appendingPathComponent(otherName))
        pets.reload()
        #expect(pets.entries.suffix(2).map(\.id) == [kept, other].sorted() && pets.entries.first(where: { $0.id == kept })?.name == "保留"
              && pets.selectedID == PetCatalog.defaultID && pets.activeStore?.displayName == "赤焰",
              "put-back pets are listed again; the pet in use stays")
        try Data("not a webp".utf8).write(to: sandbox.imported.appendingPathComponent("\(keptName)/spritesheet.webp"))
        pets.notice = nil
        pets.reload()
        #expect(pets.entries.contains { $0.id == kept } && pets.notice == nil, "a pet already listed is not read again")

        // The Trash refuses: nothing changes but the notice.
        let refused = PetCatalog(settings: settings, builtinRoot: builtin, importedRoot: sandbox.imported, trash: refusingTrash)
        #expect(!refused.moveToTrash(other) && refused.entries.contains { $0.id == other }
              && sandbox.installed().contains(otherName), "a refused move keeps the card and folder")
        let notice = refused.notice ?? ""
        #expect(notice.hasPrefix("无法移到废纸篓：") && notice.count > "无法移到废纸篓：".count, "and says why: \(notice)")

        // 赤焰 cannot be loaded: the pet in use is not moved.
        let bundled = sandbox.root.appendingPathComponent("bundled")
        try fm.createDirectory(at: bundled, withIntermediateDirectories: true)
        try fm.copyItem(at: builtin.appendingPathComponent("cangcang"), to: bundled.appendingPathComponent("cangcang"))
        let stranded = PetCatalog(settings: settings, builtinRoot: bundled, importedRoot: sandbox.imported, trash: trash(trashed))
        #expect(stranded.activate(other))
        defer { stranded.stop() }
        #expect(!stranded.moveToTrash(other) && stranded.selectedID == other && stranded.entries.contains { $0.id == other }
              && sandbox.installed().contains(otherName) && stranded.notice == "无法先换回赤焰，未移到废纸篓。",
              "a pet in use that cannot give way stays")
    }

    /// 移到废纸篓 on an imported planet's card, during a call too.
    @Test @MainActor static func planetMoveToTrashTests() throws {
        _ = NSApplication.shared
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let fm = FileManager.default
        let settings = SettingsStore(url: sandbox.root.appendingPathComponent("settings.json"), secrets: TestBootstrap.Secrets())
        let builtin = EchoTestResources.resource("planets")
        let voice = VoiceSessionController()
        defer { voice.shutdown() }
        let trashed = sandbox.root.appendingPathComponent("trash")
        let planets = PlanetStore(settings: settings, root: builtin, importedRoot: sandbox.imported, voice: voice, trash: trash(trashed))
        planets.loadEntries()
        let kept = try #require(planets.importPlanet(from: try sandbox.folder("kept", from: "planets/ember-planet") { $0["displayName"] = "保留" }))
        let other = try #require(planets.importPlanet(from: try sandbox.folder("other", from: "planets/quiet-planet") { $0["displayName"] = "其他" }))
        let keptName = String(kept.dropFirst("imported:".count)), otherName = String(other.dropFirst("imported:".count))

        #expect(planets.highlightedID == other && planets.moveToTrash(other), "an imported planet not in use is moved")
        #expect(!planets.entries.contains { $0.id == other } && planets.highlightedID == nil
              && planets.selectedID == SettingsSnapshot.defaultPlanetID && sandbox.installed() == [keptName]
              && fm.fileExists(atPath: trashed.appendingPathComponent("\(otherName)/pet.json").path),
              "the card and the highlight go, and the folder lands in the Trash under its UUID")

        // In use during a call: the default planet is swapped in at once.
        planets.select(kept)
        let owner = VoiceSessionSnapshot.Owner(sessionID: UUID(), conversationID: UUID())
        voice.updateSnapshot { $0.session = .active(owner); $0.replyAudio = .playing(UUID()) }
        #expect(planets.active?.displayName == "保留" && planets.playing == "spinning")
        #expect(planets.moveToTrash(kept), "the planet in use is moved")
        #expect(planets.selectedID == SettingsSnapshot.defaultPlanetID && settings.snapshot.selectedPlanetID == SettingsSnapshot.defaultPlanetID
              && planets.active?.displayName == "烬星" && planets.playing == "spinning" && planets.notice == nil,
              "the call switches to the default planet and keeps its state")
        #expect(sandbox.installed().isEmpty && !planets.entries.contains { $0.id == kept }, "its folder and card are gone")
        voice.updateSnapshot { $0 = VoiceSessionSnapshot() }

        let count = planets.entries.count
        #expect(!planets.moveToTrash("builtin:quiet-planet") && !planets.moveToTrash(SettingsSnapshot.defaultPlanetID)
              && planets.entries.count == count && fm.fileExists(atPath: builtin.appendingPathComponent("quiet-planet/pet.json").path),
              "a bundled planet cannot be moved")

        // Put back: opening the page again lists it, and a listed planet is not decoded again.
        try fm.moveItem(at: trashed.appendingPathComponent(keptName), to: sandbox.imported.appendingPathComponent(keptName))
        try fm.moveItem(at: trashed.appendingPathComponent(otherName), to: sandbox.imported.appendingPathComponent(otherName))
        planets.loadEntries()
        #expect(planets.entries.suffix(2).map(\.id) == [kept, other].sorted() && planets.entries.first(where: { $0.id == kept })?.name == "保留"
              && planets.selectedID == SettingsSnapshot.defaultPlanetID, "put-back planets are listed again")
        try Data("not a webp".utf8).write(to: sandbox.imported.appendingPathComponent("\(keptName)/spritesheet.webp"))
        planets.notice = nil
        planets.loadEntries()
        #expect(planets.entries.contains { $0.id == kept } && planets.notice == nil, "a planet already listed is not decoded again")

        let refused = PlanetStore(settings: settings, root: builtin, importedRoot: sandbox.imported, voice: voice, trash: refusingTrash)
        refused.loadEntries()
        #expect(!refused.moveToTrash(other) && refused.entries.contains { $0.id == other }
              && sandbox.installed().contains(otherName), "a refused move keeps the card and folder")
        let notice = refused.notice ?? ""
        #expect(notice.hasPrefix("无法移到废纸篓：") && notice.count > "无法移到废纸篓：".count, "and says why: \(notice)")

        // The default planet is missing: the planet in use is not moved.
        let bundled = sandbox.root.appendingPathComponent("bundled")
        try fm.createDirectory(at: bundled, withIntermediateDirectories: true)
        try fm.copyItem(at: builtin.appendingPathComponent("quiet-planet"), to: bundled.appendingPathComponent("quiet-planet"))
        let stranded = PlanetStore(settings: settings, root: bundled, importedRoot: sandbox.imported, voice: voice, trash: trash(trashed))
        stranded.select(other)
        #expect(!stranded.moveToTrash(other) && stranded.selectedID == other && sandbox.installed().contains(otherName)
              && stranded.notice == "无法先换回默认星球，未移到废纸篓。", "a planet in use that cannot give way stays")
    }
}
}
