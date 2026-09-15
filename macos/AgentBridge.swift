import Foundation
import EchoAgentBridge

struct AgentBridgeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// Keeps pointer lifetime separate from main-actor polling. Never transfers a
// borrowed Rust buffer into Swift; returned JSON is copied and freed immediately.
private final class AgentHandle {
    let pointer: OpaquePointer
    init(_ pointer: OpaquePointer) { self.pointer = pointer }
    deinit { echo_agent_destroy(pointer) }
}

@MainActor
final class AgentBridge {
    private var handle: AgentHandle?
    private var polling: Task<Void, Never>?
    let sessionID: String
    var onBatch: (([String: Any]) -> Void)?
    var onFailure: ((Error) -> Void)?
    var onClosed: (() -> Void)?

    /// model uses the ABI names base_url, model, api_key and protocol. The caller
    /// supplies saved settings/keychain credentials; this adapter never stores keys.
    init(sessionID: String, model: [String: Any], history: [String: Any]? = nil,
         directory: URL? = nil, resources: URL? = Bundle.main.resourceURL) throws {
        guard let resources else { throw AgentBridgeError(message: "缺少 Agent 应用资源。") }
        var config: [String: Any] = ["version": 1, "session_id": sessionID,
            "prompt_path": resources.appendingPathComponent("agent/conversation.md").path, "model": model]
        if let history { config["history"] = history }
        if let directory { config["directory"] = directory.path }
        let json = try Self.encode(config)
        var error: UnsafeMutablePointer<CChar>?
        let pointer = json.withCString { echo_agent_create($0, &error) }
        let failure = error.map { String(cString: $0) }
        echo_agent_string_free(error)
        guard let pointer else { throw AgentBridgeError(message: failure ?? "无法创建 Agent 会话。") }
        self.sessionID = sessionID
        self.handle = AgentHandle(pointer)
    }

    func startPolling() {
        guard polling == nil, handle != nil else { return }
        polling = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard self?.poll() == true else { return }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
        }
    }

    @discardableResult
    func send(_ type: String, fields: [String: Any] = [:]) throws -> String {
        guard let handle else { throw AgentBridgeError(message: "Agent 会话已关闭。") }
        let id = UUID().uuidString
        var request = fields
        request["version"] = 1; request["request_id"] = id; request["type"] = type
        let json = try Self.encode(request)
        let response = try json.withCString { try Self.decode(echo_agent_request(handle.pointer, $0)) }
        guard response["accepted"] as? Bool == true else {
            throw AgentBridgeError(message: response["error"] as? String ?? "Agent 请求未接收。")
        }
        return id
    }

    func cancel() { if let handle { echo_agent_cancel(handle.pointer) } }

    func close() {
        polling?.cancel(); polling = nil
        handle = nil
    }

    /// Call after closing all bridges and before replying to application termination.
    /// Suspension keeps the main actor available while Rust reaps command processes.
    static func waitForShutdown() async {
        while echo_agent_active_sessions() != 0 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { continuation.resume() }
            }
        }
    }

    @discardableResult
    func poll() -> Bool {
        guard let handle else { return false }
        do {
            let result = try Self.decode(echo_agent_poll_events(handle.pointer, 8))
            for batch in result["batches"] as? [[String: Any]] ?? [] {
                guard batch["version"] as? Int == 1, batch["session_id"] as? String == sessionID else { continue }
                onBatch?(batch)
                if self.handle == nil { return false }
            }
            if result["closed"] as? Bool == true { polling = nil; onClosed?(); return false }
            return true
        } catch { polling = nil; onFailure?(error); return false }
    }

    private static func encode(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
    private static func decode(_ pointer: UnsafeMutablePointer<CChar>?) throws -> [String: Any] {
        guard let pointer else { throw AgentBridgeError(message: "Agent 返回空数据。") }
        defer { echo_agent_string_free(pointer) }
        let data = Data(String(cString: pointer).utf8)
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentBridgeError(message: "Agent 返回无效数据。")
        }
        return value
    }
}
