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

/// The Agent engine a scenario runs against. Scenarios observe only `TaskStore`,
/// `WorkspaceStore` and files on disk, so each engine supplies its own sources.
/// The native engine talks to the same loopback server through Echo's own adapters.
@MainActor struct AgentEngine: CustomStringConvertible {
    let description: String
    /// A source for the loopback model server, speaking the fixture's current protocol.
    let fixtureSource: (SessionFixture) -> any TaskSource
    /// A source that reads the model configuration from saved settings.
    let settingsSource: (SettingsStore) -> any TaskSource

    static let rust = AgentEngine(
        description: "rust",
        fixtureSource: { fixture in
            AgentTaskSource(model: AgentModel(base_url: fixture.server.baseURL, model: "fixture", protocol: fixture.protocolName),
                            resources: EchoTestResources.root)
        },
        settingsSource: { AgentTaskSource(settings: $0, resources: EchoTestResources.root) })

    static let native = AgentEngine(
        description: "native",
        fixtureSource: { fixture in
            let endpoint = AgentEndpoint(baseURL: fixture.server.baseURL, model: "fixture", apiKey: nil,
                                         apiProtocol: fixture.protocolName == .responses ? .responses : .chatCompletions)
            return AgentHarness(resolveModel: {
                let transport = AgentTransport.make(for: endpoint)
                return { ledger, budget in EchoLanguageModel(endpoint: endpoint, transport: transport, ledger: ledger, budget: budget) }
            })
        },
        settingsSource: { AgentHarness(settings: $0) })
}

@MainActor final class SessionFixture {
    let root: URL
    let server: LoopbackModelServer
    let persistence: WorkspacePersistence
    let engine: AgentEngine
    var protocolName = AgentModel.ProtocolName.chat_completions
    lazy var workspace = WorkspaceStore(persistence: persistence, sourceFactory: { [unowned self] in self.source() })
    init(engine: AgentEngine = .rust) throws {
        self.engine = engine
        root = FileManager.default.temporaryDirectory.appendingPathComponent("echo-session-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        persistence = WorkspacePersistence(url: root.appendingPathComponent("workspace.json"))
        do { server = try LoopbackModelServer() }
        catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    func source() -> any TaskSource { engine.fixtureSource(self) }
    func close() async throws {
        workspace.shutdown()
        defer { try? FileManager.default.removeItem(at: root) }
        var serverError: (any Error)?
        do { try server.stop() } catch { serverError = error }
        try await waitForAgentShutdown()
        if let serverError { throw serverError }
    }
}

@MainActor func withSession(_ engine: AgentEngine = .rust, _ body: (SessionFixture) async throws -> Void) async throws {
    let fixture = try SessionFixture(engine: engine)
    do { try await body(fixture) }
    catch {
        do { try await fixture.close() } catch { Issue.record(error) }
        throw error
    }
    try await fixture.close()
}
