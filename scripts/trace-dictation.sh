#!/bin/zsh
emulate -R zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_dir="$project_dir/build/Echo.app"
if [[ ! -x "$app_dir/Contents/MacOS/Echo" ]]; then
    echo "Build first: /bin/zsh scripts/build.sh --signing development" >&2
    exit 1
fi
if /usr/bin/pgrep -x Echo >/dev/null; then
    echo "请先退出正在运行的 Echo，再启动诊断版本，确保新进程加载诊断代码。" >&2
    exit 1
fi
umask 077
mkdir -p "$project_dir/build/test-logs"
trace_path="$project_dir/build/test-logs/dictation-$(date +%Y%m%d-%H%M%S)-$$.jsonl"
echo "普通 ASR 全文诊断日志：$trace_path"
echo "在同一次录音中说第一句 → 长停顿 → 说第二句 → 结束录音。复现后退出 Echo。"
"$app_dir/Contents/MacOS/Echo" --dictation-trace "$trace_path"
python3 - "$trace_path" <<'PY'
import collections
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
rows = [json.loads(line) for line in path.read_text().splitlines()]
counts = collections.Counter(row['event'] for row in rows)
providers = collections.Counter(row['provider'] for row in rows if row['event'] == 'recording.start')
print(f'日志：{path}')
print(f'录音轮数：{counts["recording.start"]}；真实帧：{counts["transport.frame"]}；识别回调：{counts["recognizer.callback"]}')
print(f'实际识别通道：{dict(providers)}')
if not counts['recognizer.callback']:
    print('本次没有采集到识别回调，不能用来定位转写覆盖；请保留日志供排查入口/授权。')
PY
