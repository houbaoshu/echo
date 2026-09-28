//! Its own test binary: nothing else may start a command in this process first.
mod common;
use common::*;
use echo_exec::{echo_exec_active, echo_exec_runtime_started};
use std::time::{Duration, Instant};

#[test]
fn only_a_started_command_creates_the_runtime_and_active_returns_to_zero() {
    assert!(!echo_exec_runtime_started());
    assert_eq!(echo_exec_active(), 0);
    assert!(!echo_exec_runtime_started(), "asking for the count starts nothing");
    let _ = start(serde_json::json!({"version": 1, "command": "", "directory": "/"}));
    assert!(!echo_exec_runtime_started(), "a rejected request starts nothing");

    let temp = tempfile::tempdir().unwrap();
    let run = start(command("sleep 0.2", temp.path())).unwrap();
    assert!(echo_exec_runtime_started());
    assert_eq!(echo_exec_active(), 1);
    assert_eq!(run.wait(Duration::from_secs(5))["outcome"], "completed");
    let start = Instant::now();
    while echo_exec_active() != 0 {
        assert!(start.elapsed() < Duration::from_secs(1));
        std::thread::sleep(Duration::from_millis(1));
    }
}
