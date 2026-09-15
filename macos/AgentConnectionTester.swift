import Foundation

/// Uses the production Rust model adapter and parser. A fresh session has no
/// directory, and this probe never sends provide_directory or start_tool.
struct ModelConnectionTester: ConnectionTesting {
    var resources: URL? = Bundle.main.resourceURL

    @MainActor func test(configuration: ModelConfiguration, key: String) async throws {
        let configuration = try configuration.validated()
        guard !key.contains("\r"), !key.contains("\n") else { throw SettingsError("API Key 不能包含换行。") }
        try Task.checkCancellation()
        let bridge = try AgentBridge(sessionID: UUID().uuidString, model: [
            "base_url": configuration.baseURL, "model": configuration.model, "api_key": key,
            "protocol": configuration.apiProtocol == .responses ? "responses" : "chat_completions"
        ], resources: resources)
        defer { bridge.cancel(); bridge.close() }
        var result: Result<Void, Error>?
        bridge.onFailure = { _ in result = .failure(SettingsError("Agent 连接测试失败，请检查应用资源与模型配置。")) }
        bridge.onClosed = {
            if result == nil { result = .failure(SettingsError("Agent 连接测试意外结束。")) }
        }
        bridge.onBatch = { [weak bridge] batch in
            guard let bridge, result == nil else { return }
            if batch["type"] as? String == "ready" {
                do {
                    try bridge.send("submit", fields: ["text":
                        "This is a tool capability test. Return exactly one bash tool call with command: printf 'ECHO_TOOL_PROBE'. Do not answer with text. The host will inspect the call without executing it."])
                } catch { result = .failure(error) }
            }
            if batch["error"] as? String != nil {
                // Provider errors can contain arbitrary response bodies; do not
                // show them or accidentally echo credentials in a settings probe.
                result = .failure(SettingsError("模型请求失败，请检查服务地址、密钥、模型及 \(configuration.apiProtocol.title) 工具调用支持。"))
                return
            }
            for event in batch["events"] as? [[String: Any]] ?? [] {
                guard let kind = event["kind"] as? [String: Any] else { continue }
                switch kind["type"] as? String {
                case "directory_required": result = .success(())
                case "finished":
                    result = .failure(SettingsError("未收到有效的 bash 工具调用，请检查模型、额度及 \(configuration.apiProtocol.title) 工具调用支持。"))
                default: break
                }
            }
        }
        bridge.startPolling()
        let deadline = ContinuousClock.now.advanced(by: .seconds(65))
        while result == nil {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw SettingsError("Agent 工具调用测试超时。") }
            try await Task.sleep(for: .milliseconds(25))
        }
        try Task.checkCancellation()
        try result!.get()
    }
}
