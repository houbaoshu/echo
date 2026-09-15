import Foundation
import EchoAgentBridge

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
    let generation: String
    var onBatch: ((AgentBatch) -> Void)?
    var onFailure: ((Error) -> Void)?
    var onClosed: (() -> Void)?

    /// model uses the ABI names base_url, model, api_key and protocol. The caller
    /// supplies saved settings/keychain credentials; this adapter never stores keys.
    init(sessionID: String, generation: String = UUID().uuidString, model: AgentModel,
         restore: AgentRestore = AgentRestore(), resources: URL? = Bundle.main.resourceURL) throws {
        guard let resources else { throw AgentBridgeError(message: "缺少 Agent 应用资源。") }
        let config = AgentWireCreate(session_id: sessionID, generation: generation,
            prompt_path: resources.appendingPathComponent("agent/conversation.md").path, model: model, restore: restore)
        let json = try Self.encode(config)
        var error: UnsafeMutablePointer<CChar>?
        let pointer = json.withCString { echo_agent_create($0, &error) }
        let failure = error.flatMap { try? JSONDecoder().decode(AgentWireReply.self, from: Data(String(cString: $0).utf8)) }
        echo_agent_string_free(error)
        guard let pointer else { throw failure?.admission.error ?? AgentBridgeError(message: "无法创建 Agent 会话。") }
        self.sessionID = sessionID
        self.generation = generation
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
    func send(_ command: AgentCommand) throws -> String {
        guard let handle else { throw AgentBridgeError(message: "Agent 会话已关闭。") }
        let id = UUID().uuidString
        let request = AgentWireRequest(request_id: id, command: command)
        let json = try Self.encode(request)
        let response: AgentWireReply = try json.withCString { try Self.decode(echo_agent_request(handle.pointer, $0)) }
        guard response.version == 2, response.request_id == id else {
            throw AgentBridgeError(message: "Agent 返回不匹配的请求回执。")
        }
        guard response.admission.status == .queued else {
            throw response.admission.error ?? AgentBridgeError(message: "Agent 请求未接收。")
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
            let result: AgentWirePoll = try Self.decode(echo_agent_poll_events(handle.pointer, 8))
            guard result.version == 2 else { throw AgentBridgeError(code: .unsupported_version, message: "Agent 协议版本不匹配。") }
            for batch in result.batches {
                guard batch.session_id == sessionID, batch.generation == generation else { continue }
                onBatch?(batch)
                if self.handle == nil { return false }
            }
            if result.closed { polling = nil; onClosed?(); return false }
            return true
        } catch { polling = nil; onFailure?(error); return false }
    }

    private static func encode(_ value: some Encodable) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
    private static func decode<T: Decodable>(_ pointer: UnsafeMutablePointer<CChar>?) throws -> T {
        guard let pointer else { throw AgentBridgeError(message: "Agent 返回空数据。") }
        defer { echo_agent_string_free(pointer) }
        let data = Data(String(cString: pointer).utf8)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
