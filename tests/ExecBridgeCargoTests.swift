// Retires with exec-bridge: when the exec-bridge package is removed (for example together
// with the mini-agent-rs bridge), delete this file. Nothing else depends on it.
import Testing

/// echo-exec's Rust integration tests (exec-bridge/tests), run by cargo test. They start real
/// zsh processes and check timeouts, killing the whole tree on cancel and leaving nothing behind.
@Suite struct ExecBridgeCargoTests {
    @Test static func rustTestsPass() async throws {
        try await CargoTestRun.run(package: "echo-exec")
    }
}
