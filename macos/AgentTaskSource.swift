import Foundation

/// One bridge per turn makes saved model/protocol changes effective on the next
/// turn. Full local history, including provider metadata, crosses the boundary.
@MainActor final class AgentTaskSource: AgentSessionSource {
    private let credentials: () throws -> [String: Any]
    private let resources: URL?
    private var bridge: AgentBridge?
    private var ready = false
    private var cancelled = false
    private var queued: [(String, [String: Any])] = []
    private var requests: [String: (String, [String: Any])] = [:]
    init(settings: SettingsStore) {
        resources = Bundle.main.resourceURL
        credentials = {
            let (config, key) = try settings.savedModelCredentials()
            return ["base_url": config.baseURL, "model": config.model, "api_key": key,
                    "protocol": config.apiProtocol == .responses ? "responses" : "chat_completions"]
        }
    }
    init(model: [String: Any], resources: URL) {
        self.resources = resources; credentials = { model }
    }
    func start(messages: [ConversationMessage], receive: @escaping @MainActor (TaskEvent) -> Void) {
        receive(.failed("Agent 需要统一会话入口。"))
    }
    func open(sessionID: String, history: Data?, messages: [ConversationMessage], directory: URL?,
              receive: @escaping ([String: Any]) -> Void, failure: @escaping (String) -> Void) throws {
        bridge?.close(); bridge = nil
        // A failed reopen must not wait for cleanup from a closed bridge.
        ready = false; cancelled = false; queued = []; requests = [:]
        var imported: [String: Any]?
        if let history {
            guard let decoded = try JSONSerialization.jsonObject(with: history) as? [String: Any] else {
                throw SettingsError("Agent 历史格式无效。")
            }
            imported = decoded
        }
        if imported == nil, !messages.isEmpty {
            guard let resources else { throw SettingsError("缺少 Agent 资源。") }
            let prompt = try String(contentsOf: resources.appendingPathComponent("agent/conversation.md"), encoding: .utf8)
            var entries: [[String: Any]] = [["id": 1, "turn_id": 0,
                "value": ["message": ["role": "system", "content": prompt]]]]
            for message in ConversationContext.messages(messages) {
                entries.append(["id": entries.count + 1, "turn_id": 2,
                    "value": ["message": ["role": message.role.rawValue, "content": message.content]]])
            }
            // Turn IDs and entry IDs share one namespace.
            for index in 1..<entries.count { entries[index]["id"] = index + 2 }
            imported = ["version": 1, "session_id": sessionID, "entries": entries,
                "turns": [["id": 2, "model_calls": 0, "outcome": ["status": "interrupted"]]],
                "next_id": entries.count + 2, "directory": NSNull()]
        }
        if history != nil, var recovered = imported {
            var entries = recovered["entries"] as? [[String: Any]] ?? []
            var next = recovered["next_id"] as? UInt64 ?? 1
            var turns = recovered["turns"] as? [[String: Any]] ?? []
            for message in messages where message.role == .user && message.coreID == nil {
                if turns.isEmpty {
                    turns.append(["id": next, "model_calls": 0, "outcome": ["status": "interrupted"]]); next += 1
                }
                entries.append(["id": next, "turn_id": turns.last?["id"] ?? 0,
                                "value": ["message": ["role": "user", "content": message.content]]])
                next += 1
                if !turns.isEmpty { turns[turns.count - 1]["outcome"] = ["status": "interrupted"] }
            }
            recovered["entries"] = entries; recovered["next_id"] = next; recovered["turns"] = turns
            imported = recovered
        }
        // Clear a stale directory even for ordinary chat; the core will pause
        // only if it later needs a tool. Project association is owned by Swift.
        imported?["directory"] = directory?.path ?? (NSNull() as Any)
        let current = try AgentBridge(sessionID: sessionID, model: credentials(), history: imported,
                                      directory: directory, resources: resources)
        bridge = current
        current.onFailure = { error in failure(error.localizedDescription) }
        current.onBatch = { [weak self, weak current] original in
            guard let self, self.bridge === current else { return }
            var batch = original
            if let requestID = batch["request_id"] as? String, let request = self.requests.removeValue(forKey: requestID),
               let error = batch["error"] as? String {
                if error.contains("cancelled before processing") {
                    batch["error"] = NSNull()
                } else if request.0 == "start_tool", error.contains("stale") || error.contains("tool no longer") || error.contains("working directory required") {
                    batch["error"] = NSNull()
                } else if request.0 == "steer", error.contains("no running turn") {
                    do {
                        // A late receipt must not start a new turn after Stop.
                        if !self.cancelled { try self.control("submit", fields: request.1) }
                        batch["error"] = NSNull()
                    }
                    catch { failure(error.localizedDescription) }
                }
            }
            if self.requests.values.contains(where: { $0.0 == "steer" }) {
                if batch["type"] as? String == "tool_pending" { batch["type"] = "update" }
                batch["events"] = (batch["events"] as? [[String: Any]] ?? []).filter {
                    ($0["kind"] as? [String: Any])?["type"] as? String != "finished"
                }
            }
            receive(batch)
            if batch["type"] as? String == "ready" {
                self.ready = true
                let pending = self.queued; self.queued = []
                do { for (type, fields) in pending { try self.control(type, fields: fields) } }
                catch { failure(error.localizedDescription) }
            }
        }
        current.startPolling()
    }
    func control(_ type: String, fields: [String: Any] = [:]) throws {
        guard let bridge else { throw SettingsError("Agent 会话未启动。") }
        if !ready {
            guard queued.count < 32 else { throw SettingsError("补充指令队列已满，请稍后发送。") }
            queued.append((type, fields)); return
        }
        let id = try bridge.send(type, fields: fields)
        requests[id] = (type, fields)
    }
    func cancel() { cancelled = true; queued = []; bridge?.cancel() }
    func close(afterCleanup: @escaping () -> Void) {
        queued = []; ready = false
        guard let current = bridge else { afterCleanup(); return }
        bridge = nil
        // Keep polling a retired session until its own cleanup acknowledgement.
        // Other sessions can continue, and its directory lease remains held.
        var finished = false
        let finish = {
            guard !finished else { return }; finished = true
            current.onBatch = nil; current.onFailure = nil; current.onClosed = nil
            current.close(); afterCleanup()
        }
        current.onClosed = finish
        current.onFailure = { _ in
            // Keep the per-session acknowledgement path alive after a polling
            // failure. A global shutdown wait would depend on unrelated idle
            // bridges and could prevent this lease from ever being released.
            current.cancel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { current.startPolling() }
        }
        current.onBatch = { batch in
            if ["cancelled", "initialization_failed"].contains(batch["type"] as? String ?? "") {
                finish()
            }
        }
        current.cancel()
    }
}

/// FIFO arbitration on canonical paths. Ownership lasts through the whole turn.
@MainActor final class AgentDirectoryScheduler {
    private var owners: [String: UUID] = [:]
    private var waiting: [(UUID, String, () -> Void)] = []
    func acquire(_ path: String, owner: UUID, ready: @escaping () -> Void) {
        cancelWait(owner)
        if owners[path] == nil || owners[path] == owner {
            owners[path] = owner; ready()
        } else { waiting.append((owner, path, ready)) }
    }
    func cancelWait(_ owner: UUID) { waiting.removeAll { $0.0 == owner } }
    func release(_ owner: UUID) {
        cancelWait(owner)
        let paths = owners.filter { $0.value == owner }.map(\.key)
        for path in paths {
            owners[path] = nil
            if let index = waiting.firstIndex(where: { $0.1 == path }) {
                let next = waiting.remove(at: index)
                owners[path] = next.0; next.2()
            }
        }
    }
}
