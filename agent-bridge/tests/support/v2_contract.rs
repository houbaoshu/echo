//! Executable stage-1 specification, deliberately not linked into the C ABI.
//! Move core-facing types to conversation::runner in stage 2; wire types stay
//! in echo-agent in stage 3. See docs/mini-agent-mainline-bridge-v2-contract.md.
use mini_agent::conversation::{ConversationEvent, ConversationHistory};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

pub const WIRE_VERSION: u32 = 2;
pub const COMMAND_CAPACITY: usize = 32;
pub const EVENT_CAPACITY: usize = 64;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct ClientMessageId(pub String);

/// Revisions are monotonic only within one handle's generation.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CheckpointId {
    pub generation: String,
    pub revision: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct InputMessage {
    pub client_message_id: ClientMessageId,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct InputReceipt {
    pub client_message_id: ClientMessageId,
    pub message_id: u64,
    pub turn_id: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum SessionCommand {
    SendMessage { input: InputMessage },
    Submit { input: InputMessage },
    Steer { input: InputMessage },
    ProvideDirectory { directory: Option<PathBuf> },
    // Empty struct variants enforce deny_unknown_fields; Serde's unit
    // variants otherwise accept extra payload fields on internally tagged enums.
    Continue {},
    ExportHistory {},
}

/// These controls bypass the ordinary command queue, including tool permission.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum SessionControl {
    AcknowledgeCheckpoint {
        checkpoint: CheckpointId,
    },
    CheckpointFailed {
        checkpoint: CheckpointId,
    },
    AuthorizeTool {
        checkpoint: CheckpointId,
        operation_id: u64,
        directory: PathBuf,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    UnsupportedVersion,
    InvalidRequest,
    RequestTooLarge,
    QueueFull,
    SessionClosed,
    Stopping,
    CancelledBeforeProcessing,
    TurnActive,
    NoActiveTurn,
    NotContinuable,
    InvalidHistory,
    ClientMessageConflict,
    StaleCheckpoint,
    StaleOperation,
    DirectoryRequired,
    InvalidDirectory,
    PersistenceFailed,
    InitializationFailed,
    ModelFailed,
    ExecutionFailed,
    Internal,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SessionError {
    pub code: ErrorCode,
    /// For display only; never branch or retry based on this text.
    pub message: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "status", rename_all = "snake_case", deny_unknown_fields)]
pub enum CommandResult {
    Applied { input_receipt: Option<InputReceipt> },
    Rejected { error: SessionError },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum DisplayEntry {
    Message {
        message_id: u64,
        turn_id: u64,
        role: DisplayRole,
        text: String,
        final_reply: bool,
    },
    Tool {
        message_id: u64,
        turn_id: u64,
        call_id: String,
        command: String,
        result: Option<String>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DisplayRole {
    User,
    Assistant,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Checkpoint<H> {
    pub id: CheckpointId,
    pub history: H,
    pub input_receipts: Vec<InputReceipt>,
    pub projection: Vec<DisplayEntry>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum BatchKind {
    Ready {},
    CommandResult {
        request_id: String,
        result: CommandResult,
    },
    Update {},
    ToolPending {
        operation_id: u64,
        directory: PathBuf,
    },
    Cancelled {},
    InitializationFailed {
        error: SessionError,
    },
}

/// Core instantiates H = ConversationHistory; the bridge encodes that history
/// as an opaque JSON string, so Swift never decodes/rebuilds its internal IDs.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SessionBatch<H = ConversationHistory> {
    pub session_id: String,
    pub generation: String,
    pub turn_id: Option<u64>,
    pub operation_id: Option<u64>,
    pub kind: BatchKind,
    pub events: Vec<ConversationEvent>,
    pub checkpoint: Option<Checkpoint<H>>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum HistoryInput<H> {
    Empty {},
    V1 { history: H },
    LegacyText { messages: Vec<LegacyMessage> },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LegacyMessage {
    pub role: DisplayRole,
    pub input: InputMessage,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RestoreInput<H> {
    pub source: HistoryInput<H>,
    pub input_receipts: Vec<InputReceipt>,
    pub pending_inputs: Vec<InputMessage>,
    /// Explicit override: None clears a persisted directory.
    pub directory: Option<PathBuf>,
}

// Wire-only envelopes. C submit/steer validate the nested command variant.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct WireRequest<T> {
    pub version: u32,
    pub request_id: String,
    pub command: T,
}

impl<T> WireRequest<T> {
    pub fn validate_envelope(&self) -> Result<(), ErrorCode> {
        if self.version != WIRE_VERSION {
            return Err(ErrorCode::UnsupportedVersion);
        }
        if self.request_id.trim().is_empty() {
            return Err(ErrorCode::InvalidRequest);
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct WireCreate {
    pub version: u32,
    pub session_id: String,
    pub generation: String,
    pub prompt_path: PathBuf,
    pub model: WireModel,
    pub restore: RestoreInput<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct WireModel {
    pub base_url: String,
    pub model: String,
    pub api_key: Option<String>,
    pub protocol: Protocol,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Protocol {
    ChatCompletions,
    Responses,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "status", rename_all = "snake_case", deny_unknown_fields)]
pub enum Admission {
    Queued {},
    Rejected { error: SessionError },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct WireReply {
    pub version: u32,
    pub request_id: Option<String>,
    pub admission: Admission,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct WirePoll {
    pub version: u32,
    pub batches: Vec<SessionBatch<String>>,
    pub closed: bool,
}
