import Testing

/// echo-runtime's own Rust tests (pet and planet assets, animation state), run by cargo test.
@Suite struct RuntimeCargoTests {
    @Test static func rustTestsPass() async throws {
        try await CargoTestRun.run(package: "echo-runtime")
    }
}
