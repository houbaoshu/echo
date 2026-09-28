#![allow(dead_code)]
use echo_exec::*;
use serde_json::Value;
use std::{
    ffi::{CStr, CString, c_char, c_void},
    sync::mpsc,
    time::{Duration, Instant},
};

pub struct Started {
    pub handle: *mut EchoExec,
    pub results: mpsc::Receiver<Value>,
}
// Handles are only moved between test threads, never shared.
unsafe impl Send for Started {}

extern "C" fn done(context: *mut c_void, result: *const c_char) {
    let sender = unsafe { Box::from_raw(context as *mut mpsc::Sender<Value>) };
    let text = unsafe { CStr::from_ptr(result) }.to_string_lossy().into_owned();
    let _ = sender.send(serde_json::from_str(&text).expect("result is JSON"));
}

pub fn start(request: Value) -> Result<Started, String> {
    let (tx, rx) = mpsc::channel();
    let context = Box::into_raw(Box::new(tx)) as *mut c_void;
    let request = CString::new(request.to_string()).unwrap();
    let mut error: *mut c_char = std::ptr::null_mut();
    let handle = unsafe { echo_exec_start(request.as_ptr(), context, Some(done), &mut error) };
    if handle.is_null() {
        drop(unsafe { Box::from_raw(context as *mut mpsc::Sender<Value>) });
        let message = unsafe { CStr::from_ptr(error) }.to_string_lossy().into_owned();
        unsafe { echo_exec_string_free(error) };
        return Err(message);
    }
    Ok(Started { handle, results: rx })
}

pub fn command(command: &str, directory: &std::path::Path) -> Value {
    serde_json::json!({"version": 1, "command": command, "directory": directory.canonicalize().unwrap()})
}

impl Started {
    pub fn wait(&self, timeout: Duration) -> Value {
        self.results.recv_timeout(timeout).expect("done within the deadline")
    }
    pub fn cancel(&self) { unsafe { echo_exec_cancel(self.handle) } }
}
impl Started {
    /// Releases the handle while the command may still run; results keep arriving.
    pub fn release(self) -> mpsc::Receiver<Value> {
        let this = std::mem::ManuallyDrop::new(self);
        unsafe { echo_exec_release(this.handle) };
        unsafe { std::ptr::read(&this.results) }
    }
}
impl Drop for Started {
    fn drop(&mut self) { unsafe { echo_exec_release(self.handle) } }
}

pub fn alive(pid: i32) -> bool {
    rustix::process::kill_process(rustix::process::Pid::from_raw(pid).unwrap(), rustix::process::Signal::CONT).is_ok()
}

pub fn read_pid(path: &std::path::Path) -> i32 {
    std::fs::read_to_string(path).unwrap().trim().parse().unwrap()
}

pub fn wait_for(path: &std::path::Path, timeout: Duration) {
    let start = Instant::now();
    while !path.exists() {
        assert!(start.elapsed() < timeout, "{} never appeared", path.display());
        std::thread::sleep(Duration::from_millis(5));
    }
}
