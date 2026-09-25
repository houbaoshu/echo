//! C ABI plumbing shared by the integration tests; each test file keeps its own driving logic.
#![allow(dead_code)]
use echo_agent::*;
use serde_json::Value;
use std::{
    ffi::{CStr, c_char},
    time::{Duration, Instant},
};

/// Destroys the session however the test ends.
pub struct Handle(pub *mut EchoAgent);
impl Drop for Handle {
    fn drop(&mut self) {
        unsafe { echo_agent_destroy(self.0) }
    }
}

/// Parses a string the bridge returned, then gives it back to Rust to free.
pub fn owned(pointer: *mut c_char) -> Value {
    assert!(!pointer.is_null());
    let result =
        unsafe { serde_json::from_str(CStr::from_ptr(pointer).to_str().unwrap()).unwrap() };
    unsafe { echo_agent_string_free(pointer) };
    result
}

/// Waits until every destroyed session has finished reaping its work.
pub async fn wait_for_shutdown() {
    let start = Instant::now();
    while echo_agent_active_sessions() != 0 {
        assert!(start.elapsed() < Duration::from_secs(5));
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
}
