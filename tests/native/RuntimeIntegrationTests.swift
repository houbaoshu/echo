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
