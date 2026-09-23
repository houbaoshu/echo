//! Version 2 JSON C ABI. Persistent conversation archives remain version 1.
//! See include/echo_agent.h and docs/mini-agent-mainline-bridge-v2-contract.md.
mod session;
pub mod wire;

use mini_agent::conversation::runner::{SessionHandle, SessionResult};
use serde::Serialize;
use serde_json::Value;
use std::{
    ffi::{CStr, CString, c_char},
    panic::{AssertUnwindSafe, catch_unwind},
    ptr,
    sync::Mutex,
};
use wire::*;

pub struct EchoAgent {
    session: Mutex<SessionHandle>,
}
const MAX_REQUEST_BYTES: usize = 16 * 1024 * 1024;
// Create carries the restored archive; ordinary commands retain their smaller limit.
const MAX_CREATE_BYTES: usize = 32 * 1024 * 1024;

fn invalid() -> SessionError {
    SessionError::new(ErrorCode::InvalidRequest, "invalid JSON request")
}
fn internal() -> SessionError {
    SessionError::new(ErrorCode::Internal, "agent bridge failed")
}
unsafe fn parse(request: *const c_char, max_bytes: usize) -> SessionResult<Value> {
    if request.is_null() {
        return Err(invalid());
    }
    let bytes = unsafe { CStr::from_ptr(request) }.to_bytes();
    if bytes.len() > max_bytes {
        return Err(SessionError::new(
            ErrorCode::RequestTooLarge,
            format!("JSON request exceeds {} MiB", max_bytes / (1024 * 1024)),
        ));
    }
    let value: Value = serde_json::from_slice(bytes).map_err(|_| invalid())?;
    // Inspect version before decoding the payload, including old v1 envelopes.
    let version = value
        .get("version")
        .and_then(Value::as_u64)
        .ok_or_else(invalid)?;
    if version != u64::from(WIRE_VERSION) {
        return Err(SessionError::new(
            ErrorCode::UnsupportedVersion,
            "wire version 2 required",
        ));
    }
    Ok(value)
}
fn string(value: &impl Serialize) -> *mut c_char {
    CString::new(serde_json::to_string(value).expect("wire serialization"))
        .expect("JSON escapes NUL")
        .into_raw()
}
fn reply(request_id: Option<String>, result: SessionResult<()>) -> *mut c_char {
    string(&WireReply {
        version: WIRE_VERSION,
        request_id,
        admission: match result {
            Ok(()) => Admission::Queued {},
            Err(error) => Admission::Rejected { error },
        },
    })
}

/// Returns a handle immediately; initialization success/failure arrives in a batch.
/// # Safety
/// request is a NUL-terminated UTF-8 JSON string. error is null or writable for one
/// pointer. Free any returned error with echo_agent_string_free. Serialize handle
/// calls against destroy; destroy each handle exactly once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn echo_agent_create(
    request: *const c_char,
    error: *mut *mut c_char,
) -> *mut EchoAgent {
    if !error.is_null() {
        unsafe {
            *error = ptr::null_mut();
        }
    }
    let result = catch_unwind(AssertUnwindSafe(|| -> SessionResult<_> {
        let value = unsafe { parse(request, MAX_CREATE_BYTES) }?;
        // An omitted override must not accidentally erase a persisted directory.
        if value
            .get("restore")
            .and_then(|v| v.get("directory"))
            .is_none()
        {
            return Err(invalid());
        }
        let config: WireCreate = serde_json::from_value(value).map_err(|_| invalid())?;
        if config.session_id.trim().is_empty()
            || config.generation.trim().is_empty()
            || !config.prompt_path.is_absolute()
        {
            return Err(invalid());
        }
        Ok(Box::into_raw(Box::new(EchoAgent {
            session: Mutex::new(session::spawn(config)?),
        })))
    }))
    .unwrap_or_else(|_| Err(internal()));
    match result {
        Ok(handle) => handle,
        Err(message) => {
            if !error.is_null() {
                unsafe {
                    *error = reply(None, Err(message));
                }
            }
            ptr::null_mut()
        }
    }
}

unsafe fn enqueue(
    handle: *mut EchoAgent,
    request: *const c_char,
    expected: Option<&str>,
) -> *mut c_char {
    let mut request_id = None;
    let result = catch_unwind(AssertUnwindSafe(|| {
        let value = unsafe { parse(request, MAX_REQUEST_BYTES) }?;
        request_id = value
            .get("request_id")
            .and_then(Value::as_str)
            .map(str::to_owned);
        if expected.is_some_and(|kind| value["command"]["type"] != kind) {
            return Err(invalid());
        }
        // directory:null is an explicit command; absence is malformed.
        if value["command"]["type"] == "provide_directory"
            && value["command"].get("directory").is_none()
        {
            return Err(invalid());
        }
        let request: WireRequest = serde_json::from_value(value).map_err(|_| invalid())?;
        request
            .validate_envelope()
            .map_err(|code| SessionError::new(code, "invalid request envelope"))?;
        request.command.validate()?;
        let handle = unsafe { handle.as_ref() }.ok_or_else(invalid)?;
        let session = handle.session.try_lock().map_err(|_| internal())?;
        match request.command {
            WireCommand::Command(command) => session.try_command(request.request_id, command),
            WireCommand::Control(control) => session.try_control(request.request_id, control),
        }
    }))
    .unwrap_or_else(|_| Err(internal()));
    reply(request_id, result)
}

macro_rules! request_api {
    ($name:ident, $kind:expr) => {
        /// Nonblocking admission. Queued means enqueued; command_result reports application.
        /// # Safety
        /// handle must be live; request must be a NUL-terminated string. Free the
        /// returned string exactly once with echo_agent_string_free.
        #[unsafe(no_mangle)]
        pub unsafe extern "C" fn $name(
            handle: *mut EchoAgent,
            request: *const c_char,
        ) -> *mut c_char {
            unsafe { enqueue(handle, request, $kind) }
        }
    };
}
request_api!(echo_agent_submit, Some("submit"));
request_api!(echo_agent_steer, Some("steer"));
request_api!(echo_agent_provide_directory, Some("provide_directory"));
request_api!(echo_agent_request, None);

/// Out-of-band stop; never waits for queue space or process cleanup.
/// # Safety
/// handle is null or live and not concurrently destroyed. Serialize handle calls.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn echo_agent_cancel(handle: *mut EchoAgent) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if let Some(handle) = unsafe { handle.as_ref() } {
            // Calls are serialized by the C ownership contract; recover poison
            // so a previous FFI panic cannot disable cleanup.
            handle
                .session
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .stop();
        }
    }));
}

fn encode_batch(batch: SessionBatch) -> SessionResult<SessionBatch<String>> {
    let checkpoint = batch
        .checkpoint
        .map(|checkpoint| -> SessionResult<_> {
            Ok(Checkpoint {
                id: checkpoint.id,
                history: serde_json::to_string(&checkpoint.history).map_err(|_| internal())?,
                input_receipts: checkpoint.input_receipts,
                projection: checkpoint.projection,
            })
        })
        .transpose()?;
    Ok(SessionBatch {
        session_id: batch.session_id,
        generation: batch.generation,
        turn_id: batch.turn_id,
        operation_id: batch.operation_id,
        kind: batch.kind,
        events: batch.events,
        checkpoint,
    })
}

/// Drain up to max_batches (1..64), without waiting. Returned JSON owns all bytes.
/// # Safety
/// handle is null or live. Free returned string once, even after destroying handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn echo_agent_poll_events(
    handle: *mut EchoAgent,
    max_batches: usize,
) -> *mut c_char {
    let result = catch_unwind(AssertUnwindSafe(|| -> SessionResult<_> {
        let handle = unsafe { handle.as_ref() }.ok_or_else(invalid)?;
        let mut session = handle.session.try_lock().map_err(|_| internal())?;
        let mut batches = Vec::new();
        let mut closed = false;
        for _ in 0..max_batches.clamp(1, EVENT_CAPACITY) {
            match session.try_next_batch() {
                Ok(Some(batch)) => batches.push(encode_batch(batch)?),
                Ok(None) => break,
                Err(error) if error.code == ErrorCode::SessionClosed => {
                    closed = true;
                    break;
                }
                Err(error) => return Err(error),
            }
        }
        // If exactly max_batches were drained, closure is reported on the next
        // poll; never consume or drop a batch merely to inspect channel status.
        // Streamed text follows the batches it may postdate, coalesced per poll.
        Ok(WirePoll {
            version: WIRE_VERSION,
            batches,
            closed,
            stream: session.try_take_stream(),
        })
    }))
    .unwrap_or_else(|_| Err(internal()));
    match result {
        Ok(poll) => string(&poll),
        Err(error) => reply(None, Err(error)),
    }
}

/// Releases the handle immediately and asks Mini Agent to close and clean up.
/// Unread batches are discarded. active_sessions reaches zero only after each
/// runner completion; keep the process alive until then during shutdown.
/// # Safety
/// handle is null or a live handle, destroyed once, with no concurrent calls.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn echo_agent_destroy(handle: *mut EchoAgent) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if !handle.is_null() {
            drop(unsafe { Box::from_raw(handle) });
        }
    }));
}

#[unsafe(no_mangle)]
pub extern "C" fn echo_agent_active_sessions() -> usize {
    session::ACTIVE.load(std::sync::atomic::Ordering::SeqCst)
}

/// # Safety
/// value is null or a string returned by this library, freed exactly once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn echo_agent_string_free(value: *mut c_char) {
    if !value.is_null() {
        drop(unsafe { CString::from_raw(value) });
    }
}
