"""Deterministic Chat/Responses fixture; commands only touch the test cwd."""
import json
import time
import shlex
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        responses = self.path.endswith("responses")
        items = body.get("input", []) if responses else body["messages"]
        users = [x.get("content", "") for x in items if x.get("role") == "user"]
        text = str(users[-1]) if users else ""
        results = [x for x in items if x.get("role") == "tool" or x.get("type") == "function_call_output"]
        if "slow-model" in text:
            time.sleep(0.5)
        command = None
        if "tool" in text and not results:
            command = "printf 'one\\n' >> trace; printf '工具输出 🌱'; printf 'diagnostic' >&2"
            if "slow-tool" in text:
                command = "printf 'started\\n' >> trace; sleep 0.7; printf 'done\\n' >> trace"
            if "cancel-tool" in text:
                command = "printf 'started\\n' >> trace; sleep 15; printf 'forbidden\\n' >> trace"
        if "acceptance-quit-tool" in text and not results:
            command = "echo $$ > shell.pid; sleep 15 & echo $! > child.pid; printf 'started\\n' >> trace; wait; printf 'forbidden\\n' >> trace"
        if "multi-tool" in text and len(results) == 1:
            command = "printf 'second\\n' >> trace; printf 'second result'"
        if "acceptance-rwv" in text or "acceptance-history" in text:
            observed = [json.loads(x.get("output", x.get("content", "{}"))) for x in results]
            expected = ["before\n", "", "after\n"]
            assert all(x["stdout"] == expected[i] and x["exit_code"] == 0
                       for i, x in enumerate(observed)), observed
            assert body["stream"] is False
            if responses:
                assert body["store"] is False
            commands = ["cat note.txt", "printf 'after\\n' > note.txt", "test \"$(cat note.txt)\" = after && cat note.txt"]
            command = commands[len(results)] if len(results) < 3 else None
            if "acceptance-history" in text:
                assert len(results) == 3
                command = None
        if "tool capability test" in text:
            model = body["model"]
            if model.startswith("probe-delay:"):
                time.sleep(1)
            if model.startswith(("probe:", "probe-delay:")):
                command = "printf forbidden > " + shlex.quote(model.split(":", 1)[1])
            if model == "probe-text-only":
                command = None
            if model == "probe-malformed":
                command = 17
        reply = "最终回复：" + ("已读取真实工具结果" if results else text)
        if "skip" in text:
            command = None
        if responses:
            output = [{"type": "function_call", "call_id": "call-1", "name": "bash",
                       "arguments": json.dumps({"command": command})}] if command else [
                {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": reply}]}]
            if "acceptance-rwv" in text and command:
                output.insert(0, {"type": "reasoning", "id": f"rs-acceptance-{len(results)}",
                                  "summary": [], "encrypted_content": "acceptance-opaque-reasoning"})
            value = {"id": "resp-test", "status": "completed", "output": output}
        else:
            message = {"role": "assistant", "content": "我先检查文件。" if command else reply}
            if command:
                message["tool_calls"] = [{"id": "call-1", "type": "function", "function": {
                    "name": "bash", "arguments": json.dumps({"command": command})}}]
            value = {"choices": [{"message": message, "finish_reason": "tool_calls" if command else "stop"}]}
        encoded = json.dumps(value).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        try:
            self.wfile.write(encoded)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *_):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
