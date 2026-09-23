//! Exercise the actual C parser, not a parallel serialization specification.
use echo_agent::*;
use serde_json::{Value, json};
use std::{
    ffi::{CStr, CString, c_char},
    time::{Duration, Instant},
};

fn owned(pointer: *mut c_char) -> Value {
    assert!(!pointer.is_null());
    let result =
        unsafe { serde_json::from_str(CStr::from_ptr(pointer).to_str().unwrap()).unwrap() };
    unsafe { echo_agent_string_free(pointer) };
    result
}
fn rejected_create(request: &str) -> Value {
    let input = CString::new(request).unwrap();
    let mut error = std::ptr::null_mut();
    let handle = unsafe { echo_agent_create(input.as_ptr(), &mut error) };
    if !handle.is_null() {
        unsafe { echo_agent_destroy(handle) };
        panic!("unexpected handle");
    }
    owned(error)
}
fn rejected_request(value: Value) -> Value {
    let input = CString::new(value.to_string()).unwrap();
    owned(unsafe { echo_agent_request(std::ptr::null_mut(), input.as_ptr()) })
}
fn code(reply: &Value) -> &str {
    assert_eq!(reply["version"], 2);
    assert_eq!(reply["admission"]["status"], "rejected");
    reply["admission"]["error"]["code"].as_str().unwrap()
}

#[test]
fn version_is_checked_before_v1_or_future_payloads() {
    for version in [1, 3, u64::MAX] {
        // Deliberately incompatible payload: version error must take precedence.
        let value = json!({"version":version,"session_id":"old","history":{},"type":"submit","text":"hello"});
        assert_eq!(
            code(&rejected_create(&value.to_string())),
            "unsupported_version"
        );
        assert_eq!(code(&rejected_request(value)), "unsupported_version");
    }
    for value in [
        json!({}),
        json!({"version":"2"}),
        json!({"version":null}),
        json!([]),
    ] {
        assert_eq!(
            code(&rejected_create(&value.to_string())),
            "invalid_request"
        );
    }
    assert_eq!(code(&rejected_create("{")), "invalid_request");
}

#[test]
fn malformed_create_and_oversized_utf8_are_rejected_without_initializing() {
    let valid = json!({"version":2,"session_id":"test","generation":"unique", "prompt_path":"/tmp/prompt",
        "model":{"base_url":"http://127.0.0.1:1","model":"test","protocol":"responses"},
        "restore":{"source":{"type":"empty"},"input_receipts":[],"pending_inputs":[],"directory":null}});
    let mut bad = Vec::new();
    for key in ["generation", "restore", "model", "prompt_path"] {
        let mut value = valid.clone();
        value.as_object_mut().unwrap().remove(key);
        bad.push(value);
    }
    for (key, replacement) in [
        ("generation", json!(" ")),
        ("session_id", json!("")),
        ("prompt_path", json!("relative")),
        ("unknown", json!(true)),
    ] {
        let mut value = valid.clone();
        value[key] = replacement;
        bad.push(value);
    }
    let mut absent_override = valid.clone();
    absent_override["restore"]
        .as_object_mut()
        .unwrap()
        .remove("directory");
    bad.push(absent_override);
    for value in bad {
        assert_eq!(
            code(&rejected_create(&value.to_string())),
            "invalid_request"
        );
    }
    let over_create_limit = json!({"version":2,"session_id":"large-history","generation":"large-2",
        "prompt_path":"/tmp/prompt.md",
        "model":{"base_url":"http://127.0.0.1:1","model":"test","protocol":"chat_completions"},
        "restore":{"source":{"type":"v1","history":tool_heavy_history(260)},
            "input_receipts":[],"pending_inputs":[],"directory":null}})
    .to_string();
    assert!(over_create_limit.len() > 32 * 1024 * 1024);
    assert_eq!(
        code(&rejected_create(&over_create_limit)),
        "request_too_large"
    );
    let over_command_limit =
        json!({"version":2,"padding":"🌱".repeat(4 * 1024 * 1024)}).to_string();
    let input = CString::new(over_command_limit).unwrap();
    assert_eq!(
        code(&owned(unsafe {
            echo_agent_request(std::ptr::null_mut(), input.as_ptr())
        })),
        "request_too_large"
    );
}

// Each archived command has at most 64 KiB in each output stream, as in production.
// Many such tool results can still make the complete v1 history exceed 16 MiB.
fn tool_heavy_history(turn_count: usize) -> String {
    let mut entries = vec![json!({"id":1,"turn_id":0,
        "value":{"message":{"role":"system","content":"Answer directly or use bash."}}})];
    let mut turns = Vec::new();
    let result = json!({"stdout":"x".repeat(64 * 1024), "stderr":"y".repeat(64 * 1024),
        "exit_code":0,"timed_out":false,"stdout_truncated":false,"stderr_truncated":false})
    .to_string();
    let mut next_id = 2u64;
    for index in 0..turn_count {
        let turn_id = next_id;
        next_id += 1;
        let call_id = format!("call-{index}");
        let user_id = next_id;
        next_id += 1;
        let proposal_id = next_id;
        next_id += 1;
        let result_id = next_id;
        next_id += 1;
        let reply_id = next_id;
        next_id += 1;
        entries.push(json!({"id":user_id,"turn_id":turn_id,
            "value":{"message":{"role":"user","content":format!("inspect {index}")}}}));
        entries.push(json!({"id":proposal_id,"turn_id":turn_id,
            "value":{"message":{"role":"assistant","content":null,"tool_calls":[{
                "id":call_id,"type":"function","function":{"name":"bash","arguments":"{\"command\":\"echo ok\"}"}
            }]}}}));
        entries.push(json!({"id":result_id,"turn_id":turn_id,
            "value":{"message":{"role":"tool","tool_call_id":call_id,"content":result}}}));
        entries.push(json!({"id":reply_id,"turn_id":turn_id,
            "value":{"message":{"role":"assistant","content":"done"}}}));
        turns.push(json!({"id":turn_id,"model_calls":2,
            "outcome":{"status":"completed","reply":"done"}}));
    }
    json!({"version":1,"session_id":"large-history","entries":entries,
        "turns":turns,"directory":null,"next_id":next_id})
    .to_string()
}

#[test]
fn tool_heavy_history_over_16_mib_restores() {
    let history = tool_heavy_history(225);
    let temp = tempfile::tempdir().unwrap();
    let prompt = temp.path().join("prompt.md");
    std::fs::write(&prompt, "Answer directly.").unwrap();
    let create = json!({"version":2,"session_id":"large-history","generation":"large-1", "prompt_path":prompt,
        "model":{"base_url":"http://127.0.0.1:1","model":"test","protocol":"chat_completions"},
        "restore":{"source":{"type":"v1","history":history},"input_receipts":[],"pending_inputs":[],"directory":null}}).to_string();
    assert!(create.len() > 16 * 1024 * 1024 && create.len() < 32 * 1024 * 1024);
    println!("tool-heavy create request: {} bytes", create.len());
    let input = CString::new(create).unwrap();
    let mut error = std::ptr::null_mut();
    let handle = unsafe { echo_agent_create(input.as_ptr(), &mut error) };
    assert!(
        !handle.is_null(),
        "{:?}",
        (!error.is_null()).then(|| owned(error))
    );
    struct Guard(*mut EchoAgent);
    impl Drop for Guard {
        fn drop(&mut self) {
            unsafe { echo_agent_destroy(self.0) }
        }
    }
    let handle = Guard(handle);
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        let poll = owned(unsafe { echo_agent_poll_events(handle.0, 1) });
        assert!(
            !poll["batches"]
                .as_array()
                .unwrap()
                .iter()
                .any(|batch| batch["kind"]["type"] == "initialization_failed"),
            "large history failed core validation"
        );
        if let Some(ready) = poll["batches"]
            .as_array()
            .unwrap()
            .iter()
            .find(|batch| batch["kind"]["type"] == "ready")
        {
            let restored = ready["checkpoint"]["history"].as_str().unwrap();
            assert!(restored.len() > 16 * 1024 * 1024 && restored.contains("call-224"));
            break;
        }
        assert!(
            Instant::now() < deadline,
            "large history did not finish restoring"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn ordinary_command_the_size_of_restored_history_is_still_rejected() {
    let history = tool_heavy_history(225);
    let command = json!({"version":2,"request_id":"large","command":{"type":"send_message",
        "input":{"client_message_id":"large","text":history}}})
    .to_string();
    assert!(command.len() > 16 * 1024 * 1024 && command.len() < 32 * 1024 * 1024);
    let input = CString::new(command).unwrap();
    assert_eq!(
        code(&owned(unsafe {
            echo_agent_request(std::ptr::null_mut(), input.as_ptr())
        })),
        "request_too_large"
    );
}

#[test]
fn live_handle_validates_nested_commands_and_returns_correlated_admission() {
    let temp = tempfile::tempdir().unwrap();
    let prompt = temp.path().join("prompt.md");
    std::fs::write(&prompt, "Answer directly.").unwrap();
    let create = CString::new(json!({"version":2,"session_id":"wire","generation":"wire-1", "prompt_path":prompt,
        "model":{"base_url":"http://127.0.0.1:1","model":"test","protocol":"responses"},
        "restore":{"source":{"type":"empty"},"input_receipts":[],"pending_inputs":[],"directory":null}}).to_string()).unwrap();
    let mut error = std::ptr::null_mut();
    let handle = unsafe { echo_agent_create(create.as_ptr(), &mut error) };
    assert!(!handle.is_null() && error.is_null());
    struct Guard(*mut EchoAgent);
    impl Drop for Guard {
        fn drop(&mut self) {
            unsafe { echo_agent_destroy(self.0) };
        }
    }
    let guard = Guard(handle);
    for command in [
        json!({"type":"unknown"}),
        json!({"type":"continue","extra":true}),
        json!({"type":"provide_directory"}),
        json!({"type":"send_message","input":{"text":"no ID"}}),
        json!({"type":"send_message","input":{"client_message_id":" ","text":"blank ID"}}),
        json!({"type":"send_message","input":{"client_message_id":"a","text":"ok","message_id":3}}),
        json!({"type":"acknowledge_checkpoint","checkpoint":{"generation":"wire-1","revision":0}}),
        json!({"type":"checkpoint_failed","checkpoint":{"generation":"","revision":1}}),
        json!({"type":"authorize_tool","checkpoint":{"generation":"wire-1","revision":1},"operation_id":0,"directory":"/tmp"}),
    ] {
        let input =
            CString::new(json!({"version":2,"request_id":"请求-一","command":command}).to_string())
                .unwrap();
        let reply = owned(unsafe { echo_agent_request(handle, input.as_ptr()) });
        assert_eq!(code(&reply), "invalid_request");
        assert_eq!(reply["request_id"], "请求-一");
    }
    for value in [
        json!({"version":2,"request_id":" ","command":{"type":"export_history"}}),
        json!({"version":2,"request_id":"r","command":{"type":"export_history"},"extra":true}),
    ] {
        let input = CString::new(value.to_string()).unwrap();
        assert_eq!(
            code(&owned(unsafe {
                echo_agent_request(handle, input.as_ptr())
            })),
            "invalid_request"
        );
    }
    let command = json!({"version":2,"request_id":"请求-二","command":{"type":"send_message",
        "input":{"client_message_id":"ui","text":format!("你好\\\"\0{}", "🌱".repeat(32 * 1024))}}});
    let input = CString::new(command.to_string()).unwrap();
    // Specialized entrypoints reject the wrong nested type before admission.
    assert_eq!(
        code(&owned(unsafe { echo_agent_submit(handle, input.as_ptr()) })),
        "invalid_request"
    );
    assert_eq!(
        code(&owned(unsafe { echo_agent_steer(handle, input.as_ptr()) })),
        "invalid_request"
    );
    assert_eq!(
        code(&owned(unsafe {
            echo_agent_provide_directory(handle, input.as_ptr())
        })),
        "invalid_request"
    );
    let reply = owned(unsafe { echo_agent_request(handle, input.as_ptr()) });
    assert_eq!(reply["admission"]["status"], "queued");
    assert_eq!(reply["request_id"], "请求-二");
    // No checkpoint has been acknowledged, so this cannot contact the model.
    let buffer = unsafe { echo_agent_poll_events(handle, usize::MAX) };
    drop(guard);
    assert_eq!(owned(buffer)["version"], 2);
}
