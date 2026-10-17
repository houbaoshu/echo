import AppKit
import EchoRuntime
import Testing

extension EchoIntegrationScenarios {
  @Suite(.serialized) @MainActor struct RuntimeIntegrationTests {
    @Test static func invalidResourceReportsAnError() throws {
      let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      #expect(throws: PetError.self) { try RuntimeHandle(directory: missing) }
      #expect(throws: PetError.self) { try PetStore(directory: missing) }
    }

    /// The runtime reads only version 2 manifests, whatever the import checked.
    @Test static func onlyVersion2ManifestsLoad() throws {
      let fm = FileManager.default
      let source = EchoTestResources.resource("pets/chiyan")
      let root = fm.temporaryDirectory.appendingPathComponent("echo-sprite-version-\(UUID())")
      defer { try? fm.removeItem(at: root) }
      var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: source.appendingPathComponent("pet.json"))) as! [String: Any]
      for version in [2, 1, 3, nil] as [Int?] {
        let directory = root.appendingPathComponent("\(version ?? 0)")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try fm.copyItem(at: source.appendingPathComponent("spritesheet.webp"), to: directory.appendingPathComponent("spritesheet.webp"))
        manifest["spriteVersionNumber"] = version
        try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent("pet.json"))
        if version == 2 { _ = try RuntimeHandle(directory: directory) }
        else { #expect(throws: PetError.self, "spriteVersionNumber \(String(describing: version))") { try RuntimeHandle(directory: directory) } }
      }
    }

    @Test static func framesRemainUsableAfterRuntimeDestruction() throws {
      let store = try PetStore(directory: EchoTestResources.resource("pets/chiyan"))
      defer { store.stop() }
      #expect(store.displayName == "赤焰")
      #expect(store.size.width == 112 && store.size.height > 0)
      let retained = store.image
      let before = try #require(retained.dataProvider?.data) as Data
      #expect(before.count == retained.width * retained.height * 4)
      #expect(before.contains { $0 != 0 })
      store.stop()  // Releases the actual EchoRuntime, retaining only copied CGImages.
      let after = try #require(retained.dataProvider?.data) as Data
      #expect(before == after)
      #expect(store.image === retained)
    }

    /// A click's wave goes through the runtime's one-shot, which shows over looking at the
    /// pointer and over hovering. The runtime's own tests cover the timing.
    @Test static func waveShowsOverLookingAndHovering() throws {
      let store = try PetStore(directory: EchoTestResources.resource("pets/chiyan"))
      defer { store.stop() }
      store.look(at: NSPoint(x: 300, y: 0))
      #expect(store.spriteIndex == 76, "A moving pointer to the right turns the pet that way")
      store.wave()
      #expect((24...27).contains(store.spriteIndex), "The wave shows over the look, sprite \(store.spriteIndex)")
      store.interact(hovered: true, direction: 0)
      #expect((24...27).contains(store.spriteIndex), "Hovering does not cut the wave, sprite \(store.spriteIndex)")
    }

    @Test static func runtimeFailureStopsTheStoreAndReportsOnce() throws {
      let store = try PetStore(directory: EchoTestResources.resource("pets/chiyan"))
      defer { store.stop() }
      var failures: [String] = []
      store.onFailure = { failures.append($0.localizedDescription) }
      store.play("missing-animation")
      #expect(failures.count == 1)
      #expect(failures.first?.contains("missing-animation") == true)
      store.wave()
      #expect(failures.count == 1, "The failed runtime is no longer called")
    }
  }
}
