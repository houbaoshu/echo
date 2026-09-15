//! Version 1 JSON C ABI. See include/echo_agent.h and docs/agent-integration-stage2.md.
mod executor;
mod session;

use serde::de::DeserializeOwned;
use serde_json::json;
use session::{Channels, Create, Request};
use std::{
    ffi::{CStr, CString, c_char},
    panic::{AssertUnwindSafe, catch_unwind},
    ptr,
    sync::Arc,
};

pub struct EchoAgent {
    channels: Arc<Channels>,
}
const MAX_REQUEST_BYTES: usize = 16 * 1024 * 1024;

unsafe fn parse<T: DeserializeOwned>(request: *const c_char) -> Result<T, String> {
    if request.is_null() {
        return Err("missing JSON request".into());
    }
    let bytes = unsafe { CStr::from_ptr(request) }.to_bytes();
    if bytes.len() > MAX_REQUEST_BYTES {
        return Err("JSON request exceeds 16 MiB".into());
    }
    serde_json::from_slice(bytes).map_err(|_| "invalid JSON request".into())
}
fn string(value: serde_json::Value) -> *mut c_char {
    CString::new(value.to_string()).unwrap().into_raw()
}
fn reply(result: Result<(), String>) -> *mut c_char {
    match result {
        Ok(()) => string(json!({"version":1,"accepted":true})),
        Err(error) => string(json!({"version":1,"accepted":false,"error":error})),
    }
}

/// Returns a handle immediately; initialization success/failure arrives as an event.
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
    let result = catch_unwind(AssertUnwindSafe(|| -> Result<_, String> {
        let config: Create = unsafe { parse(request) }?;
        if config.version != 1
            || config.session_id.trim().is_empty()
            || !config.prompt_path.is_absolute()
        {
            return Err("version 1, session ID and absolute prompt_path required".into());
        }
        Ok(Box::into_raw(Box::new(EchoAgent {
            channels: session::spawn(config)?,
        })))
    }))
    .unwrap_or_else(|_| Err("agent initialization panicked".into()));
    match result {
        Ok(handle) => handle,
        Err(message) => {
            if !error.is_null() {
                unsafe {
                    *error = reply(Err(message));
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
    reply(
        catch_unwind(AssertUnwindSafe(|| {
            let handle = unsafe { handle.as_ref() }.ok_or("missing handle")?;
            let value: serde_json::Value = unsafe { parse(request) }?;
            if expected.is_some_and(|kind| value["type"] != kind) {
                return Err("wrong request type".into());
            }
            let mut request: Request =
                serde_json::from_value(value).map_err(|_| "invalid request".to_string())?;
            if request.version != 1 || request.request_id.trim().is_empty() {
                return Err("version 1 and request_id required".into());
            }
            request.cancel_generation = *handle.channels.cancel.borrow();
            handle
                .channels
                .commands
                .try_send(request)
                .map_err(|error| match error {
                    tokio::sync::mpsc::error::TrySendError::Full(_) => {
                        "command queue full; request not accepted".into()
                    }
                    tokio::sync::mpsc::error::TrySendError::Closed(_) => "session closed".into(),
                })
        }))
        .unwrap_or_else(|_| Err("agent request panicked".into())),
    )
}

macro_rules! request_api {
    ($name:ident, $kind:expr) => {
        /// Nonblocking enqueue. Accepted means queued; command_result reports validation.
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
/// handle is null or live and not concurrently destroyed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn echo_agent_cancel(handle: *mut EchoAgent) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if let Some(handle) = unsafe { handle.as_ref() } {
            handle
                .channels
                .cancel
                .send_modify(|sequence| *sequence = sequence.wrapping_add(1));
        }
    }));
}

/// Drain up to max_batches (1..64), without waiting. Returned JSON owns all bytes.
/// # Safety
/// handle is null or live. Free returned string once, even after destroying handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn echo_agent_poll_events(
    handle: *mut EchoAgent,
    max_batches: usize,
) -> *mut c_char {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(handle) = (unsafe { handle.as_ref() }) else { return reply(Err("missing handle".into())); };
        let Ok(mut receiver) = handle.channels.events.try_lock() else { return reply(Err("concurrent poll".into())); };
        let mut events = Vec::new();
        for _ in 0..max_batches.clamp(1, session::EVENT_CAPACITY) {
            match receiver.try_recv() { Ok(event) => events.push(event), Err(_) => break }
        }
        string(json!({"version":1,"batches":events,"closed":receiver.is_closed() && receiver.is_empty()}))
    })).unwrap_or_else(|_| reply(Err("agent poll panicked".into())))
}

/// Releases the handle immediately and asks its worker to cancel and clean up.
/// Unread events are discarded on destruction. active_sessions reaches zero only
/// after workers finish cleanup; keep the process alive until then during shutdown.
/// # Safety
/// handle is null or a live handle, destroyed once, with no concurrent calls.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn echo_agent_destroy(handle: *mut EchoAgent) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if !handle.is_null() {
            let handle = unsafe { Box::from_raw(handle) };
            let _ = handle.channels.destroy.send(true);
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
