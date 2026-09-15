//! Serialization checks against the production wire and Mini Agent types.
use echo_agent::wire::*;
use serde::{Serialize, de::DeserializeOwned};
use serde_json::{Value, json};

fn round_trip<T: Serialize + DeserializeOwned + PartialEq + std::fmt::Debug>(value: &T) {
    let encoded = serde_json::to_string(value).unwrap();
    assert_eq!(&serde_json::from_str::<T>(&encoded).unwrap(), value);
}

#[test]
fn v2_envelope_rejects_v1_without_changing_archive_version() {
    let mut request: WireRequest<SessionCommand> = serde_json::from_value(json!({
        "version": 2, "request_id": "request-一",
        "command": {"type": "send_message", "input": {"client_message_id": "ui-1", "text": "你好 🌱"}}
    })).unwrap();
    assert_eq!(request.validate_envelope(), Ok(()));
    round_trip(&request);
    request.version = 1;
    assert_eq!(
        request.validate_envelope(),
        Err(ErrorCode::UnsupportedVersion)
    );
    request.version = 2;
    request.request_id = "  ".into();
    assert_eq!(request.validate_envelope(), Err(ErrorCode::InvalidRequest));
    assert_eq!((COMMAND_CAPACITY, EVENT_CAPACITY), (32, 64));
}

#[test]
fn controls_require_checkpoint_generation_and_cannot_enter_command_queue() {
    let value = json!({"type":"authorize_tool", "checkpoint":{"generation":"handle-2","revision":7},
        "operation_id":42, "directory":"/tmp/project"});
    let control: SessionControl = serde_json::from_value(value.clone()).unwrap();
    round_trip(&control);
    assert!(serde_json::from_value::<SessionCommand>(value.clone()).is_err());
    let mut missing_generation = value;
    missing_generation["checkpoint"]
        .as_object_mut()
        .unwrap()
        .remove("generation");
    assert!(serde_json::from_value::<SessionControl>(missing_generation).is_err());
    for kind in ["acknowledge_checkpoint", "checkpoint_failed"] {
        let value = json!({"type":kind,"checkpoint":{"generation":"handle-2","revision":7}});
        round_trip(&serde_json::from_value::<SessionControl>(value).unwrap());
    }
    assert!(
        serde_json::from_value::<SessionControl>(
            json!({"type":"acknowledge_checkpoint","revision":7})
        )
        .is_err()
    );
}

#[test]
fn opaque_history_and_receipts_share_one_checkpoint() {
    let raw = include_str!("../../tests/fixtures/agent-v1/responses-tool.json");
    let id = CheckpointId {
        generation: "handle-2".into(),
        revision: 7,
    };
    let checkpoint = Checkpoint {
        id,
        history: raw.to_string(),
        input_receipts: vec![InputReceipt {
            client_message_id: ClientMessageId("ui-1".into()),
            message_id: 3,
            turn_id: 2,
        }],
        projection: vec![DisplayEntry::Message {
            message_id: 3,
            turn_id: 2,
            role: DisplayRole::User,
            text: "读取示例".into(),
            final_reply: false,
        }],
    };
    let poll = WirePoll {
        version: WIRE_VERSION,
        closed: false,
        batches: vec![SessionBatch {
            session_id: "session-一".into(),
            generation: "handle-2".into(),
            turn_id: Some(2),
            operation_id: None,
            kind: BatchKind::Update {},
            events: vec![],
            checkpoint: Some(checkpoint),
        }],
    };
    round_trip(&poll);
    let decoded: WirePoll = serde_json::from_str(&serde_json::to_string(&poll).unwrap()).unwrap();
    let restored = &decoded.batches[0].checkpoint.as_ref().unwrap().history;
    assert_eq!(restored.as_bytes(), raw.as_bytes());
    assert_eq!(
        serde_json::from_str::<Value>(restored).unwrap()["version"],
        1
    );
    assert!(restored.contains("synthetic-opaque-fixture"));
}

#[test]
fn restore_distinguishes_identical_text_by_client_id() {
    let input = |id: &str| InputMessage {
        client_message_id: ClientMessageId(id.into()),
        text: "同一句".into(),
    };
    let restore = RestoreInput {
        source: HistoryInput::V1 {
            history: include_str!("../../tests/fixtures/agent-v1/completed-chat.json").to_string(),
        },
        input_receipts: vec![InputReceipt {
            client_message_id: ClientMessageId("ui-1".into()),
            message_id: 3,
            turn_id: 2,
        }],
        pending_inputs: vec![input("ui-1"), input("ui-2")],
        directory: None,
    };
    round_trip(&restore);
    assert_eq!(
        restore.pending_inputs[0].text,
        restore.pending_inputs[1].text
    );
    assert_ne!(
        restore.pending_inputs[0].client_message_id,
        restore.pending_inputs[1].client_message_id
    );
    // The runtime deduplication algorithm belongs to stage 2, not this shape test.
}

#[test]
fn invalid_or_ambiguous_wire_shapes_are_rejected() {
    for value in [
        json!({"type":"send_message","input":{"text":"missing id"}}),
        json!({"type":"send_message","input":{"client_message_id":"a","text":"ok","core_id":3}}),
        json!({"type":"continue","text":"unexpected"}),
        json!({"type":"unknown_command"}),
    ] {
        assert!(serde_json::from_value::<SessionCommand>(value).is_err());
    }
    // There cannot be both success and error in a command result.
    assert!(
        serde_json::from_value::<CommandResult>(json!({"status":"applied", "input_receipt":null,
        "error":{"code":"stopping","message":"stopping"}}))
        .is_err()
    );
    let rejected = WireReply {
        version: 2,
        request_id: Some("r-1".into()),
        admission: Admission::Rejected {
            error: SessionError {
                code: ErrorCode::QueueFull,
                message: "队列已满".into(),
            },
        },
    };
    round_trip(&rejected);
}
