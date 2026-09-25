#!/bin/zsh
# External sampling only. Start/stop calls in Echo or XCUITest; Xcode builds the
# CoreAudio helper. --mode labels a debugger-attached / detached comparison.
emulate -R zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL
summarize() {
    python3 - "$1" <<'PY'
import re, statistics, sys
lines = open(sys.argv[1], encoding='utf-8', errors='replace').read().splitlines()
calls, current = [], None
mark = re.compile(r'\[计时\] MARK \+([\d.]+)ms (.+)$')
span = re.compile(r'\[计时\] SPAN \+([\d.]+)ms (.+?) 耗时 ([\d.]+)ms')
reason = re.compile(r'\[通话结束\] REASON (\+\S+) (.*)$')
for line in lines:
    if m := mark.search(line):
        offset, name = float(m[1]), m[2]
        if offset == 0.0 and name.startswith('开始'):
            current = {'entry': name, 'marks': {}, 'spans': {}, 'reason': None}
            calls.append(current)
        elif current is not None:
            current['marks'].setdefault(name, offset)
    elif current is None:
        continue
    elif m := span.search(line):
        current['spans'].setdefault(m[2].strip(), []).append(float(m[3]))
    elif m := reason.search(line):
        current['reason'] = f'{m[1]} {m[2]}'
if not calls:
    sys.exit('没有找到任何通话（缺少 "MARK +0.0ms 开始" 行）。')

def table(title, rows):
    print(f'\n{title}')
    width = max(len(name) for name, _ in rows)
    print(f'  {"":{width}}  {"n":>3} {"min":>10} {"median":>10} {"max":>10}')
    for name, values in rows:
        print(f'  {name:{width}}  {len(values):>3} {min(values):>10.1f} {statistics.median(values):>10.1f} {max(values):>10.1f}')

def ordered(key):
    names = []
    for call in calls:
        for name in call[key]:
            if name not in names: names.append(name)
    return names

print(f'通话数：{len(calls)}')
marks = [(n, [c['marks'][n] for c in calls if n in c['marks']]) for n in ordered('marks')]
if not marks:
    sys.exit('日志只有通话开始，没有后续计时点；采样未完成。')
table('MARK 相对点击的偏移（ms）', marks)
# A span that repeats within one call (workspace saves) is reported as its per-call total.
spans = [(n, [sum(c['spans'][n]) for c in calls if n in c['spans']]) for n in ordered('spans')]
if spans: table('SPAN 耗时（ms，同一通话内多次则求和）', spans)
print('\n每次通话')
for i, call in enumerate(calls, 1):
    listening = call['marks'].get('ASR 就绪 → listening')
    audio = sum(call['spans'].get('audio.start', [])) or None
    print(f'  #{i} {call["entry"]}  click→listening={f"{listening:.0f}ms" if listening is not None else "—"}'
          f'  audio.start={f"{audio:.0f}ms" if audio is not None else "—"}')
    print(f'     REASON {call["reason"] or "（日志中没有结束行）"}')
PY
}

mode=N duration=120 process_id="" helper="" output=""
while (( $# )); do
    case "$1" in
        --mode) mode="$2"; shift 2 ;;
        --seconds) duration="$2"; shift 2 ;;
        --pid) process_id="$2"; shift 2 ;;
        --helper) helper="$2"; shift 2 ;;
        --output) output="$2"; shift 2 ;;
        --summarize) summarize "$2"; exit ;;
        --help|-h)
            echo "Usage: $0 --pid ECHO_PID --helper BUILT_EchoCoreAudioProbe [--mode D|N] [--seconds 120] [--output DIR]"
            echo "Run Echo with/without LLDB yourself; interact through the App or XCUITest."
            exit ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done
[[ "$mode" == (D|N) && "$duration" == <1-> && "$process_id" == <1-> && -x "$helper" ]] || {
    echo "Require --pid, an Xcode-built --helper, positive --seconds, and --mode D|N" >&2; exit 2
}
kill -0 "$process_id"
[[ -n "$output" ]] || output="$(mktemp -d "${TMPDIR:-/tmp}/echo-voice-startup.XXXXXX")"
mkdir -p "$output"
log_file="$output/voice-$mode.log"
/usr/bin/log stream --style compact --level debug --predicate "processIdentifier == $process_id AND subsystem == \"local.chiyan.desktop-pet\" AND category == \"voice\"" > "$log_file" 2>&1 &
log_pid=$!
cleanup() { kill "$log_pid" 2>/dev/null || true; wait "$log_pid" 2>/dev/null || true }
trap cleanup EXIT
/bin/ps -p "$process_id" -o pid,ppid,stat,comm > "$output/process-$mode.txt"
echo "Sampling $duration seconds ($mode). Evidence: $output"
printf 'elapsed_seconds,input_device_running\n' > "$output/device-$mode.csv"
started=$SECONDS
while (( SECONDS - started < duration )); do
    kill -0 "$process_id" || { echo "App ended before sampling finished" >&2; exit 1 }
    running="$("$helper")"
    printf '%s,%s\n' "$(( SECONDS - started ))" "$running" >> "$output/device-$mode.csv"
    sleep 0.25
done
cleanup
trap - EXIT
summarize "$log_file"
