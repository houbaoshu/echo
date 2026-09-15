//! Exercise the actual C parser, not a parallel serialization specification.
use echo_agent::*;
use serde_json::{Value, json};
use std::ffi::{CStr, CString, c_char};

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
    let huge = json!({"version":2,"padding":"🌱".repeat(4 * 1024 * 1024)}).to_string();
    assert_eq!(code(&rejected_create(&huge)), "request_too_large");
    let input = CString::new(huge).unwrap();
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
