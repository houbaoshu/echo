//! Explicit cancellation acknowledgement: kill the group, then reap the shell.
use mini_agent::{
    Result,
    types::{Action, CommandOutput},
};
use rustix::process::{Pid, Signal, kill_process_group};
use std::{process::Stdio, time::Duration};
use tokio::{
    io::{AsyncRead, AsyncReadExt},
    process::Command,
    sync::watch,
};

struct Group(Option<Pid>);
impl Group {
    fn kill(&mut self) -> std::io::Result<()> {
        if let Some(pid) = self.0.take() {
            match kill_process_group(pid, Signal::KILL) {
                Ok(()) | Err(rustix::io::Errno::SRCH) => {}
                Err(error) => return Err(error.into()),
            }
        }
        Ok(())
    }
}
impl Drop for Group {
    fn drop(&mut self) {
        let _ = self.kill();
    }
}

#[derive(Default)]
struct Capture {
    bytes: Vec<u8>,
    truncated: bool,
}
impl Capture {
    async fn read(&mut self, pipe: &mut (impl AsyncRead + Unpin)) -> std::io::Result<()> {
        let mut buffer = [0; 8192];
        loop {
            let n = pipe.read(&mut buffer).await?;
            if n == 0 {
                return Ok(());
            }
            let keep = n.min((64 * 1024usize).saturating_sub(self.bytes.len()));
            self.bytes.extend_from_slice(&buffer[..keep]);
            self.truncated |= keep < n;
        }
    }
}

pub async fn execute(
    action: Action,
    directory: std::path::PathBuf,
    stop: watch::Receiver<bool>,
) -> Result<CommandOutput> {
    execute_with_timeout(action, directory, stop, Duration::from_secs(30)).await
}

async fn execute_with_timeout(
    action: Action,
    directory: std::path::PathBuf,
    mut stop: watch::Receiver<bool>,
    timeout: Duration,
) -> Result<CommandOutput> {
    if *stop.borrow() || stop.has_changed().is_err() {
        return Err(mini_agent::Error::Config(
            "command cancelled before spawn".into(),
        ));
    }
    let mut child = Command::new("/bin/bash")
        .arg("-c")
        .arg(action.command)
        .current_dir(directory)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .process_group(0)
        .kill_on_drop(true)
        .spawn()?;
    let mut group = Group(child.id().and_then(|id| Pid::from_raw(id as i32)));
    let mut stdout = child.stdout.take().unwrap();
    let mut stderr = child.stderr.take().unwrap();
    let (mut out, mut err) = (Capture::default(), Capture::default());
    let result = tokio::select! {
        biased;
        _ = stop.changed() => None,
        result = tokio::time::timeout(timeout, async {
            tokio::try_join!(child.wait(), out.read(&mut stdout), err.read(&mut stderr))
        }) => Some(result),
    };
    // Also clean up descendants holding pipes open, on success, error or timeout.
    let killed = group.kill();
    let status = child.wait().await;
    killed?;
    let status = status?;
    let timed_out = matches!(result, Some(Err(_)));
    if let Some(Ok(result)) = result {
        result?;
    }
    Ok(CommandOutput {
        stdout: String::from_utf8_lossy(&out.bytes).into_owned(),
        stderr: String::from_utf8_lossy(&err.bytes).into_owned(),
        exit_code: status.code(),
        timed_out,
        stdout_truncated: out.truncated,
        stderr_truncated: err.truncated,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn output_limits_and_timeout_preserve_captured_bytes() {
        let temp = tempfile::tempdir().unwrap();
        let (_stop, cancel) = watch::channel(false);
        let output = execute(
            Action {
                command: "head -c 70000 /dev/zero; head -c 70000 /dev/zero >&2".into(),
            },
            temp.path().into(),
            cancel,
        )
        .await
        .unwrap();
        assert_eq!(output.stdout.len(), 65536);
        assert_eq!(output.stderr.len(), 65536);
        assert!(output.stdout_truncated && output.stderr_truncated);
        assert_eq!(output.exit_code, Some(0));

        let (_stop, cancel) = watch::channel(false);
        let output = execute_with_timeout(
            Action {
                command: "printf started; sleep 20".into(),
            },
            temp.path().into(),
            cancel,
            Duration::from_millis(100),
        )
        .await
        .unwrap();
        assert!(output.timed_out);
        assert_eq!(output.stdout, "started");
    }

    #[tokio::test]
    async fn cancellation_before_task_is_scheduled_does_not_spawn() {
        let temp = tempfile::tempdir().unwrap();
        let (stop, cancel) = watch::channel(false);
        stop.send(true).unwrap();
        assert!(
            execute(
                Action {
                    command: "touch forbidden".into()
                },
                temp.path().into(),
                cancel
            )
            .await
            .is_err()
        );
        assert!(!temp.path().join("forbidden").exists());
    }
}
