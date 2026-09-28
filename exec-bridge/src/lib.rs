//! Process execution for Echo's native Agent engine. Each handle runs one bash command with
//! `mini-agent-exec`'s local executor and reports once, after cleanup, through a C callback.
//! See `include/echo_exec.h`.
use mini_agent_exec::{
    Action, CancellationSignal, ExecutionErrorCode, ExecutionOutcome, LocalExecutor, LocalExecutorConfig,
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    ffi::{CStr, CString, c_char, c_void},
    path::PathBuf,
    sync::{
        OnceLock,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};
use tokio::runtime::Runtime;

static RUNTIME: OnceLock<Runtime> = OnceLock::new();
static ACTIVE: AtomicUsize = AtomicUsize::new(0);

fn runtime() -> &'static Runtime {
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("echo-exec")
            .enable_all()
            .build()
            .expect("echo-exec runtime")
    })
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    version: u32,
    command: String,
    directory: PathBuf,
    timeout_ms: Option<u64>,
    max_output_bytes: Option<usize>,
}

pub struct EchoExec {
    cancellation: CancellationSignal,
}

/// Owned by the command's task until `done` has returned.
struct Callback {
    context: *mut c_void,
    done: extern "C" fn(*mut c_void, *const c_char),
}
// The caller promises the context may be used from the runtime thread until `done` returns.
unsafe impl Send for Callback {}

fn failure(code: &str, message: &str) -> Value {
    json!({"version": 1, "outcome": "failed", "error": {"code": code, "message": message}})
}

fn error_out(error: *mut *mut c_char, message: &str) {
    if !error.is_null() {
        let value = CString::new(message).unwrap_or_default().into_raw();
        unsafe { *error = value };
    }
}

async fn run(request: Request, cancellation: CancellationSignal) -> Value {
    let executor = LocalExecutor::new(LocalExecutorConfig {
        shell: "/bin/bash".into(),
        timeout: Duration::from_millis(request.timeout_ms.unwrap_or(30_000)),
        max_output_bytes: request.max_output_bytes.unwrap_or(64 * 1024),
        ..Default::default()
    });
    let mut executor = match executor {
        Ok(executor) => executor,
        Err(_) => return failure("execution_failed", "command execution failed"),
    };
    match executor.execute(Action { command: request.command }, request.directory, cancellation).await {
        // The exact string Mini Agent writes into history, in CommandOutput's field order.
        Ok(ExecutionOutcome::Completed(output)) => match serde_json::to_string(&output) {
            Ok(text) => json!({"version": 1, "outcome": "completed", "output": text}),
            Err(_) => failure("execution_failed", "command execution failed"),
        },
        Ok(ExecutionOutcome::Cancelled) => json!({"version": 1, "outcome": "cancelled"}),
        Err(error) => failure(
            match error.code {
                ExecutionErrorCode::InvalidRequest => "invalid_request",
                ExecutionErrorCode::InvalidDirectory => "invalid_directory",
                ExecutionErrorCode::ExecutionFailed => "execution_failed",
            },
            &error.message,
        ),
    }
}

/// # Safety
/// `request` is a NUL-terminated UTF-8 string; `error` is null or writable. `context` stays
/// valid until `done` is called, which happens exactly once for a non-null result.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn echo_exec_start(
    request: *const c_char,
    context: *mut c_void,
    done: Option<extern "C" fn(*mut c_void, *const c_char)>,
    error: *mut *mut c_char,
) -> *mut EchoExec {
    let Some(done) = done else {
        error_out(error, "missing completion callback");
        return std::ptr::null_mut();
    };
    if request.is_null() {
        error_out(error, "missing request");
        return std::ptr::null_mut();
    }
    let text = unsafe { CStr::from_ptr(request) }.to_string_lossy();
    let request: Request = match serde_json::from_str(&text) {
        Ok(request) => request,
        Err(_) => {
            error_out(error, "invalid execution request");
            return std::ptr::null_mut();
        }
    };
    if request.version != 1 || request.command.is_empty() || !request.directory.is_absolute() {
        error_out(error, "invalid execution request");
        return std::ptr::null_mut();
    }
    let cancellation = CancellationSignal::new();
    let signal = cancellation.clone();
    let callback = Callback { context, done };
    ACTIVE.fetch_add(1, Ordering::SeqCst);
    runtime().spawn(async move {
        let result = run(request, signal).await;
        let result = CString::new(result.to_string()).unwrap_or_default();
        let callback = callback;
        (callback.done)(callback.context, result.as_ptr());
        ACTIVE.fetch_sub(1, Ordering::SeqCst);
    });
    Box::into_raw(Box::new(EchoExec { cancellation }))
}

/// # Safety
/// `exec` is null or a live handle from `echo_exec_start`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn echo_exec_cancel(exec: *mut EchoExec) {
    if let Some(exec) = unsafe { exec.as_ref() } {
        exec.cancellation.cancel();
    }
}

/// # Safety
/// `exec` is null or a live handle from `echo_exec_start`, released exactly once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn echo_exec_release(exec: *mut EchoExec) {
    if !exec.is_null() {
        drop(unsafe { Box::from_raw(exec) });
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn echo_exec_active() -> usize {
    ACTIVE.load(Ordering::SeqCst)
}

#[unsafe(no_mangle)]
pub extern "C" fn echo_exec_runtime_started() -> bool {
    RUNTIME.get().is_some()
}

/// # Safety
/// `value` is null or a string returned by this library, freed exactly once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn echo_exec_string_free(value: *mut c_char) {
    if !value.is_null() {
        drop(unsafe { CString::from_raw(value) });
    }
}
