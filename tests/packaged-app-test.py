"""Run the signed, relocated production bundle with a loopback model fixture."""
import base64
import json
import os
from pathlib import Path
import selectors
import shutil
import subprocess
import sys
import tempfile


def verify_checkpoint(state, session_id):
    """Check the actual sidecar across the Swift/wire/core persistence boundary."""
    history = json.loads(base64.b64decode(state["agentHistory"], validate=True))
    assert history["version"] == 1 and history["session_id"] == session_id
    checkpoint = state["savedCheckpoint"]
    assert checkpoint["generation"] and checkpoint["revision"] > 0
    assert state["pendingInputs"] == [], "Terminal session lost an input acknowledgement"
    entries = {entry["id"]: entry for entry in history["entries"]}
    assert len(entries) == len(history["entries"])
    messages = {message["coreID"]: message for message in state["messages"]}
    assert len(messages) == len(state["messages"]), "Duplicate visible core message"
    receipts = state["inputReceipts"]
    assert len({r["client_message_id"] for r in receipts}) == len(receipts)
    assert len({r["message_id"] for r in receipts}) == len(receipts)
    assert {r["message_id"] for r in receipts} == {
        e["id"] for e in entries.values() if e["value"]["message"]["role"] == "user"
    }
    for receipt in receipts:
        entry = entries[receipt["message_id"]]
        message = messages[receipt["message_id"]]
        assert receipt["turn_id"] == entry["turn_id"]
        assert receipt["client_message_id"] == message["id"]
        assert message["content"] == entry["value"]["message"]["content"]
    projection = state["agentProjection"]
    assert [entry["message_id"] for entry in projection if entry["type"] == "message"] == [
        message["coreID"] for message in state["messages"]
    ], "Saved display order differs from the core projection"
    projected_tools = [entry for entry in projection if entry["type"] == "tool"]
    assert len(projected_tools) == len(state["tools"])
    for projected, tool in zip(projected_tools, state["tools"]):
        assert (projected["message_id"], projected["turn_id"], projected["call_id"], projected["result"]) == (
            tool["entryID"], tool["turnID"], tool["callID"], tool["result"])
    delivered = state["deliveredReplies"]
    assert len(set(delivered)) == len(delivered)
    assert all(messages[mid]["role"] == "assistant" for mid in delivered)
    return history


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
            assert "PASS: packaged main-actor heartbeat" in output
            assert len(list(artifacts.glob("*.png"))) == 4
            notes = list(artifacts.glob("*/note.txt"))
            assert len(notes) == 2, "Both protocols must complete real read/edit/verify"
            for file in notes:
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
            states = {file.stem: json.loads(file.read_text())
                      for file in (artifacts / "agent-sessions").glob("*.json")}
            # Workspace also persists its untouched initial draft as an empty sidecar.
            for state in states.values():
                if not state.get("task"):
                    assert not state["messages"] and not state.get("agentHistory") and not state.get("pendingInputs")
            states = {session_id: state for session_id, state in states.items() if state.get("task")}
            assert len(states) == 5, "Expected two chats, two tool sessions and the exit session"
            # Session snapshots must not persist an in-flight task after normal exit.
            histories = []
            for session_id, state in states.items():
                task = state.get("task")
                assert not task or task["status"] not in ("running", "stopping"), task
                histories.append(verify_checkpoint(state, session_id))
            assert sum(state["task"]["status"] == "completed" for state in states.values()) == 4
            assert sum(state["task"]["status"] == "stopped" for state in states.values()) == 1
            reasoning = [item for history in histories for entry in history["entries"]
                         for item in entry["value"].get("response_items", []) if item["type"] == "reasoning"]
            assert len(reasoning) == 3 and all(
                item["encrypted_content"] == "acceptance-opaque-reasoning" for item in reasoning
            ), "Responses metadata lost across protocol switch or persistence"
            print("PASS: relocated signed app, system-only libraries, screenshots, v1 history/v2 checkpoint mappings, "
                  "Responses metadata, terminal snapshots, no surviving shell/child")
        finally:
            server.terminate()
            server.wait(timeout=5)
            print(f"Retained acceptance evidence: {root}", flush=True)


if __name__ == "__main__":
    main()
