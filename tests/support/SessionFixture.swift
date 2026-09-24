import Foundation
import Testing
import EchoAgentBridge

@Suite(.serialized) enum EchoIntegrationScenarios {}

@MainActor func waitForAgentShutdown() async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
    while echo_agent_active_sessions() != 0 {
        try #require(ContinuousClock.now < deadline, "Rust session cleanup did not finish before the deadline")
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor final class SessionFixture {
    let root: URL
    let server: LoopbackModelServer
    let persistence: WorkspacePersistence
    var protocolName = AgentModel.ProtocolName.chat_completions
    lazy var workspace = WorkspaceStore(persistence: persistence, sourceFactory: { [unowned self] in self.source() })
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("echo-session-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        persistence = WorkspacePersistence(url: root.appendingPathComponent("workspace.json"))
        do { server = try LoopbackModelServer() }
        catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    func source() -> AgentTaskSource {
        AgentTaskSource(model: AgentModel(base_url: server.baseURL, model: "fixture", protocol: protocolName), resources: EchoTestResources.root)
    }
    func close() async throws {
        workspace.shutdown()
        defer { try? FileManager.default.removeItem(at: root) }
        var serverError: (any Error)?
        do { try server.stop() } catch { serverError = error }
        try await waitForAgentShutdown()
        if let serverError { throw serverError }
    }
}

@MainActor func withSession(_ body: (SessionFixture) async throws -> Void) async throws {
    let fixture = try SessionFixture()
    do { try await body(fixture) }
    catch {
        do { try await fixture.close() } catch { Issue.record(error) }
        throw error
    }
    try await fixture.close()
}
