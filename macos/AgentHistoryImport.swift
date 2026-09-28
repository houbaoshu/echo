import Foundation
import FoundationModels

// One-way import of Rust-engine conversations into the native engine: v1 history (and legacy
// plain-text conversations) becomes the native transcript, with the rules mini-agent-rs applies
// when it restores one (`conversation.rs` `from_history`, `restore.rs`). Pure Swift: importing
// never needs the Rust core.

enum AgentHistoryImport {
    struct Failure: Error, LocalizedError, Equatable {
        let reason: String
        var errorDescription: String? { "Agent 历史无法迁移（\(reason)），已保留原历史。" }
    }

    /// What the Rust engine kept for a conversation, after `TaskStore.init(snapshot:)` cleaned it.
    struct Source {
        /// v1 history; nil for a conversation the Rust engine never ran, which imports as text.
        var history: Data?
        /// The conversation as shown: user and reply messages keep their identity through `coreID`.
        var messages: [ConversationMessage]
        /// What a legacy conversation sends the model (`TaskStore.requestMessages`).
        var requestMessages: [ConversationMessage]
        var receipts: [AgentInputReceipt]
        var pendingInputs: [AgentInput]
    }

    static func native(_ source: Source) throws(Failure) -> NativeAgentState {
        var state: NativeAgentState
        if let history = source.history { state = try v1(history, source: source) }
        else { state = try legacy(source.requestMessages) }
        // Input that never reached the history stays pending: continuing sends it.
        let imported = Set(state.entries.compactMap(Self.messageID))
        for input in source.pendingInputs where !imported.contains(input.client_message_id) {
            guard let id = UUID(uuidString: input.client_message_id) else { throw Failure(reason: "无效的待处理输入") }
            state.pendingInputs.append(.init(messageID: id, text: input.text))
        }
        return state
    }

    // MARK: v1

    private static let unknownResult = AgentToolResult.unknownAfterInterruption

    private static func v1(_ data: Data, source: Source) throws(Failure) -> NativeAgentState {
        guard let history = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              history["version"] as? Int == 1,
              let session = history["session_id"] as? String, !session.trimmingCharacters(in: .whitespaces).isEmpty,
              let entries = history["entries"] as? [[String: Any]],
              let turns = history["turns"] as? [[String: Any]],
              let nextID = (history["next_id"] as? NSNumber)?.uint64Value, nextID > 0 else {
            throw Failure(reason: "格式无效")
        }
        // IDs are unique and below next_id across turns and entries; entries name known turns.
        var ids = Set<UInt64>()
        let turnIDs = try turns.map { turn throws(Failure) -> UInt64 in
            guard let id = (turn["id"] as? NSNumber)?.uint64Value else { throw Failure(reason: "轮次无效") }
            return id
        }
        for id in turnIDs + entries.map({ ($0["id"] as? NSNumber)?.uint64Value ?? 0 }) {
            guard id != 0, id < nextID, ids.insert(id).inserted else { throw Failure(reason: "ID 重复或越界") }
        }
        let knownTurns = Set(turnIDs)

        let userIDs = Dictionary(source.messages.filter { $0.role == .user }.compactMap { m in m.coreID.map { ($0, m.id) } },
                                 uniquingKeysWith: { first, _ in first })
        let replyIDs = Dictionary(source.messages.filter { $0.role == .assistant }.compactMap { m in m.coreID.map { ($0, m.id) } },
                                  uniquingKeysWith: { first, _ in first })
        let receiptIDs = Dictionary(source.receipts.map { ($0.message_id, $0.client_message_id) }, uniquingKeysWith: { first, _ in first })

        var state = NativeAgentState()
        var starts: [UInt64: Int] = [:]
        // Calls of the current turn still waiting for a result, as (call ID, tool name).
        var pending: [(id: String, name: String)] = []
        func recoverMissing() {
            for call in pending {
                state.entries.append(.toolOutput(.init(id: call.id, toolName: call.name, segments: [.text(.init(content: unknownResult))])))
            }
            pending = []
        }
        var pendingTurn: UInt64 = 0

        for entry in entries {
            guard let id = (entry["id"] as? NSNumber)?.uint64Value,
                  let turn = (entry["turn_id"] as? NSNumber)?.uint64Value,
                  let value = entry["value"] as? [String: Any],
                  let message = value["message"] as? [String: Any],
                  let role = message["role"] as? String else { throw Failure(reason: "条目无效") }
            guard turn == 0 || knownTurns.contains(turn) else { throw Failure(reason: "条目指向未知轮次") }
            if role == "tool" {
                guard let callID = message["tool_call_id"] as? String, turn == pendingTurn,
                      let index = pending.firstIndex(where: { $0.id == callID }) else { throw Failure(reason: "孤立或重复的工具结果") }
                let call = pending.remove(at: index)
                state.entries.append(.toolOutput(.init(id: callID, toolName: call.name,
                                                       segments: [.text(.init(content: message["content"] as? String ?? ""))])))
                continue
            }
            // Missing results go right after their calls, before whatever came next.
            recoverMissing()
            if turn != 0, starts[turn] == nil { starts[turn] = state.entries.count }
            switch role {
            case "system":
                continue   // the native engine's instructions replace the archived prompt
            case "user":
                let text = message["content"] as? String ?? ""
                let messageID = userIDs[id]?.uuidString ?? receiptIDs[id] ?? UUID().uuidString
                state.entries.append(.prompt(Transcript.Prompt(metadata: [AgentPromptKey.message: messageID],
                                                               segments: [.text(.init(content: text))])))
            case "assistant":
                for item in value["response_items"] as? [[String: Any]] ?? [] where item["type"] as? String == "reasoning" {
                    let summary = (item["summary"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n\n")
                    let signature = (item["encrypted_content"] as? String).map { Data($0.utf8) }
                    guard !summary.isEmpty || signature != nil else { continue }
                    let reasoningID = item["id"] as? String ?? "echo-v1-reasoning-\(id)"
                    state.entries.append(.reasoning(Transcript.Reasoning(id: reasoningID, segments: [.text(.init(content: summary))],
                                                                         signature: signature)))
                }
                if let text = message["content"] as? String, !text.isEmpty {
                    let responseID = "echo-v1-\(id)"
                    state.entries.append(.response(Transcript.Response(id: responseID, assetIDs: [], segments: [.text(.init(content: text))])))
                    if let reply = replyIDs[id] { state.replies[responseID] = reply }
                }
                let calls = message["tool_calls"] as? [[String: Any]] ?? []
                if !calls.isEmpty {
                    var converted: [Transcript.ToolCall] = []
                    var seen = Set<String>()
                    for call in calls {
                        // Only what Rust's restore rejects (`validate_calls`): the model's own format
                        // errors — no name, arguments that are not JSON — are history like any other.
                        let function = call["function"] as? [String: Any] ?? [:]
                        guard let callID = call["id"] as? String, !callID.trimmingCharacters(in: .whitespaces).isEmpty,
                              seen.insert(callID).inserted else {
                            throw Failure(reason: "工具调用 ID 为空或重复")
                        }
                        let name = function["name"] as? String ?? ""
                        let raw = function["arguments"] as? String ?? ""
                        guard let arguments = (try? GeneratedContent(json: raw)) ?? (try? GeneratedContent(json: "{}")) else {
                            throw Failure(reason: "工具调用无效")
                        }
                        converted.append(Transcript.ToolCall(id: callID, metadata: [AgentCallArguments.rawKey: raw],
                                                             toolName: name, arguments: arguments))
                        pending.append((callID, name))
                    }
                    pendingTurn = turn
                    state.entries.append(.toolCalls(Transcript.ToolCalls(id: "echo-v1-calls-\(id)", converted)))
                }
            default:
                throw Failure(reason: "未知的消息角色")
            }
        }
        recoverMissing()

        // Turns in history order; one with no entries starts where the next one does.
        var nextStart = state.entries.count
        var converted: [NativeAgentState.Turn] = []
        for turn in turns.reversed() {
            let id = (turn["id"] as? NSNumber)?.uint64Value ?? 0
            let start = starts[id] ?? nextStart
            nextStart = start
            let status = (turn["outcome"] as? [String: Any])?["status"] as? String
            converted.append(.init(start: start, outcome: status.flatMap(AgentTurnOutcome.init(rawValue:)) ?? .interrupted))
        }
        state.turns = converted.reversed()
        return state
    }

    // MARK: Legacy text

    /// Each user message begins a turn that stays interrupted until a reply completes it.
    private static func legacy(_ messages: [ConversationMessage]) throws(Failure) -> NativeAgentState {
        var state = NativeAgentState()
        for message in messages {
            switch message.role {
            case .user:
                state.turns.append(.init(start: state.entries.count, outcome: .interrupted))
                state.entries.append(.prompt(Transcript.Prompt(metadata: [AgentPromptKey.message: message.id.uuidString],
                                                               segments: [.text(.init(content: message.content))])))
            case .assistant:
                guard let last = state.turns.indices.last else { throw Failure(reason: "回复先于提问") }
                let responseID = "echo-legacy-\(message.id.uuidString)"
                state.entries.append(.response(Transcript.Response(id: responseID, assetIDs: [], segments: [.text(.init(content: message.content))])))
                state.replies[responseID] = message.id
                state.turns[last].outcome = .completed
            }
        }
        return state
    }

    private static func messageID(_ entry: Transcript.Entry) -> String? {
        guard case .prompt(let prompt) = entry else { return nil }
        return try? prompt.metadata[AgentPromptKey.message]?.value(String.self)
    }
}
