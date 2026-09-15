use axum::{Json, Router, routing::post};
use echo_agent::*;
use serde_json::{Value, json};
use std::{
    ffi::{CStr, CString, c_char},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
use tokio::sync::Notify;

struct Handle(*mut EchoAgent);
impl Drop for Handle {
    fn drop(&mut self) {
        unsafe { echo_agent_destroy(self.0) }
    }
}
fn owned(pointer: *mut c_char) -> Value {
    assert!(!pointer.is_null());
    let result =
        unsafe { serde_json::from_str(CStr::from_ptr(pointer).to_str().unwrap()).unwrap() };
    unsafe { echo_agent_string_free(pointer) };
    result
}
fn create(base: &str, prompt: &std::path::Path, protocol: &str, history: Option<Value>) -> Handle {
    let request = CString::new(
        json!({"version":2,"session_id":"session-一","generation":format!("generation-{}", next_id()),"prompt_path":prompt,
        "model":{"base_url":base,"model":"test","protocol":protocol},
        "restore":{"source": history.map(|h| json!({"type":"v1","history":h.to_string()})).unwrap_or(json!({"type":"empty"})), "directory":null,"input_receipts":[],"pending_inputs":[]}})
        .to_string(),
    )
    .unwrap();
    let mut error = std::ptr::null_mut();
    let start = Instant::now();
    let handle = unsafe { echo_agent_create(request.as_ptr(), &mut error) };
    assert!(start.elapsed() < Duration::from_millis(250));
    assert!(
        !handle.is_null(),
        "{:?}",
        (!error.is_null()).then(|| owned(error))
    );
    Handle(handle)
}
fn next_id() -> usize {
    static ID: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
    ID.fetch_add(1, std::sync::atomic::Ordering::SeqCst)
}
fn send(handle: &Handle, kind: &str, fields: Value) -> Value {
    let mut request = fields;
    request["type"] = json!(kind);
    if ["submit", "steer", "send_message"].contains(&kind) && request.get("input").is_none() {
        request["input"] =
            json!({"client_message_id":format!("ui-{}",next_id()), "text":request["text"]});
        request.as_object_mut().unwrap().remove("text");
    }
    let request =
        CString::new(json!({"version":2,"request_id":kind,"command":request}).to_string()).unwrap();
    owned(unsafe {
        match kind {
            "submit" => echo_agent_submit(handle.0, request.as_ptr()),
            "steer" => echo_agent_steer(handle.0, request.as_ptr()),
            "provide_directory" => echo_agent_provide_directory(handle.0, request.as_ptr()),
            _ => echo_agent_request(handle.0, request.as_ptr()),
        }
    })
}
fn accepted(handle: &Handle, kind: &str, fields: Value) {
    assert_eq!(send(handle, kind, fields)["admission"]["status"], "queued");
}
fn poll(handle: &Handle) -> Vec<Value> {
    let start = Instant::now();
    let value = owned(unsafe { echo_agent_poll_events(handle.0, 64) });
    assert!(start.elapsed() < Duration::from_millis(250));
    value["batches"].as_array().unwrap().clone()
}
async fn until(handle: &Handle, predicate: impl Fn(&Value) -> bool) -> Vec<Value> {
    collect_until(handle, true, predicate).await
}
async fn collect_until(
    handle: &Handle,
    ack: bool,
    predicate: impl Fn(&Value) -> bool,
) -> Vec<Value> {
    let start = Instant::now();
    let mut all = Vec::new();
    loop {
        let frames = poll(handle);
        if ack {
            for frame in &frames {
                acknowledge(handle, frame);
            }
        }
        all.extend(frames);
        if all.iter().any(&predicate) {
            return all;
        }
        assert!(
            start.elapsed() < Duration::from_secs(8),
            "timed out: {all:#?}"
        );
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
}
fn acknowledge(handle: &Handle, frame: &Value) {
    if frame["checkpoint"].is_object() {
        accepted(
            handle,
            "acknowledge_checkpoint",
            json!({"checkpoint":frame["checkpoint"]["id"]}),
        );
    }
}
fn authorize(handle: &Handle, frame: &Value) {
    accepted(
        handle,
        "authorize_tool",
        json!({
            "checkpoint":frame["checkpoint"]["id"],
            "operation_id":frame["kind"]["operation_id"],
            "directory":frame["kind"]["directory"],
        }),
    );
}
fn history(frames: &[Value]) -> Value {
    let raw = frames
        .iter()
        .rev()
        .find_map(|f| f["checkpoint"]["history"].as_str())
        .unwrap();
    serde_json::from_str(raw).unwrap()
}
fn event(frame: &Value, kind: &str) -> bool {
    frame["events"]
        .as_array()
        .is_some_and(|events| events.iter().any(|event| event["kind"]["type"] == kind))
}
async fn shutdown() {
    let start = Instant::now();
    while echo_agent_active_sessions() != 0 {
        assert!(start.elapsed() < Duration::from_secs(5));
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
}

#[derive(Clone)]
struct Server {
    requests: Arc<Mutex<Vec<Value>>>,
    replies: Arc<Mutex<std::collections::VecDeque<Value>>>,
    entered: Arc<Notify>,
    release: Arc<Notify>,
    block: Arc<std::sync::atomic::AtomicBool>,
}
impl Server {
    fn reply(&self, value: Value) {
        self.replies.lock().unwrap().push_back(value);
    }
}
fn answer(protocol: &str, text: &str) -> Value {
    if protocol == "responses" {
        json!({"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":text}]}]})
    } else {
        json!({"choices":[{"message":{"role":"assistant","content":text},"finish_reason":"stop"}]})
    }
}
fn tool(protocol: &str, command: &str) -> Value {
    let args = json!({"command":command}).to_string();
    if protocol == "responses" {
        json!({"status":"completed","output":[{"type":"function_call","call_id":"call_1","name":"bash","arguments":args}]})
    } else {
        json!({"choices":[{"message":{"role":"assistant","tool_calls":[{"id":"call_1","type":"function","function":{"name":"bash","arguments":args}}]},"finish_reason":"tool_calls"}]})
    }
}

// Sequential scenarios make process-count assertions meaningful. All HTTP traffic
// stays on loopback; tools touch only the test's temporary directory.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn c_abi_lifecycle() {
    let server = Server {
        requests: Default::default(),
        replies: Default::default(),
        entered: Arc::new(Notify::new()),
        release: Arc::new(Notify::new()),
        block: Default::default(),
    };
    let service = server.clone();
    let router = Router::new().route(
        "/{*path}",
        post(move |Json(body): Json<Value>| {
            let state = service.clone();
            async move {
                state.requests.lock().unwrap().push(body);
                state.entered.notify_one();
                let reply = state.replies.lock().unwrap().pop_front().unwrap();
                if state.block.swap(false, std::sync::atomic::Ordering::SeqCst) {
                    state.release.notified().await;
                }
                Json(reply)
            }
        }),
    );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let http = tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    let temp = tempfile::tempdir().unwrap();
    let prompt = temp.path().join("conversation.md");
    std::fs::write(&prompt, "Answer directly or use bash.").unwrap();

    // Invalid ABI input, safe null operations and independent allocated errors.
    let mut error = std::ptr::null_mut();
    assert!(unsafe { echo_agent_create(std::ptr::null(), &mut error) }.is_null());
    assert_eq!(owned(error)["admission"]["status"], "rejected");
    unsafe {
        echo_agent_destroy(std::ptr::null_mut());
        echo_agent_cancel(std::ptr::null_mut());
        echo_agent_string_free(std::ptr::null_mut());
    }
    assert_eq!(
        owned(unsafe { echo_agent_poll_events(std::ptr::null_mut(), 1) })["admission"]["status"],
        "rejected"
    );

    // Real C v2 save gates: neither a queued input nor a tool lease is a save.
    for fail_save in [false, true] {
        let handle = create(&base, &prompt, "chat_completions", None);
        let ready = collect_until(&handle, false, |f| f["kind"]["type"] == "ready").await;
        let before = server.requests.lock().unwrap().len();
        accepted(
            &handle,
            "provide_directory",
            json!({"directory":temp.path()}),
        );
        let input = json!({"input":{"client_message_id":"stable-一", "text":"save first 🌱"}});
        accepted(&handle, "send_message", input.clone());
        let frames = collect_until(&handle, false, |f| {
            f["kind"]["request_id"] == "send_message"
        })
        .await;
        let receipt = frames
            .iter()
            .find(|f| f["kind"]["request_id"] == "send_message")
            .unwrap()["kind"]["result"]["input_receipt"]
            .clone();
        // Re-delivery uses the same IDs; identical text with another ID remains separate.
        accepted(&handle, "send_message", input.clone());
        let duplicate = collect_until(&handle, false, |f| {
            f["kind"]["request_id"] == "send_message"
        })
        .await;
        assert_eq!(
            duplicate.last().unwrap()["kind"]["result"]["input_receipt"],
            receipt
        );
        accepted(
            &handle,
            "send_message",
            json!({"input":{"client_message_id":"stable-二", "text":"save first 🌱"}}),
        );
        let second = collect_until(&handle, false, |f| {
            f["kind"]["request_id"] == "send_message"
        })
        .await;
        assert_ne!(
            second.last().unwrap()["kind"]["result"]["input_receipt"]["message_id"],
            receipt["message_id"]
        );
        accepted(
            &handle,
            "send_message",
            json!({"input":{"client_message_id":"stable-一", "text":"conflict"}}),
        );
        let conflict = collect_until(&handle, false, |f| {
            f["kind"]["request_id"] == "send_message"
        })
        .await;
        assert_eq!(
            conflict.last().unwrap()["kind"]["result"]["error"]["code"],
            "client_message_conflict"
        );
        acknowledge(&handle, ready.last().unwrap()); // Old saved waterline cannot dispatch this input.
        tokio::time::sleep(Duration::from_millis(40)).await;
        assert_eq!(server.requests.lock().unwrap().len(), before);
        // The largest u64 revision survives decoding and is rejected as stale,
        // rather than being rounded or truncated by the wire adapter.
        let mut future = second.last().unwrap()["checkpoint"]["id"].clone();
        future["revision"] = json!(u64::MAX);
        accepted(
            &handle,
            "acknowledge_checkpoint",
            json!({"checkpoint":future}),
        );
        let rejected = collect_until(&handle, false, |f| {
            f["kind"]["result"]["error"]["code"] == "stale_checkpoint"
        })
        .await;
        assert!(rejected.iter().all(|f| f["checkpoint"].is_null()));
        acknowledge(&handle, second.last().unwrap());
        let budget = collect_until(&handle, false, |f| event(f, "model_started")).await;
        tokio::time::sleep(Duration::from_millis(40)).await;
        assert_eq!(server.requests.lock().unwrap().len(), before); // Budget checkpoint is another gate.
        server.reply(tool("chat_completions", "printf durable > gated.txt"));
        acknowledge(&handle, budget.last().unwrap());
        let proposal = collect_until(&handle, false, |f| f["kind"]["type"] == "tool_pending").await;
        let proposal = proposal
            .iter()
            .find(|f| f["kind"]["type"] == "tool_pending")
            .unwrap();
        authorize(&handle, proposal); // Lease granted before save acknowledgement.
        tokio::time::sleep(Duration::from_millis(40)).await;
        assert!(!temp.path().join("gated.txt").exists());
        let mut wrong_generation = proposal["checkpoint"]["id"].clone();
        wrong_generation["generation"] = json!("previous-handle");
        accepted(
            &handle,
            "acknowledge_checkpoint",
            json!({"checkpoint":wrong_generation}),
        );
        collect_until(&handle, false, |f| {
            f["kind"]["result"]["error"]["code"] == "stale_checkpoint"
        })
        .await;
        assert!(!temp.path().join("gated.txt").exists());
        acknowledge(&handle, proposal);
        let result = collect_until(&handle, false, |f| event(f, "tool_result")).await;
        assert_eq!(
            std::fs::read_to_string(temp.path().join("gated.txt")).unwrap(),
            "durable"
        );
        tokio::time::sleep(Duration::from_millis(40)).await;
        assert_eq!(server.requests.lock().unwrap().len(), before + 1); // Result not saved => no next query.
        if fail_save {
            // Saturate normal admission and event output first. Persistence
            // failure still enters through its independent terminal latch.
            let mut full = false;
            for _ in 0..160 {
                full |= send(&handle, "export_history", json!({}))["admission"]["error"]["code"]
                    == "queue_full";
                tokio::time::sleep(Duration::from_millis(1)).await;
            }
            assert!(full);
            accepted(
                &handle,
                "checkpoint_failed",
                json!({"checkpoint":result.last().unwrap()["checkpoint"]["id"]}),
            );
            let stopped = collect_until(&handle, false, |f| f["kind"]["type"] == "cancelled").await;
            assert!(
                stopped
                    .iter()
                    .any(|f| f["kind"]["result"]["error"]["code"] == "persistence_failed")
            );
            assert_eq!(
                send(&handle, "send_message", input)["admission"]["error"]["code"],
                "persistence_failed"
            );
            assert_eq!(server.requests.lock().unwrap().len(), before + 1);
        } else {
            // Stop also works while waiting to persist a result; the known
            // result remains intact and cannot accidentally dispatch a model.
            unsafe { echo_agent_cancel(handle.0) };
            let stopped = collect_until(&handle, false, |f| f["kind"]["type"] == "cancelled").await;
            assert!(stopped.iter().any(|f| {
                f["checkpoint"]["history"]
                    .as_str()
                    .is_some_and(|h| h.contains("gated.txt"))
            }));
            assert_eq!(server.requests.lock().unwrap().len(), before + 1);
        }
        drop(handle);
        shutdown().await;
        std::fs::remove_file(temp.path().join("gated.txt")).unwrap();
    }

    for protocol in ["chat_completions", "responses"] {
        let handle = create(&base, &prompt, protocol, None);
        until(&handle, |f| f["kind"]["type"] == "ready").await;
        server.reply(answer(protocol, "你好 🌱"));
        accepted(&handle, "submit", json!({"text":"hello"}));
        let finished = until(&handle, |f| event(f, "finished")).await;
        assert!(finished.iter().any(|f| f.to_string().contains("你好 🌱")));
        let history = history(&finished);
        drop(handle);
        shutdown().await;
        let handle = create(&base, &prompt, protocol, Some(history));
        until(&handle, |f| f["kind"]["type"] == "ready").await;
        let extra = poll(&handle);
        assert!(
            extra
                .iter()
                .all(|f| f["checkpoint"].is_null() && f["events"].as_array().unwrap().is_empty())
        ); // only ack receipts, never auto-execution

        server.reply(tool(
            protocol,
            "printf 'changed' > result.txt; cat result.txt",
        ));
        server.reply(answer(protocol, "done"));
        accepted(&handle, "submit", json!({"text":"modify"}));
        until(&handle, |f| event(f, "directory_required")).await;
        assert!(!temp.path().join("result.txt").exists());
        accepted(
            &handle,
            "provide_directory",
            json!({"directory":temp.path()}),
        );
        let frames = until(&handle, |f| f["kind"]["type"] == "tool_pending").await;
        assert!(!temp.path().join("result.txt").exists());
        authorize(&handle, frames.last().unwrap());
        let frames = until(&handle, |f| event(f, "finished")).await;
        assert_eq!(
            std::fs::read_to_string(temp.path().join("result.txt")).unwrap(),
            "changed"
        );
        assert!(frames.iter().any(|f| event(f, "tool_result")));
        {
            let requests = server.requests.lock().unwrap();
            assert!(requests.last().unwrap().to_string().contains("changed"));
            assert!(requests.last().unwrap().to_string().contains("hello"));
        }
        std::fs::remove_file(temp.path().join("result.txt")).unwrap();
        drop(handle);
        shutdown().await;
    }

    // Fixed v1 archives survive a protocol switch. The provider-specific
    // reasoning stays in storage but is sent only to the Responses endpoint.
    for protocol in ["chat_completions", "responses"] {
        let fixture: Value = serde_json::from_str(include_str!(
            "../../tests/fixtures/agent-v1/responses-tool.json"
        ))
        .unwrap();
        let requests_before = server.requests.lock().unwrap().len();
        let handle = create(&base, &prompt, protocol, Some(fixture.clone()));
        let ready = until(&handle, |f| f["kind"]["type"] == "ready").await;
        assert_eq!(history(&ready), fixture);
        accepted(&handle, "export_history", json!({}));
        until(&handle, |f| f["kind"]["request_id"] == "export_history").await;
        assert_eq!(server.requests.lock().unwrap().len(), requests_before);
        server.reply(answer(protocol, "restored context"));
        accepted(&handle, "submit", json!({"text":"继续聊 🌱"}));
        let frames = until(&handle, |f| event(f, "finished")).await;
        assert!(
            history(&frames)
                .to_string()
                .contains("synthetic-opaque-fixture")
        );
        let body = server.requests.lock().unwrap().last().unwrap().clone();
        assert!(body.to_string().contains("fixture-output"));
        assert_eq!(
            body.to_string().contains("synthetic-opaque-fixture"),
            protocol == "responses"
        );
        assert_eq!(body["model"], "test");
        drop(handle);
        shutdown().await;
    }

    // A corrupt but syntactically valid v1 archive fails during initialization
    // and never reaches the model or tool dispatcher.
    let requests_before = server.requests.lock().unwrap().len();
    let history = serde_json::from_str(include_str!(
        "../../tests/fixtures/agent-v1/invalid-duplicate-id.json"
    ))
    .unwrap();
    let handle = create(&base, &prompt, "chat_completions", Some(history));
    let frames = until(&handle, |f| f["kind"]["type"] == "initialization_failed").await;
    assert!(!frames.iter().any(|f| f["kind"]["type"] == "ready"));
    assert_eq!(
        frames.last().unwrap()["kind"]["error"]["code"],
        "invalid_history"
    );
    assert_eq!(server.requests.lock().unwrap().len(), requests_before);
    shutdown().await; // Failed initialization completes even while the C handle remains alive.
    assert_eq!(
        owned(unsafe { echo_agent_poll_events(handle.0, 1) })["closed"],
        true
    );
    drop(handle);

    let private_prompt = temp.path().join("private-missing-prompt.md");
    let handle = create(&base, &private_prompt, "responses", None);
    let frames = until(&handle, |f| f["kind"]["type"] == "initialization_failed").await;
    assert_eq!(
        frames.last().unwrap()["kind"]["error"]["code"],
        "initialization_failed"
    );
    assert!(
        !frames
            .last()
            .unwrap()
            .to_string()
            .contains("private-missing-prompt")
    );
    drop(handle);
    shutdown().await;

    // Steering during a held model request invalidates its proposed command.
    let handle = create(&base, &prompt, "chat_completions", None);
    until(&handle, |f| f["kind"]["type"] == "ready").await;
    server
        .block
        .store(true, std::sync::atomic::Ordering::SeqCst);
    server.reply(tool("chat_completions", "touch must-not-exist"));
    server.reply(answer("chat_completions", "new answer"));
    accepted(&handle, "submit", json!({"text":"old"}));
    until(&handle, |f| event(f, "model_started")).await;
    accepted(&handle, "steer", json!({"text":"new"}));
    until(&handle, |f| event(f, "steering_queued")).await;
    server.release.notify_one();
    let frames = until(&handle, |f| event(f, "finished")).await;
    assert!(
        frames
            .iter()
            .any(|f| f.to_string().contains("not_executed"))
    );
    assert!(!frames.iter().any(|f| f["kind"]["type"] == "tool_pending"));
    drop(handle);
    shutdown().await;

    // A follow-up at the host's persistence/lock gate rejects stale permission.
    let handle = create(&base, &prompt, "chat_completions", None);
    until(&handle, |f| f["kind"]["type"] == "ready").await;
    accepted(
        &handle,
        "provide_directory",
        json!({"directory":temp.path()}),
    );
    server.reply(tool("chat_completions", "touch obsolete"));
    server.reply(answer("chat_completions", "reconsidered"));
    accepted(&handle, "submit", json!({"text":"old tool"}));
    let frames = until(&handle, |f| f["kind"]["type"] == "tool_pending").await;
    let stale = frames.last().unwrap().clone();
    accepted(&handle, "steer", json!({"text":"do not execute"}));
    // Let the serial runner process steering before delivering obsolete permission.
    until(&handle, |f| f["kind"]["request_id"] == "steer").await;
    authorize(&handle, &stale);
    let frames = until(&handle, |f| event(f, "finished")).await;
    assert!(
        frames
            .iter()
            .any(|f| f["kind"]["request_id"] == "authorize_tool"
                && f["kind"]["result"]["error"]["code"] == "stale_operation")
    );
    assert!(!temp.path().join("obsolete").exists());
    drop(handle);
    shutdown().await;

    // A known completed tool result survives cancellation behind a full queue.
    let handle = create(&base, &prompt, "chat_completions", None);
    until(&handle, |f| f["kind"]["type"] == "ready").await;
    accepted(
        &handle,
        "provide_directory",
        json!({"directory":temp.path()}),
    );
    server.reply(tool(
        "chat_completions",
        "while [ ! -e release ]; do sleep 0.01; done; printf preserved-output",
    ));
    accepted(&handle, "submit", json!({"text":"wait for release"}));
    let frames = until(&handle, |f| f["kind"]["type"] == "tool_pending").await;
    authorize(&handle, frames.last().unwrap());
    for _ in 0..160 {
        send(&handle, "export_history", json!({}));
        tokio::time::sleep(Duration::from_millis(1)).await;
    }
    std::fs::write(temp.path().join("release"), "go").unwrap();
    tokio::time::sleep(Duration::from_millis(150)).await;
    unsafe { echo_agent_cancel(handle.0) };
    let frames = collect_until(&handle, false, |f| f["kind"]["type"] == "cancelled").await;
    assert!(
        frames
            .iter()
            .any(|f| event(f, "tool_result") && f.to_string().contains("preserved-output"))
    );
    drop(handle);
    shutdown().await;

    // Tool cancellation and destruction kill a real shell and its child.
    for destroy in [false, true] {
        let handle = create(&base, &prompt, "chat_completions", None);
        until(&handle, |f| f["kind"]["type"] == "ready").await;
        accepted(
            &handle,
            "provide_directory",
            json!({"directory":temp.path()}),
        );
        server.reply(tool(
            "chat_completions",
            "echo $$ > shell.pid; sleep 20 & echo $! > child.pid; wait; touch survived",
        ));
        accepted(&handle, "submit", json!({"text":"work"}));
        let frames = until(&handle, |f| f["kind"]["type"] == "tool_pending").await;
        authorize(&handle, frames.last().unwrap());
        let start = Instant::now();
        while !temp.path().join("child.pid").exists() {
            assert!(start.elapsed() < Duration::from_secs(5));
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        // Fill the event queue without polling, then saturate command admission.
        let mut rejected = false;
        for _ in 0..160 {
            rejected |=
                send(&handle, "export_history", json!({}))["admission"]["status"] == "rejected";
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
        assert!(rejected);
        let start = Instant::now();
        if destroy {
            drop(handle);
        } else {
            unsafe { echo_agent_cancel(handle.0) };
            assert!(start.elapsed() < Duration::from_millis(100));
            // Stop must clean up even before the full output queue is drained.
            tokio::time::sleep(Duration::from_millis(100)).await;
            let pid: i32 = std::fs::read_to_string(temp.path().join("shell.pid"))
                .unwrap()
                .trim()
                .parse()
                .unwrap();
            assert!(
                rustix::process::kill_process(
                    rustix::process::Pid::from_raw(pid).unwrap(),
                    rustix::process::Signal::CONT
                )
                .is_err()
            );
            let frames = collect_until(&handle, false, |f| f["kind"]["type"] == "cancelled").await;
            assert!(frames.iter().any(|f| event(f, "stopping")));
            assert!(frames.iter().any(|f| event(f, "finished")));
            assert!(frames.iter().any(|f| f.to_string().contains("unknown")));
            drop(handle);
        }
        assert!(start.elapsed() < Duration::from_secs(3));
        shutdown().await;
        for name in ["shell.pid", "child.pid"] {
            let pid: i32 = std::fs::read_to_string(temp.path().join(name))
                .unwrap()
                .trim()
                .parse()
                .unwrap();
            let start = Instant::now();
            while rustix::process::kill_process(
                rustix::process::Pid::from_raw(pid).unwrap(),
                rustix::process::Signal::CONT,
            )
            .is_ok()
            {
                assert!(
                    start.elapsed() < Duration::from_secs(3),
                    "process {pid} survived"
                );
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
            std::fs::remove_file(temp.path().join(name)).unwrap();
        }
        assert!(!temp.path().join("survived").exists());
    }

    // Destroy in flight, and repeat create/poll/free/destroy with buffers surviving handles.
    server
        .block
        .store(true, std::sync::atomic::Ordering::SeqCst);
    server.reply(answer("chat_completions", "late"));
    let handle = create(&base, &prompt, "chat_completions", None);
    until(&handle, |f| f["kind"]["type"] == "ready").await;
    accepted(&handle, "submit", json!({"text":"wait"}));
    until(&handle, |f| event(f, "model_started")).await;
    drop(handle);
    shutdown().await;
    server.release.notify_one();
    for _ in 0..100 {
        let handle = create(&base, &prompt, "chat_completions", None);
        let pointer = unsafe { echo_agent_poll_events(handle.0, 1) };
        drop(handle);
        assert_eq!(owned(pointer)["version"], 2);
    }
    shutdown().await;
    http.abort();
}
