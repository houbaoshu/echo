//! Immutable v1 compatibility fixtures exercise the current history decoder.
use mini_agent::conversation::{Conversation, ConversationConfig, ConversationHistory, Operation};
use serde_json::{Value, json};

const CHAT: &str = include_str!("../../tests/fixtures/agent-v1/completed-chat.json");
const RESPONSES: &str = include_str!("../../tests/fixtures/agent-v1/responses-tool.json");
const INTERRUPTED: &str = include_str!("../../tests/fixtures/agent-v1/interrupted-tool.json");
const INVALID: &str = include_str!("../../tests/fixtures/agent-v1/invalid-duplicate-id.json");

fn restore(raw: &str) -> mini_agent::Result<Conversation> {
    Conversation::from_history(
        ConversationConfig::new("Current bundle prompt"),
        serde_json::from_str::<ConversationHistory>(raw).unwrap(),
    )
}

#[test]
fn completed_archives_round_trip_without_execution_or_metadata_loss() {
    for raw in [CHAT, RESPONSES] {
        let mut core = restore(raw).unwrap();
        assert!(!core.is_active());
        assert!(matches!(core.next_operation(), Operation::Idle));
        assert!(core.take_events().is_empty());
        assert_eq!(
            serde_json::to_value(core.export_history()).unwrap(),
            serde_json::from_str::<Value>(raw).unwrap()
        );
    }
    let history = restore(CHAT).unwrap().export_history();
    assert_ne!(history.entries[1].id, history.entries[3].id);
    assert_eq!(
        history.entries[1].value.message,
        history.entries[3].value.message
    );
}

#[test]
fn interrupted_tool_gets_one_unknown_result_before_follow_up_and_never_replays() {
    let mut core = restore(INTERRUPTED).unwrap();
    assert!(matches!(core.next_operation(), Operation::Idle));
    let history = serde_json::to_value(core.export_history()).unwrap();
    let entries = history["entries"].as_array().unwrap();
    assert_eq!(entries.len(), 5);
    assert_eq!(
        entries[3]["value"]["message"]["tool_call_id"],
        "call_fixture"
    );
    let result: Value =
        serde_json::from_str(entries[3]["value"]["message"]["content"].as_str().unwrap()).unwrap();
    assert_eq!(result["status"], "unknown");
    assert_eq!(entries[4]["value"]["message"]["content"], "不要重放旧命令");
    assert_eq!(history["turns"][0]["outcome"]["status"], "interrupted");
    assert_eq!(history["next_id"], 9);
    // A second import cannot add another synthetic tool result or change IDs.
    let mut again = restore(&history.to_string()).unwrap();
    assert_eq!(
        serde_json::to_value(again.export_history()).unwrap(),
        history
    );
    again.continue_turn().unwrap();
    let Operation::Model {
        history: context, ..
    } = again.next_operation()
    else {
        panic!("continue must ask the model, never replay the archived tool")
    };
    assert_eq!(context.len(), entries.len());
    assert_eq!(
        serde_json::to_value(&context[2]).unwrap()["response_items"],
        entries[2]["value"]["response_items"]
    );
}

#[test]
fn corrupt_archives_fail_closed() {
    assert!(restore(INVALID).is_err());
    for (name, mutate) in [
        ("unsupported version", 0),
        ("unknown turn", 1),
        ("orphan result", 2),
        ("metadata mismatch", 3),
    ] {
        let mut raw: Value = serde_json::from_str(RESPONSES).unwrap();
        match mutate {
            0 => raw["version"] = json!(2),
            1 => raw["entries"][1]["turn_id"] = json!(999),
            2 => raw["entries"][3]["value"]["message"]["tool_call_id"] = json!("unknown"),
            3 => raw["entries"][2]["value"]["response_items"][1]["arguments"] = json!("{}"),
            _ => unreachable!(),
        }
        assert!(restore(&raw.to_string()).is_err(), "{name}");
    }
}
