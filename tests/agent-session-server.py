"""Deterministic Chat/Responses fixture; commands only touch the test cwd."""
import json
import time
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
        if "multi-tool" in text and len(results) == 1:
            command = "printf 'second\\n' >> trace; printf 'second result'"
        reply = "最终回复：" + ("已读取真实工具结果" if results else text)
        if "skip" in text:
            command = None
        if responses:
            output = [{"type": "function_call", "call_id": "call-1", "name": "bash",
                       "arguments": json.dumps({"command": command})}] if command else [
                {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": reply}]}]
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
