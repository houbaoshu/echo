"""Run the signed, relocated production bundle with a loopback model fixture."""
import json
import os
from pathlib import Path
import selectors
import shutil
import subprocess
import sys
import tempfile


def main():
    source = Path(sys.argv[1]).resolve(strict=True)
    root = Path(tempfile.mkdtemp(prefix="echo-packaged-", dir="/private/tmp"))
    app = root / "Echo.app"
    shutil.copytree(source, app)
    shutil.copyfile(Path(__file__).with_name("agent-session-server.py"), root / "model.py")
    cwd = root / "empty-cwd"
    cwd.mkdir()
    artifacts = root / "artifacts"
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    dependencies = subprocess.check_output(["otool", "-L", str(app / "Contents/MacOS/Echo")], text=True)
    assert all(line.strip().startswith(("/System/Library/", "/usr/lib/"))
               for line in dependencies.splitlines()[1:]), dependencies
    with (root / "model.log").open("w") as errors:
        server = subprocess.Popen(["/usr/bin/python3", str(root / "model.py")], cwd=cwd,
                                  stdout=subprocess.PIPE, stderr=errors, text=True)
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(server.stdout, selectors.EVENT_READ)
                assert selector.select(timeout=5), "Fixture startup timed out"
            port = int(server.stdout.readline().strip())
            with (root / "app.log").open("w") as log:
                result = subprocess.run([str(app / "Contents/MacOS/Echo"), "--acceptance-test",
                                         f"http://127.0.0.1:{port}", str(artifacts)],
                                        cwd=cwd, stdout=log, stderr=subprocess.STDOUT, timeout=100)
            output = (root / "app.log").read_text()
            print(output, flush=True)
            assert result.returncode == 0, f"App failed: {result.returncode}"
            assert "AppKit termination acknowledged Rust cleanup" in output
            assert len(list(artifacts.glob("*.png"))) == 4
            for file in artifacts.glob("*/note.txt"):
                assert file.read_text() == "after\n"
            for file in artifacts.glob("*/trace"):
                assert "forbidden" not in file.read_text()
            pid_files = list(artifacts.glob("*/*.pid"))
            assert len(pid_files) == 2, "Exit cleanup scenario did not start shell/child"
            for file in pid_files:
                try:
                    os.kill(int(file.read_text().strip()), 0)
                except ProcessLookupError:
                    continue
                raise AssertionError(f"Command process survived AppKit termination: {file.name}")
            states = [json.loads(file.read_text()) for file in (artifacts / "agent-sessions").glob("*.json")]
            assert states, "No persisted sessions"
            # Session snapshots must not persist an in-flight task after normal exit.
            for state in states:
                task = state.get("task")
                assert not task or task["status"] not in ("running", "stopping"), task
            print("PASS: relocated signed app, system-only dynamic libraries, screenshots, persisted terminal states, no surviving shell/child")
        finally:
            server.terminate()
            server.wait(timeout=5)
            print(f"Retained acceptance evidence: {root}", flush=True)


if __name__ == "__main__":
    main()
