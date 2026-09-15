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
        json!({"version":1,"session_id":"session-一","prompt_path":prompt,
        "model":{"base_url":base,"model":"test","protocol":protocol}, "history":history})
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
fn send(handle: &Handle, kind: &str, fields: Value) -> Value {
    let mut request = fields;
    request["version"] = json!(1);
    request["request_id"] = json!(kind);
    request["type"] = json!(kind);
    let request = CString::new(request.to_string()).unwrap();
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
    assert_eq!(send(handle, kind, fields)["accepted"], true);
}
fn poll(handle: &Handle) -> Vec<Value> {
    let start = Instant::now();
    let value = owned(unsafe { echo_agent_poll_events(handle.0, 64) });
    assert!(start.elapsed() < Duration::from_millis(250));
    value["batches"].as_array().unwrap().clone()
}
async fn until(handle: &Handle, predicate: impl Fn(&Value) -> bool) -> Vec<Value> {
    let start = Instant::now();
    let mut all = Vec::new();
    loop {
        all.extend(poll(handle));
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
    assert_eq!(owned(error)["accepted"], false);
    unsafe {
        echo_agent_destroy(std::ptr::null_mut());
        echo_agent_cancel(std::ptr::null_mut());
        echo_agent_string_free(std::ptr::null_mut());
    }
    assert_eq!(
        owned(unsafe { echo_agent_poll_events(std::ptr::null_mut(), 1) })["accepted"],
        false
    );

    for protocol in ["chat_completions", "responses"] {
        let handle = create(&base, &prompt, protocol, None);
        until(&handle, |f| f["type"] == "ready").await;
        server.reply(answer(protocol, "你好 🌱"));
        accepted(&handle, "submit", json!({"text":"hello"}));
        let finished = until(&handle, |f| event(f, "finished")).await;
        assert!(finished.iter().any(|f| f.to_string().contains("你好 🌱")));
        let history = finished.last().unwrap()["history"].clone();
        drop(handle);
        shutdown().await;
        let handle = create(&base, &prompt, protocol, Some(history));
        until(&handle, |f| f["type"] == "ready").await;
        assert!(poll(&handle).is_empty()); // import never auto-executes

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
        let frames = until(&handle, |f| f["type"] == "tool_pending").await;
        let id = frames.last().unwrap()["operation_id"].clone();
        assert!(!temp.path().join("result.txt").exists());
        accepted(&handle, "start_tool", json!({"operation_id":id}));
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

    // Steering during a held model request invalidates its proposed command.
    let handle = create(&base, &prompt, "chat_completions", None);
    until(&handle, |f| f["type"] == "ready").await;
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
    assert!(!frames.iter().any(|f| f["type"] == "tool_pending"));
    drop(handle);
    shutdown().await;

    // A follow-up at the host's persistence/lock gate rejects stale permission.
    let handle = create(&base, &prompt, "chat_completions", None);
    until(&handle, |f| f["type"] == "ready").await;
    accepted(
        &handle,
        "provide_directory",
        json!({"directory":temp.path()}),
    );
    server.reply(tool("chat_completions", "touch obsolete"));
    server.reply(answer("chat_completions", "reconsidered"));
    accepted(&handle, "submit", json!({"text":"old tool"}));
    let frames = until(&handle, |f| f["type"] == "tool_pending").await;
    let stale = frames.last().unwrap()["operation_id"].clone();
    accepted(&handle, "steer", json!({"text":"do not execute"}));
    accepted(&handle, "start_tool", json!({"operation_id":stale}));
    let frames = until(&handle, |f| event(f, "finished")).await;
    assert!(
        frames
            .iter()
            .any(|f| f["request_id"] == "start_tool" && f["error"].is_string())
    );
    assert!(!temp.path().join("obsolete").exists());
    drop(handle);
    shutdown().await;

    // A known completed tool result survives cancellation behind a full queue.
    let handle = create(&base, &prompt, "chat_completions", None);
    until(&handle, |f| f["type"] == "ready").await;
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
    let frames = until(&handle, |f| f["type"] == "tool_pending").await;
    accepted(
        &handle,
        "start_tool",
        json!({"operation_id":frames.last().unwrap()["operation_id"]}),
    );
    for _ in 0..160 {
        send(&handle, "export_history", json!({}));
        tokio::time::sleep(Duration::from_millis(1)).await;
    }
    std::fs::write(temp.path().join("release"), "go").unwrap();
    tokio::time::sleep(Duration::from_millis(150)).await;
    unsafe { echo_agent_cancel(handle.0) };
    let frames = until(&handle, |f| f["type"] == "cancelled").await;
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
        until(&handle, |f| f["type"] == "ready").await;
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
        let frames = until(&handle, |f| f["type"] == "tool_pending").await;
        accepted(
            &handle,
            "start_tool",
            json!({"operation_id":frames.last().unwrap()["operation_id"]}),
        );
        let start = Instant::now();
        while !temp.path().join("child.pid").exists() {
            assert!(start.elapsed() < Duration::from_secs(5));
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        // Fill the event queue without polling, then saturate command admission.
        let mut rejected = false;
        for _ in 0..160 {
            rejected |= send(&handle, "export_history", json!({}))["accepted"] == false;
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
            let frames = until(&handle, |f| f["type"] == "cancelled").await;
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
    until(&handle, |f| f["type"] == "ready").await;
    accepted(&handle, "submit", json!({"text":"wait"}));
    until(&handle, |f| event(f, "model_started")).await;
    drop(handle);
    shutdown().await;
    server.release.notify_one();
    for _ in 0..100 {
        let handle = create(&base, &prompt, "chat_completions", None);
        let pointer = unsafe { echo_agent_poll_events(handle.0, 1) };
        drop(handle);
        assert_eq!(owned(pointer)["version"], 1);
    }
    shutdown().await;
    http.abort();
}
