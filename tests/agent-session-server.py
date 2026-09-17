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
            assert body["stream"] is True
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
        if "markdown-stream" in text and not command:
            reply = "## 结果\n\n- **第一项**通过\n- 运行 `swift test`\n- 第三项\n- 第四项完成"
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
        if body.get("stream"):
            self.stream(value, responses, pause=0.15 if "slow-stream" in text else 0)
            return
        encoded = json.dumps(value).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        try:
            self.wfile.write(encoded)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def stream(self, value, responses, pause):
        """Server-sent events carrying the same reply in several real deltas."""
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()

        def send(event):
            self.wfile.write(("data: " + json.dumps(event, ensure_ascii=False) + "\n\n").encode())
            self.wfile.flush()
            if pause:
                time.sleep(pause)

        def pieces(text, count=4):
            size = max(1, -(-len(text) // count))
            return [text[i:i + size] for i in range(0, len(text), size)]

        try:
            if responses:
                for item in value["output"]:
                    send({"type": "response.output_item.added", "item": item})
                    if item["type"] == "message":
                        for piece in pieces(item["content"][0]["text"]):
                            send({"type": "response.output_text.delta", "item_id": "msg-test",
                                  "content_index": 0, "delta": piece})
                send({"type": "response.completed", "response": value})
            else:
                message = value["choices"][0]["message"]
                for piece in pieces(message["content"]):
                    send({"choices": [{"index": 0, "delta": {"content": piece}, "finish_reason": None}]})
                for call in message.get("tool_calls", []):
                    arguments = call["function"]["arguments"]
                    send({"choices": [{"index": 0, "delta": {"tool_calls": [{"index": 0, "id": call["id"], "type": "function",
                          "function": {"name": "bash", "arguments": arguments[:5]}}]}, "finish_reason": None}]})
                    send({"choices": [{"index": 0, "delta": {"tool_calls": [{"index": 0,
                          "function": {"arguments": arguments[5:]}}]}, "finish_reason": None}]})
                send({"choices": [{"index": 0, "delta": {}, "finish_reason": value["choices"][0]["finish_reason"]}]})
                self.wfile.write(b"data: [DONE]\n\n")
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *_):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
