//! Probe-only C ABI over Mini Agent's production `LocalConversationExecutor`.
//! Same executor configuration as `agent-bridge/src/session.rs::initialize`;
//! the result JSON for a completed command is exactly what production writes
//! into history (`serde_json::to_string(&CommandOutput)`).
use mini_agent::{
    conversation::runner::{
        CancellationSignal, ConversationExecutor, ExecutionOutcome, LocalConversationExecutor,
        LocalExecutorConfig,
    },
    types::Action,
};
use serde_json::json;
use std::{
    ffi::{CStr, CString, c_char},
    path::PathBuf,
    sync::{OnceLock, mpsc},
    time::Duration,
};
use tokio::runtime::Runtime;

fn runtime() -> &'static Runtime {
    static RUNTIME: OnceLock<Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("echo-probe-exec")
            .enable_all()
            .build()
            .expect("probe runtime")
    })
}

pub struct ProbeExec {
    cancellation: CancellationSignal,
    result: mpsc::Receiver<String>,
}

fn string(value: *const c_char) -> Option<String> {
    (!value.is_null()).then(|| unsafe { CStr::from_ptr(value) }.to_string_lossy().into_owned())
}

/// Starts one bash action in `directory` (must be canonical). Never blocks.
#[unsafe(no_mangle)]
pub extern "C" fn probe_exec_start(command: *const c_char, directory: *const c_char) -> *mut ProbeExec {
    let (Some(command), Some(directory)) = (string(command), string(directory)) else {
        return std::ptr::null_mut();
    };
    let cancellation = CancellationSignal::new();
    let (tx, rx) = mpsc::channel();
    let signal = cancellation.clone();
    runtime().spawn(async move {
        let result = async {
            let mut executor = LocalConversationExecutor::new(LocalExecutorConfig {
                shell: "/bin/bash".into(),
                timeout: Duration::from_secs(30),
                max_output_bytes: 64 * 1024,
                ..Default::default()
            })?;
            executor.execute(Action { command }, PathBuf::from(directory), signal).await
        }
        .await;
        let reply = match result {
            Ok(ExecutionOutcome::Completed(output)) => json!({
                "outcome": "completed",
                "output": serde_json::to_string(&output).unwrap_or_default(),
            }),
            Ok(ExecutionOutcome::Cancelled) => json!({"outcome": "cancelled"}),
            Err(error) => json!({"outcome": "error", "error": serde_json::to_value(&error).unwrap_or_default()}),
        };
        let _ = tx.send(reply.to_string());
    });
    Box::into_raw(Box::new(ProbeExec { cancellation, result: rx }))
}

/// Requests cancellation; the executor kills the process tree and still reports once.
#[unsafe(no_mangle)]
pub extern "C" fn probe_exec_cancel(exec: *mut ProbeExec) {
    if let Some(exec) = unsafe { exec.as_ref() } {
        exec.cancellation.cancel();
    }
}

/// Blocks until the executor has finished, including cleanup after cancellation.
#[unsafe(no_mangle)]
pub extern "C" fn probe_exec_wait(exec: *mut ProbeExec) -> *mut c_char {
    let Some(exec) = (unsafe { exec.as_ref() }) else { return std::ptr::null_mut() };
    let reply = exec.result.recv().unwrap_or_else(|_| json!({"outcome": "error", "error": "executor task lost"}).to_string());
    CString::new(reply).map(CString::into_raw).unwrap_or(std::ptr::null_mut())
}

#[unsafe(no_mangle)]
pub extern "C" fn probe_exec_free(exec: *mut ProbeExec) {
    if !exec.is_null() {
        drop(unsafe { Box::from_raw(exec) });
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn probe_exec_string_free(value: *mut c_char) {
    if !value.is_null() {
        drop(unsafe { CString::from_raw(value) });
    }
}
