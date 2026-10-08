import Foundation
import Testing

@Suite(.serialized) enum EchoIntegrationScenarios {}

/// Waits until every command the execution core started has finished its cleanup.
@MainActor func waitForAgentShutdown() async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
    while ExecutionService.activeCommands != 0 {
        try #require(ContinuousClock.now < deadline, "Command cleanup did not finish before the deadline")
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// Agent sources for the loopback model server. Each turn resolves the protocol, as settings are
/// read at each turn.
@MainActor enum AgentFixture {
    static func source(baseURL: String, protocol current: @escaping @MainActor () -> ModelAPIProtocol) -> AgentHarness {
        AgentHarness(resolveModel: {
            let endpoint = AgentEndpoint(baseURL: baseURL, model: "fixture", apiKey: nil, apiProtocol: current())
            let transport = AgentTransport.make(for: endpoint)
            return { ledger, budget in EchoLanguageModel(endpoint: endpoint, transport: transport, ledger: ledger, budget: budget) }
        })
    }
    static func source(server: LoopbackModelServer, protocol apiProtocol: ModelAPIProtocol) -> AgentHarness {
        source(baseURL: server.baseURL) { apiProtocol }
    }
}

@MainActor final class SessionFixture {
    let root: URL
    let server: LoopbackModelServer
    let persistence: WorkspacePersistence
    var protocolName = ModelAPIProtocol.chatCompletions
    lazy var workspace = WorkspaceStore(persistence: persistence, sourceFactory: { [unowned self] in self.source() })
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("echo-session-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        persistence = WorkspacePersistence(url: root.appendingPathComponent("workspace.json"))
        do { server = try LoopbackModelServer() }
        catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    func source() -> AgentHarness { AgentFixture.source(baseURL: server.baseURL) { [unowned self] in self.protocolName } }
    /// A source that reads the model configuration from saved settings.
    func settingsSource(_ settings: SettingsStore) -> AgentHarness { AgentHarness(settings: settings) }
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
