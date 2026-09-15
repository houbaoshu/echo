import Foundation

enum AgentDisplayRole: String, Codable { case user, assistant }

enum AgentErrorCode: String, Codable {
    case unsupported_version, invalid_request, request_too_large, queue_full, session_closed, stopping
    case cancelled_before_processing, turn_active, no_active_turn, not_continuable, invalid_history
    case client_message_conflict, stale_checkpoint, stale_operation, directory_required, invalid_directory
    case persistence_failed, initialization_failed, model_failed, execution_failed, `internal`
}
struct AgentBridgeError: Error, LocalizedError, Codable {
    var code: AgentErrorCode = .internal
    let message: String
    var errorDescription: String? { message }
}
struct AgentModel: Codable {
    enum ProtocolName: String, Codable { case chat_completions, responses }
    var base_url: String
    var model: String
    var api_key: String?
    var `protocol`: ProtocolName
}
struct AgentInput: Codable, Equatable {
    var client_message_id: String
    var text: String
}
struct AgentInputReceipt: Codable, Equatable {
    var client_message_id: String
    var message_id: UInt64
    var turn_id: UInt64
}
struct AgentCheckpointID: Codable, Equatable {
    var generation: String
    var revision: UInt64
}
struct AgentLegacyMessage: Codable {
    var role: AgentDisplayRole
    var input: AgentInput
}
struct AgentHistoryInput: Codable {
    enum Kind: String, Codable { case empty, v1, legacy_text }
    var type: Kind
    var history: String?
    var messages: [AgentLegacyMessage]?
}
struct AgentRestore: Encodable {
    var source = AgentHistoryInput(type: .empty)
    var input_receipts: [AgentInputReceipt] = []
    var pending_inputs: [AgentInput] = []
    var directory: String?
    enum CodingKeys: String, CodingKey { case source, input_receipts, pending_inputs, directory }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(source, forKey: .source)
        try c.encode(input_receipts, forKey: .input_receipts)
        try c.encode(pending_inputs, forKey: .pending_inputs)
        try c.encode(directory, forKey: .directory)
    }
}
enum AgentCommand: Encodable, Equatable {
    case sendMessage(AgentInput), submit(AgentInput), steer(AgentInput)
    case provideDirectory(String?), `continue`, exportHistory
    case acknowledgeCheckpoint(AgentCheckpointID), checkpointFailed(AgentCheckpointID)
    case authorizeTool(AgentCheckpointID, operationID: UInt64, directory: String)
    var isControl: Bool {
        switch self {
        case .acknowledgeCheckpoint, .checkpointFailed, .authorizeTool: true
        default: false
        }
    }
    enum CodingKeys: String, CodingKey { case type, input, directory, checkpoint, operation_id }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let type: String
        switch self {
        case .sendMessage(let input): type = "send_message"; try c.encode(input, forKey: .input)
        case .submit(let input): type = "submit"; try c.encode(input, forKey: .input)
        case .steer(let input): type = "steer"; try c.encode(input, forKey: .input)
        case .provideDirectory(let path): type = "provide_directory"; try c.encode(path, forKey: .directory)
        case .continue: type = "continue"
        case .exportHistory: type = "export_history"
        case .acknowledgeCheckpoint(let id): type = "acknowledge_checkpoint"; try c.encode(id, forKey: .checkpoint)
        case .checkpointFailed(let id): type = "checkpoint_failed"; try c.encode(id, forKey: .checkpoint)
        case .authorizeTool(let id, let operation, let directory):
            type = "authorize_tool"
            try c.encode(id, forKey: .checkpoint); try c.encode(operation, forKey: .operation_id)
            try c.encode(directory, forKey: .directory)
        }
        try c.encode(type, forKey: .type)
    }
}
struct AgentDisplayEntry: Codable, Equatable {
    enum Kind: String, Codable { case message, tool }
    var type: Kind
    var message_id: UInt64
    var turn_id: UInt64
    var role: AgentDisplayRole?
    var text: String?
    var final_reply: Bool?
    var call_id: String?
    var command: String?
    var result: String?
}
struct AgentCheckpoint: Codable {
    var id: AgentCheckpointID
    var history: String
    var input_receipts: [AgentInputReceipt]
    var projection: [AgentDisplayEntry]
}
struct AgentOutcome: Codable {
    enum Status: String, Codable { case completed, step_limit, format_error_limit, interrupted, failed }
    var status: Status
    var reply: String?
    var error: String?
}
struct AgentEvent: Codable {
    struct Kind: Codable {
        enum Tag: String, Codable {
            case turn_started, message_added, steering_queued, steering_accepted, model_started
            case assistant, directory_required, tool_ready, tool_started, tool_result, stopping, finished
        }
        struct Call: Codable { var id: String }
        var type: Tag
        var message_id: UInt64?
        var final_reply: Bool?
        var call: Call?
        var directory: String?
        var outcome: AgentOutcome?
    }
    var version: UInt32
    var session_id: String
    var turn_id: UInt64
    var operation_id: UInt64?
    var kind: Kind
}
struct AgentCommandResult: Codable {
    enum Status: String, Codable { case applied, rejected }
    var status: Status
    var input_receipt: AgentInputReceipt?
    var error: AgentBridgeError?
}
struct AgentBatch: Codable {
    struct Kind: Codable {
        enum Tag: String, Codable { case ready, command_result, update, tool_pending, cancelled, initialization_failed }
        var type: Tag
        var request_id: String?
        var result: AgentCommandResult?
        var operation_id: UInt64?
        var directory: String?
        var error: AgentBridgeError?
    }
    var session_id: String
    var generation: String
    var turn_id: UInt64?
    var operation_id: UInt64?
    var kind: Kind
    var events: [AgentEvent] = []
    var checkpoint: AgentCheckpoint?
    var error: AgentBridgeError? { kind.error ?? kind.result?.error }
}
struct AgentWireCreate: Encodable {
    let version = 2
    var session_id: String
    var generation: String
    var prompt_path: String
    var model: AgentModel
    var restore: AgentRestore
}
struct AgentWireRequest: Encodable {
    let version = 2
    var request_id: String
    var command: AgentCommand
}
struct AgentWireReply: Decodable {
    struct Admission: Decodable {
        enum Status: String, Decodable { case queued, rejected }
        var status: Status
        var error: AgentBridgeError?
    }
    var version: Int
    var request_id: String?
    var admission: Admission
}
struct AgentWirePoll: Decodable {
    var version: Int
    var batches: [AgentBatch]
    var closed: Bool
}
