import Foundation

/// Rebuild on each UI turn so saved model settings apply to the next request.
@MainActor final class AgentTaskSource: AgentSessionSource {
    private let credentials: () throws -> AgentModel
    private let resources: URL?
    private var bridge: AgentBridge?
    private var ready = false
    private var cancelled = false
    private var cleanupConfirmed = false
    private var queued: [AgentCommand] = []
    private var controls: [AgentCommand] = []
    private var retry: Task<Void, Never>?
    private var closingBridges: [UUID: AgentBridge] = [:]
    private var cleanupWaiters: [() -> Void] = []
    init(settings: SettingsStore) {
        resources = Bundle.main.resourceURL
        credentials = {
            let (config, key) = try settings.savedModelCredentials()
            return AgentModel(base_url: config.baseURL, model: config.model, api_key: key,
                              protocol: config.apiProtocol == .responses ? .responses : .chat_completions)
        }
    }
    init(model: AgentModel, resources: URL) {
        self.resources = resources; credentials = { model }
    }
    func start(messages: [ConversationMessage], receive: @escaping @MainActor (TaskEvent) -> Void) {
        receive(.failed("Agent 需要统一会话入口。"))
    }
    func open(sessionID: String, generation: String, restore: AgentRestore,
              receive: @escaping (AgentBatch) -> Void, failure: @escaping (String) -> Void) throws {
        bridge?.close(); bridge = nil
        retry?.cancel(); retry = nil
        ready = false; cancelled = false; cleanupConfirmed = false; queued = []; controls = []
        let current = try AgentBridge(sessionID: sessionID, generation: generation, model: credentials(),
                                      restore: restore, resources: resources)
        bridge = current
        current.onFailure = { error in failure(error.localizedDescription) }
        current.onBatch = { [weak self, weak current] batch in
            guard let self, self.bridge === current else { return }
            if batch.kind.type == .cancelled || batch.kind.type == .initialization_failed {
                self.cleanupConfirmed = true
            }
            receive(batch)
            if batch.kind.type == .ready {
                self.ready = true
                let pending = self.queued; self.queued = []
                do { for command in pending where !self.cancelled { try self.control(command) } }
                catch { failure(error.localizedDescription) }
            }
        }
        current.startPolling()
    }
    func control(_ command: AgentCommand) throws {
        guard let bridge else { throw AgentBridgeError(code: .session_closed, message: "Agent 会话未启动。") }
        // Persistence controls remain usable before Ready and during Stop.
        if command.isControl {
            if case .checkpointFailed = command {
                controls = []; retry?.cancel(); retry = nil
                try bridge.send(command); return
            }
            do {
                if !controls.isEmpty { enqueueControl(command); return }
                try bridge.send(command)
            } catch let error as AgentBridgeError where error.code == .queue_full {
                enqueueControl(command)
            }
            return
        }
        guard !cancelled else { throw AgentBridgeError(code: .stopping, message: "Agent 正在停止。") }
        cleanupConfirmed = false
        if !ready {
            guard queued.count < 32 else { throw AgentBridgeError(code: .queue_full, message: "补充指令队列已满，请稍后发送。") }
            queued.append(command); return
        }
        try bridge.send(command)
    }
    private func enqueueControl(_ command: AgentCommand) {
        if !controls.contains(command) { controls.append(command) }
        guard retry == nil else { return }
        retry = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                guard let self, let bridge = self.bridge else { return }
                do {
                    while let next = self.controls.first {
                        try bridge.send(next); self.controls.removeFirst()
                    }
                    self.retry = nil; return
                } catch let error as AgentBridgeError where error.code == .queue_full { continue }
                catch { self.retry = nil; bridge.onFailure?(error); return }
            }
        }
    }
    func cancel() {
        cancelled = true; queued = []
        controls.removeAll { if case .authorizeTool = $0 { return true }; return false }
        bridge?.cancel()
    }
    func close(afterCleanup: @escaping () -> Void) {
        queued = []; controls = []; ready = false; cancelled = true
        retry?.cancel(); retry = nil
        cleanupWaiters.append(afterCleanup)
        guard let current = bridge else { finishCloseIfReady(); return }
        bridge = nil
        let closeID = UUID()
        closingBridges[closeID] = current
        // Keep the retired handle alive until its own cleanup receipt arrives.
        var finished = false
        let finish = {
            guard !finished else { return }; finished = true
            current.onBatch = nil; current.onFailure = nil; current.onClosed = nil
            current.close()
            self.closingBridges[closeID] = nil
            self.finishCloseIfReady()
        }
        if cleanupConfirmed { finish(); return }
        current.onClosed = finish
        current.onFailure = { _ in
            current.cancel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { current.startPolling() }
        }
        current.onBatch = { batch in
            if batch.kind.type == .cancelled || batch.kind.type == .initialization_failed { finish() }
        }
        current.cancel()
        current.startPolling()
    }
    private func finishCloseIfReady() {
        guard closingBridges.isEmpty else { return }
        let callbacks = cleanupWaiters; cleanupWaiters = []
        callbacks.forEach { $0() }
    }
}

/// FIFO arbitration on canonical paths. Ownership lasts through the whole turn.
@MainActor final class AgentDirectoryScheduler {
    private var owners: [String: UUID] = [:]
    private var waiting: [(UUID, String, () -> Void)] = []
    func acquire(_ path: String, owner: UUID, ready: @escaping () -> Void) {
        let path = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
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
