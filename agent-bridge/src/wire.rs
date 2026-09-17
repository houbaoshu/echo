//! JSON v2 transport envelopes. All conversation types come from Mini Agent.
pub use mini_agent::conversation::runner::{
    AssistantStream, BatchKind, COMMAND_CAPACITY, Checkpoint, CheckpointId, ClientMessageId,
    CommandResult, DisplayEntry, DisplayRole, EVENT_CAPACITY, ErrorCode, HistoryInput,
    InputMessage, InputReceipt, LegacyMessage, RestoreInput, SessionBatch, SessionCommand,
    SessionControl, SessionError,
};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
pub const WIRE_VERSION: u32 = 2;

/// Untagged only at the transport boundary: each inner enum strictly validates
/// its own tag/fields, and controls are sent directly to the control mailbox.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum WireCommand {
    Command(SessionCommand),
    Control(SessionControl),
}

// Wire-only envelopes. C submit/steer validate the nested command variant.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct WireRequest<T = WireCommand> {
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
    /// Latest display-only text of the running model operation, if it changed since
    /// the previous poll. Deltas between polls are coalesced; never persist it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stream: Option<AssistantStream>,
}

impl WireCommand {
    pub fn validate(&self) -> Result<(), SessionError> {
        let valid = match self {
            Self::Command(
                SessionCommand::SendMessage { input }
                | SessionCommand::Submit { input }
                | SessionCommand::Steer { input },
            ) => !input.client_message_id.0.trim().is_empty() && !input.text.trim().is_empty(),
            Self::Control(control) => {
                let checkpoint = match control {
                    SessionControl::AcknowledgeCheckpoint { checkpoint }
                    | SessionControl::CheckpointFailed { checkpoint }
                    | SessionControl::AuthorizeTool { checkpoint, .. } => checkpoint,
                };
                let operation_valid = match control {
                    SessionControl::AuthorizeTool {
                        operation_id,
                        directory,
                        ..
                    } => *operation_id > 0 && directory.is_absolute(),
                    _ => true,
                };
                !checkpoint.generation.trim().is_empty()
                    && checkpoint.revision > 0
                    && operation_valid
            }
            _ => true,
        };
        if valid {
            Ok(())
        } else {
            Err(SessionError::new(
                ErrorCode::InvalidRequest,
                "invalid command identifiers or input",
            ))
        }
    }
}
