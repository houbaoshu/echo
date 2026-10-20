import Foundation
import Testing

@Suite(.serialized) enum EchoIntegrationScenarios {}

/// Harnesses for the loopback model server. Each turn resolves the protocol, as settings are
/// read at each turn.
@MainActor enum AgentFixture {
    static func harness(baseURL: String, protocol current: @escaping @MainActor () -> ModelAPIProtocol) -> AgentHarness {
        AgentHarness(resolveModel: {
            let endpoint = AgentEndpoint(baseURL: baseURL, model: "fixture", apiKey: nil, apiProtocol: current())
            let transport = AgentTransport.make(for: endpoint)
            return { ledger, budget in EchoLanguageModel(endpoint: endpoint, transport: transport, ledger: ledger, budget: budget) }
        }, finder: NoFinder())
    }
    static func harness(server: LoopbackModelServer, protocol apiProtocol: ModelAPIProtocol) -> AgentHarness {
        harness(baseURL: server.baseURL) { apiProtocol }
    }
}

@MainActor final class SessionFixture {
    let root: URL
    let server: LoopbackModelServer
    let persistence: WorkspacePersistence
    var protocolName = ModelAPIProtocol.chatCompletions
    lazy var workspace = WorkspaceStore(persistence: persistence, harnessFactory: { [unowned self] in self.harness() })
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("echo-session-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        persistence = WorkspacePersistence(url: root.appendingPathComponent("workspace.json"))
        do { server = try LoopbackModelServer() }
        catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    func harness() -> AgentHarness { AgentFixture.harness(baseURL: server.baseURL) { [unowned self] in self.protocolName } }
    func close() async throws {
        workspace.shutdown()
        defer { try? FileManager.default.removeItem(at: root) }
        try server.stop()
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
