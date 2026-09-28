import AppKit

/// System-only acceptance of an already built, relocated App. Business history
/// assertions belong to EchoIntegrationTests; this checks the independent process
/// and the ordinary AppKit termination path with real child processes of the
/// execution core.
@MainActor enum AgentAcceptanceProbe {
    static func wait(_ label: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw SettingsError("验收等待超时：\(label)") }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    static func run(baseURL: String, root: URL, register: (WorkspaceStore) -> Void) async throws {
        let config = try ModelConfiguration(baseURL: baseURL, model: "fixture").validated()
        guard let host = try config.rootURL().host, ["127.0.0.1", "localhost"].contains(host),
              let resources = Bundle.main.resourceURL else {
            throw SettingsError("系统验收需要本机 fixture 和打包资源。")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pet = try PetStore(directory: resources.appendingPathComponent("pets/chiyan"))
        defer { pet.stop() }
        guard pet.image.width > 0 else { throw SettingsError("搬移后的应用无法加载精灵。") }
        let endpoint = AgentEndpoint(baseURL: config.baseURL, model: "fixture", apiKey: nil, apiProtocol: .chatCompletions)
        let workspace = WorkspaceStore(persistence: WorkspacePersistence(url: root.appendingPathComponent("workspace.json")),
            sourceFactory: {
                AgentHarness(resolveModel: {
                    let transport = AgentTransport.make(for: endpoint)
                    return { EchoLanguageModel(endpoint: endpoint, transport: transport, ledger: $0, budget: $1) }
                })
            })
        register(workspace)
        let project = root.appendingPathComponent("process-audit")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let projectID = workspace.addProject(url: project)
        let work = workspace.newConversation(projectID: projectID)
        guard work.store.send("acceptance-quit-tool") else { throw SettingsError("未能创建验收任务。") }
        try await wait("真实子进程启动") {
            work.store.tools.first?.state == "执行中"
                && FileManager.default.fileExists(atPath: project.appendingPathComponent("child.pid").path)
        }
        print("PASS: relocated bundle loaded pet and the Agent from empty cwd; requesting AppKit quit during bash")
        fflush(nil)
    }
}
