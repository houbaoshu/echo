//! Its own test binary: it sets environment variables before any command starts.
mod common;
use common::*;
use std::time::Duration;

fn stdout(result: &serde_json::Value) -> String {
    let output: serde_json::Value = serde_json::from_str(result["output"].as_str().unwrap()).unwrap();
    output["stdout"].as_str().unwrap().to_owned()
}

/// Commands run in /bin/zsh with the caller's environment and none of the user's startup files.
#[test]
fn commands_run_in_zsh_without_startup_files() {
    let temp = tempfile::tempdir().unwrap();
    let dir = temp.path().canonicalize().unwrap();
    let home = dir.join("zdotdir");
    std::fs::create_dir(&home).unwrap();
    for name in [".zshenv", ".zprofile", ".zshrc", ".zlogin"] {
        std::fs::write(home.join(name), format!("print {name} >> {}\n", dir.join("sourced").display())).unwrap();
    }
    // Before any thread of this binary starts a process.
    unsafe {
        std::env::set_var("ZDOTDIR", &home);
        std::env::set_var("ECHO_EXEC_INHERITED", "kept");
    }
    // The fixture works: a plain zsh -c reads $ZDOTDIR/.zshenv.
    std::process::Command::new("/bin/zsh").args(["-c", "true"]).status().unwrap();
    assert_eq!(std::fs::read_to_string(dir.join("sourced")).unwrap(), ".zshenv\n");
    std::fs::remove_file(dir.join("sourced")).unwrap();

    // ${(U)…} is zsh-only; bash rejects it as a bad substitution.
    let result = start(command(r#"x=abc; print -r -- "$0 ${(U)x} $ECHO_EXEC_INHERITED $PWD""#, &dir))
        .unwrap()
        .wait(Duration::from_secs(10));
    assert_eq!(stdout(&result), format!("/bin/zsh ABC kept {}\n", dir.display()));
    assert!(!dir.join("sourced").exists(), "a startup file was read");
}
