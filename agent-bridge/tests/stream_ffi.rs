//! Streamed model text crosses the C ABI in poll results, outside batches and checkpoints.
mod common;

use axum::{Router, body::Body, http::header::CONTENT_TYPE, response::IntoResponse, routing::post};
use common::{Handle, owned, wait_for_shutdown};
use echo_agent::*;
use serde_json::{Value, json};
use std::{
    ffi::CString,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
use tokio::sync::mpsc;

fn request(handle: &Handle, command: Value) {
    let request =
        CString::new(json!({"version":2,"request_id":"r","command":command}).to_string()).unwrap();
    let reply = owned(unsafe { echo_agent_request(handle.0, request.as_ptr()) });
    assert_eq!(reply["admission"]["status"], "queued", "{reply}");
}
/// Polls once, acknowledging checkpoints, and returns the whole poll result.
fn poll(handle: &Handle) -> Value {
    let value = owned(unsafe { echo_agent_poll_events(handle.0, 64) });
    for batch in value["batches"].as_array().unwrap() {
        if batch["checkpoint"].is_object() {
            request(
                handle,
                json!({"type":"acknowledge_checkpoint","checkpoint":batch["checkpoint"]["id"]}),
            );
        }
    }
    value
}
async fn poll_until(handle: &Handle, predicate: impl Fn(&Value) -> bool) -> Vec<Value> {
    let start = Instant::now();
    let mut polls = Vec::new();
    loop {
        let value = poll(handle);
        let done = predicate(&value);
        polls.push(value);
        if done {
            return polls;
        }
        assert!(
            start.elapsed() < Duration::from_secs(8),
            "timed out: {polls:#?}"
        );
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
}
fn chunk(delta: Value, finish: Option<&str>) -> String {
    format!(
        "data: {}\n\n",
        json!({"choices":[{"index":0,"delta":delta,"finish_reason":finish}]})
    )
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn poll_carries_coalesced_stream_text_outside_checkpoints() {
    let (tx, rx) = mpsc::unbounded_channel::<String>();
    let receiver = Arc::new(Mutex::new(Some(rx)));
    let requests = Arc::new(Mutex::new(0));
    let router = Router::new().route(
        "/{*path}",
        post({
            let (receiver, requests) = (receiver.clone(), requests.clone());
            move || async move {
                *requests.lock().unwrap() += 1;
                let rx = receiver.lock().unwrap().take().unwrap();
                let chunks = futures_util::stream::unfold(rx, |mut rx| async move {
                    let chunk = rx.recv().await?;
                    Some((Ok::<_, std::io::Error>(chunk), rx))
                });
                (
                    [(CONTENT_TYPE, "text/event-stream")],
                    Body::from_stream(chunks),
                )
                    .into_response()
            }
        }),
    );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}/v1", listener.local_addr().unwrap());
    tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    let prompt = tempfile::NamedTempFile::new().unwrap();
    std::fs::write(prompt.path(), "Chat.").unwrap();
    let create = CString::new(
        json!({"version":2,"session_id":"stream","generation":"stream-1","prompt_path":prompt.path(),
            "model":{"base_url":base,"model":"test","protocol":"chat_completions"},
            "restore":{"source":{"type":"empty"},"directory":null,"input_receipts":[],"pending_inputs":[]}})
        .to_string(),
    )
    .unwrap();
    let mut error = std::ptr::null_mut();
    let handle = Handle(unsafe { echo_agent_create(create.as_ptr(), &mut error) });
    assert!(!handle.0.is_null());
    poll_until(&handle, |poll| {
        poll["batches"]
            .as_array()
            .unwrap()
            .iter()
            .any(|b| b["kind"]["type"] == "ready")
    })
    .await;
    request(
        &handle,
        json!({"type":"send_message","input":{"client_message_id":"ui-1","text":"hi"}}),
    );
    poll_until(&handle, |_| *requests.lock().unwrap() == 1).await;

    tx.send(chunk(json!({"role":"assistant","content":"He"}), None))
        .unwrap();
    tx.send(chunk(json!({"content":"l"}), None)).unwrap();
    let polls = poll_until(&handle, |poll| poll["stream"]["text"] == "Hel").await;
    let stream = &polls.last().unwrap()["stream"];
    assert_eq!(stream["tool_call"], false);
    assert!(
        stream["operation_id"].as_u64().unwrap() > 0 && stream["turn_id"].as_u64().unwrap() > 0
    );
    assert!(
        polls
            .iter()
            .all(|poll| poll["stream"]["text"] != "He"
                || poll["batches"].as_array().unwrap().is_empty()),
        "stream text never rides on checkpoint batches"
    );
    let unchanged = poll(&handle);
    assert!(
        unchanged.get("stream").is_none(),
        "an unchanged stream is omitted: {unchanged}"
    );

    tx.send(chunk(json!({"content":"lo"}), None)).unwrap();
    let polls = poll_until(&handle, |poll| poll["stream"]["text"] == "Hello").await;
    assert_eq!(
        polls.last().unwrap()["stream"]["operation_id"],
        stream["operation_id"]
    );
    tx.send(chunk(json!({}), Some("stop"))).unwrap();
    drop(tx);
    let polls = poll_until(&handle, |poll| {
        poll["batches"].as_array().unwrap().iter().any(|b| {
            b["events"]
                .as_array()
                .unwrap()
                .iter()
                .any(|e| e["kind"]["type"] == "finished")
        })
    })
    .await;
    let finished = polls
        .iter()
        .flat_map(|poll| poll["batches"].as_array().unwrap())
        .flat_map(|b| b["events"].as_array().unwrap())
        .find(|e| e["kind"]["type"] == "finished")
        .unwrap();
    assert_eq!(finished["kind"]["outcome"]["reply"], "Hello");
    drop(handle);
    wait_for_shutdown().await;
}
