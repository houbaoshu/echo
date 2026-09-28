mod common;
use common::*;
use serde_json::json;
use std::time::{Duration, Instant};

fn parsed(result: &serde_json::Value) -> serde_json::Value {
    serde_json::from_str(result["output"].as_str().expect("output is a JSON string")).unwrap()
}

#[test]
fn completed_output_is_the_history_contract() {
    let temp = tempfile::tempdir().unwrap();
    let run = start(command("printf 'out 🌱'; printf 'err' >&2; exit 3", temp.path())).unwrap();
    let result = run.wait(Duration::from_secs(10));
    assert_eq!(result["outcome"], "completed");
    // Byte for byte what Mini Agent writes into v1 history for this command.
    let expected = mini_agent::types::CommandOutput {
        stdout: "out 🌱".into(), stderr: "err".into(), exit_code: Some(3), timed_out: false,
        stdout_truncated: false, stderr_truncated: false,
    };
    assert_eq!(result["output"].as_str().unwrap(), serde_json::to_string(&expected).unwrap());
    assert!(result["output"].as_str().unwrap().starts_with(r#"{"stdout":"#));
}

#[test]
fn runs_in_the_directory_with_limits_and_timeout() {
    let temp = tempfile::tempdir().unwrap();
    let mut request = command("pwd; head -c 200000 /dev/zero | tr '\\0' a", temp.path());
    request["max_output_bytes"] = json!(1024);
    let result = start(request).unwrap().wait(Duration::from_secs(10));
    let output = parsed(&result);
    let stdout = output["stdout"].as_str().unwrap();
    assert!(stdout.starts_with(temp.path().canonicalize().unwrap().to_str().unwrap()));
    assert!(stdout.len() <= 1024 && output["stdout_truncated"] == true);

    let mut slow = command("sleep 5", temp.path());
    slow["timeout_ms"] = json!(200);
    let start_at = Instant::now();
    let result = start(slow).unwrap().wait(Duration::from_secs(5));
    assert_eq!(result["outcome"], "completed");
    assert_eq!(parsed(&result)["timed_out"], true);
    assert!(start_at.elapsed() < Duration::from_secs(3));
}

#[test]
fn invalid_requests_are_rejected_before_anything_starts() {
    let temp = tempfile::tempdir().unwrap();
    let dir = temp.path().canonicalize().unwrap();
    for request in [
        json!({"version": 2, "command": "true", "directory": dir}),
        json!({"version": 1, "command": "", "directory": dir}),
        json!({"version": 1, "command": "true", "directory": "relative"}),
        json!({"version": 1, "command": "true", "directory": dir, "extra": 1}),
        json!("not an object"),
    ] {
        assert_eq!(start(request).err().as_deref(), Some("invalid execution request"));
    }
}

#[test]
fn a_directory_that_moved_or_is_an_alias_is_reported() {
    let temp = tempfile::tempdir().unwrap();
    let real = temp.path().canonicalize().unwrap().join("real");
    std::fs::create_dir(&real).unwrap();
    let alias = real.parent().unwrap().join("alias");
    std::os::unix::fs::symlink(&real, &alias).unwrap();
    for directory in [alias.clone(), real.parent().unwrap().join("missing")] {
        let result = start(json!({"version": 1, "command": "touch ran", "directory": directory}))
            .unwrap().wait(Duration::from_secs(5));
        assert_eq!(result["outcome"], "failed");
        assert_eq!(result["error"]["code"], "invalid_directory");
    }
    assert!(!real.join("ran").exists());
}

/// Cancel returns at once; done arrives only after the shell, its child and a descendant that
/// left the shell's session are gone (agent-bridge `lifecycle.rs` semantics on the new ABI).
#[test]
fn cancel_kills_the_whole_tree_before_reporting() {
    let temp = tempfile::tempdir().unwrap();
    let dir = temp.path().canonicalize().unwrap();
    let run = start(command(
        "echo $$ > shell.pid; python3 -c 'import subprocess as s; p = s.Popen([\"/bin/sh\", \"-c\", \"sleep 1; touch survived\"], start_new_session=True, stdin=s.DEVNULL, stdout=s.DEVNULL, stderr=s.DEVNULL); open(\"detached.pid\", \"w\").write(str(p.pid))'; sleep 20 & echo $! > child.pid; wait; touch survived",
        &dir,
    )).unwrap();
    wait_for(&dir.join("child.pid"), Duration::from_secs(5));
    wait_for(&dir.join("detached.pid"), Duration::from_secs(5));
    let started = Instant::now();
    run.cancel();
    assert!(started.elapsed() < Duration::from_millis(100), "cancel never blocks");
    let result = run.wait(Duration::from_secs(5));
    assert_eq!(result, json!({"version": 1, "outcome": "cancelled"}));
    for name in ["shell.pid", "child.pid", "detached.pid"] {
        assert!(!alive(read_pid(&dir.join(name))), "{name} outlived done");
    }
    std::thread::sleep(Duration::from_millis(1500));
    assert!(!dir.join("survived").exists());
    run.cancel(); // idempotent after done
}

/// Every descendant is killed when a command completes normally, too. (A background process
/// that keeps the output pipes open holds the command until its timeout, as in Rust today.)
#[test]
fn a_finished_command_leaves_no_background_process() {
    let temp = tempfile::tempdir().unwrap();
    let dir = temp.path().canonicalize().unwrap();
    let result = start(command("sleep 20 >/dev/null 2>&1 & echo $! > child.pid; printf ok", &dir)).unwrap().wait(Duration::from_secs(10));
    assert_eq!(parsed(&result)["stdout"], "ok");
    assert!(!alive(read_pid(&dir.join("child.pid"))));
}

#[test]
fn release_does_not_cancel_and_a_late_cancel_keeps_the_result() {
    let temp = tempfile::tempdir().unwrap();
    let dir = temp.path().canonicalize().unwrap();
    let results = start(command("sleep 0.3; printf finished", &dir)).unwrap().release();
    let result = results.recv_timeout(Duration::from_secs(5)).unwrap();
    assert_eq!(parsed(&result)["stdout"], "finished", "release is not cancel");

    let run = start(command("printf quick", &dir)).unwrap();
    let result = run.wait(Duration::from_secs(5));
    run.cancel();
    assert_eq!(result["outcome"], "completed");
    assert!(run.results.recv_timeout(Duration::from_millis(200)).is_err(), "done is called once");
}

/// Several commands on the two-worker runtime: cancelling all of them stays prompt while
/// process-tree scanning runs.
#[test]
fn concurrent_commands_cancel_promptly() {
    let temp = tempfile::tempdir().unwrap();
    let dir = temp.path().canonicalize().unwrap();
    let runs: Vec<_> = (0..6).map(|i| start(command(&format!("sleep 20 & echo $! > child{i}.pid; wait"), &dir)).unwrap()).collect();
    for i in 0..6 { wait_for(&dir.join(format!("child{i}.pid")), Duration::from_secs(5)); }
    let started = Instant::now();
    runs.iter().for_each(Started::cancel);
    for run in &runs { assert_eq!(run.wait(Duration::from_secs(5))["outcome"], "cancelled"); }
    assert!(started.elapsed() < Duration::from_secs(2), "took {:?}", started.elapsed());
    for i in 0..6 { assert!(!alive(read_pid(&dir.join(format!("child{i}.pid"))))); }
}
