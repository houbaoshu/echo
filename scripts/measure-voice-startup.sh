#!/bin/zsh
# Measures Live Voice startup from the diagnostics timeline. Manual tool, not part of CI.
#
#   measure-voice-startup.sh [--mode D|N] [--entry main|manual] [--runs 5] [--app PATH]
#   measure-voice-startup.sh --summarize LOG
#
# --mode D   Echo is already running from Xcode (Run, debugger attached).
# --mode N   `open` the Development build from DerivedData, without a debugger. An instance
#            already started that way (parent pid 1) is reused; one Xcode launched is quit first.
# --entry main    Clicks 对话 → 切换 Live Voice through System Events, waits for ASR 就绪,
#                 then ends the call the same way. Needs Accessibility for the terminal.
# --entry manual  Only collects: start and end the calls yourself (pet entry), then press
#                 Return. The summary covers every call that began while collecting.
#
# --probe-ui        While connecting, time accessibility queries of Echo's windows (answered on its
#                   main thread) and print the slowest per call.
# --cancel-after S  Each run ends the call S seconds into connecting, reports click→REASON latency,
#                   restarts at once, ends that call normally, then times until the mic is idle.
#
# Output goes to build/voice-startup/<timestamp>-<mode>-<entry>.log (raw `log stream`) and a
# summary printed with min / median / max for every MARK offset and SPAN duration, plus one
# REASON per call.
emulate -R zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL
zmodload zsh/datetime zsh/mathfunc
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
bundle_id="local.chiyan.desktop-pet"
predicate='subsystem == "local.chiyan.desktop-pet" AND category == "voice"'

summarize() {
    python3 - "$1" <<'PY'
import math, re, statistics, sys
lines = open(sys.argv[1], encoding='utf-8', errors='replace').read().splitlines()
calls, current = [], None
mark = re.compile(r'\[计时\] MARK \+([\d.]+)ms (.+)$')
span = re.compile(r'\[计时\] SPAN \+([\d.]+)ms (.+?) 耗时 ([\d.]+)ms')
reason = re.compile(r'\[通话结束\] REASON (\+\S+) (.*)$')
frames = re.compile(r'\[通话结束\] INFO PlanetFrame body 次数 (.+)$')
for line in lines:
    if m := mark.search(line):
        offset, name = float(m[1]), m[2]
        if offset == 0.0 and name.startswith('开始'):
            current = {'entry': name, 'marks': {}, 'spans': {}, 'reason': None, 'frames': ''}
            calls.append(current)
        elif current is not None:
            current['marks'].setdefault(name, offset)
    elif current is None:
        continue
    elif m := span.search(line):
        current['spans'].setdefault(m[2].strip(), []).append(float(m[3]))
    elif m := reason.search(line):
        current['reason'] = f'{m[1]} {m[2]}'
    elif m := frames.search(line):
        current['frames'] = m[1]
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
    if call['frames']: print(f'     PlanetFrame {call["frames"]}')
    # P1-A: chat-window planet frames while connecting (10 fps animation). Counting stops at the
    # REASON line, so the listening stretch (4 fps) is subtracted as an upper bound, plus one mount.
    r = re.match(r'\+([\d.]+)ms', call['reason'] or '')
    if call['frames'] and listening is not None and r:
        chat = sum(int(v) for v in re.findall(r'聊天窗口·[^=]+=(\d+)', call['frames']))
        after = math.ceil(4 * (float(r[1]) - listening) / 1000) + 1
        expected = 10 * listening / 1000
        print(f'     连接期聊天窗口帧 ≥{max(0, chat - after)} / 期望 {expected:.0f}（{max(0, chat - after) / expected:.0%}，验收 ≥80%）')
PY
}

mode=D entry=main runs=5 app="" probe_ui=0 cancel_after=""
while (( $# )); do
    case $1 in
        --mode) mode=$2; shift 2 ;;
        --entry) entry=$2; shift 2 ;;
        --runs) runs=$2; shift 2 ;;
        --app) app=$2; shift 2 ;;
        --probe-ui) probe_ui=1; shift ;;
        --cancel-after) cancel_after=$2; shift 2 ;;
        --summarize) summarize "$2"; exit ;;
        *) print -u2 "未知参数：$1"; exit 2 ;;
    esac
done
[[ $mode == (D|N) ]] || { print -u2 "--mode 只能是 D 或 N"; exit 2 }
[[ $entry == (main|manual) ]] || { print -u2 "--entry 只能是 main 或 manual"; exit 2 }

echo_pid() { pgrep -x Echo -u "$USER" | head -1 || true }

if [[ $mode == N ]]; then
    if [[ -z $app ]]; then
        products=$(xcodebuild -project "$project_dir/Echo.xcodeproj" -scheme Echo -configuration Development \
            -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $2; exit}')
        app="$products/Echo.app"
    fi
    [[ -d $app ]] || { print -u2 "找不到 Development 构建：$app（先在 Xcode 里用 Development 配置构建一次）"; exit 1 }
    # An instance launchd started (`open`, parent pid 1) has no debugger and is reused, so a
    # profiler can be attached before the runs; one Xcode launched is quit and replaced.
    if [[ -n $(echo_pid) && $(ps -o ppid= -p $(echo_pid) | tr -d ' ') != 1 ]]; then
        print "退出正在运行的 Echo（Xcode 里的实例会随之结束调试）…"
        osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
        for _ in {1..20}; do [[ -z $(echo_pid) ]] && break; sleep 0.5; done
        [[ -z $(echo_pid) ]] || { print -u2 "Echo 没有退出，请在 Xcode 里停止后重试。"; exit 1 }
    fi
    if [[ -z $(echo_pid) ]]; then
        print "启动（无调试器）：$app"
        open "$app"
        for _ in {1..40}; do [[ -n $(echo_pid) ]] && break; sleep 0.5; done
        sleep 3   # let the workspace load before the first click
    else print "沿用已在运行的无调试器实例"
    fi
else
    [[ -n $(echo_pid) ]] || { print -u2 "D 方式需要先在 Xcode 里 Run Echo。"; exit 1 }
fi
pid=$(echo_pid)
[[ -n $pid ]] || { print -u2 "Echo 没有启动。"; exit 1 }
print "Echo pid=$pid mode=$mode entry=$entry"

out_dir="$project_dir/build/voice-startup"
mkdir -p "$out_dir"
log_file="$out_dir/$(date +%Y%m%d-%H%M%S)-$mode-$entry.log"
/usr/bin/log stream --level default --style compact --predicate "$predicate" > "$log_file" 2>&1 &
stream_pid=$!
trap 'kill $stream_pid 2>/dev/null || true' EXIT
sleep 1

# Counts lines in the collected log that match an extended regex.
count() { grep -cE -- "$1" "$log_file" || true }
# Waits until `count $1` exceeds $2, for at most $3 seconds.
wait_for() {
    local deadline=$(( SECONDS + $3 ))
    while (( SECONDS < deadline )); do
        (( $(count "$1") > $2 )) && return 0
        sleep 0.25
    done
    return 1
}

menu_item='menu item "切换 Live Voice" of menu 1 of menu bar item "对话" of menu bar 1'
# Brings Echo forward and clicks the toggle once it validates. Returns 1 if it never enabled.
# Echo is an accessory app: System Events never reports it frontmost, and the only way to its
# main window (the one AXStandardWindow) is clicking the pet (the AXSystemDialog that is not
# the 活动控件 strip), so the menu item's own validation is what is waited on.
# Prints the epoch time (from NSDate, sub-millisecond) taken just before the click itself.
click_toggle() {
    osascript <<APPLESCRIPT
use framework "Foundation"
use scripting additions
tell application "System Events"
    tell (first process whose bundle identifier is "$bundle_id")
        if (count of (windows whose subrole is "AXStandardWindow")) is 0 then
            set pet to first window whose subrole is "AXSystemDialog" and name is not "活动控件"
            set {x, y} to position of pet
            set {w, h} to size of pet
            click at {x + w / 2, y + h / 2}
            delay 1
        end if
    end tell
end tell
tell application id "$bundle_id" to activate
tell application "System Events"
    tell (first process whose bundle identifier is "$bundle_id")
        set frontmost to true
        repeat 20 times
            if enabled of $menu_item then exit repeat
            delay 0.25
        end repeat
        if not (enabled of $menu_item) then error "切换 Live Voice 不可用：打开主窗口并选中一个会话" number 1
        set clickedAt to (current application's NSDate's |date|())'s timeIntervalSince1970()
        click $menu_item
    end tell
end tell
return ((current application's NSNumber's numberWithDouble:clickedAt)'s stringValue()) as text
APPLESCRIPT
}

begin_re='\[计时\] MARK \+0\.0ms 开始'
ready_re='\[计时\] MARK .* ASR 就绪'
reason_re='\[通话结束\] REASON'
user_end_re='\[通话结束\] REASON .* 用户结束'

# Prints 1 while any process has the default input device running (what the orange dot shows).
mic_in_use() {
    local helper="$out_dir/mic-in-use"
    if [[ ! -x $helper || $helper -ot $0 ]]; then
        cat > "$out_dir/mic-in-use.swift" <<'SWIFT'
import CoreAudio
var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                         mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var device = AudioDeviceID(0), running = UInt32(0), size = UInt32(4)
_ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
_ = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running)
print(running)
SWIFT
        swiftc -O -o "$helper" "$out_dir/mic-in-use.swift" >/dev/null
    fi
    "$helper"
}
# Milliseconds an accessibility query of Echo's windows takes; it is answered on Echo's main thread.
ui_probe_ms() {
    local begin=$EPOCHREALTIME
    osascript -e "tell application \"System Events\" to get name of every window of (first process whose bundle identifier is \"$bundle_id\")" >/dev/null 2>&1 || true
    print $(( int((EPOCHREALTIME - begin) * 1000) ))
}
# Local wall time (epoch seconds) of the last REASON line, from log stream's own timestamp.
last_reason_time() {
    grep -E "$reason_re" "$log_file" | tail -1 | python3 -c '
import sys, datetime
line = sys.stdin.read()
print(datetime.datetime.strptime(line[:23], "%Y-%m-%d %H:%M:%S.%f").timestamp())'
}

# Clicks start and waits for the call's begin mark; snapshots the counters first.
begin_call() {
    begins=$(count "$begin_re"); readies=$(count "$ready_re"); reasons=$(count "$reason_re"); user_ends=$(count "$user_end_re")
    click_toggle >/dev/null
    wait_for "$begin_re" $begins 5 || { print -u2 "\n点击后 5 秒内没有看到开始 MARK，中止。"; exit 1 }
}
# Waits for listening or for the call to end on its own, probing the UI meanwhile if asked.
wait_connected() {
    local deadline=$(( SECONDS + 90 )) probes=0 slowest=0 ms
    while (( SECONDS < deadline )); do
        (( $(count "$ready_re") > readies || $(count "$reason_re") > reasons )) && break
        if (( probe_ui )); then
            ms=$(ui_probe_ms); (( probes += 1 )); (( ms > slowest )) && slowest=$ms
        else sleep 0.25
        fi
    done
    (( probe_ui )) && print -n " [UI 探测 $probes 次 最慢 ${slowest}ms]"
    return 0
}
# Ends the open call with the toggle. Sets end_click to the epoch time the successful click began.
end_call() {
    for attempt in 1 2; do
        # Only click while this call is still open; a click after it ended would start another.
        (( $(count "$reason_re") > reasons )) && break
        end_click=$(click_toggle)
        wait_for "$reason_re" $reasons 5 && break
    done
    if (( $(count "$user_end_re") > user_ends )); then print -n " 已结束"
    elif (( $(count "$reason_re") > reasons )); then
        print -n " 以其他原因结束：$(grep -E "$reason_re" "$log_file" | tail -1 | sed -E 's/.*REASON //')"
    else print -u2 "\n两次结束点击都没有产生 REASON，中止。"; exit 1
    fi
}
# A full call: start, wait for listening, end.
full_call() {
    begin_call
    wait_connected
    if (( $(count "$reason_re") > reasons )); then
        print -n " 通话自行结束：$(grep -E "$reason_re" "$log_file" | tail -1 | sed -E 's/.*REASON //')"
    else
        (( $(count "$ready_re") > readies )) && print -n " listening，结束…" || print -n " 90 秒内未就绪，结束…"
        sleep 1
        end_call
        print -n "（点击→REASON $(python3 -c "print(round(($(last_reason_time) - $end_click) * 1000))")ms）"
    fi
}
# Seconds until the default input device is idle again, at most 60.
wait_mic_idle() {
    local begin=$SECONDS
    while (( SECONDS - begin < 60 )); do
        [[ $(mic_in_use) == 0 ]] && { print $(( SECONDS - begin )); return 0 }
        sleep 0.5
    done
    print "超过60"
}

if [[ $entry == manual ]]; then
    print "开始采集。请手动完成 $runs 次通话（开始 → 等到 listening → 结束），完成后按回车。"
    read -r
else
    osascript -e "tell application \"System Events\" to count menu bar items of menu bar 1 of (first process whose bundle identifier is \"$bundle_id\")" >/dev/null 2>&1 ||
        { print -u2 "System Events 无法读取 Echo 菜单：请在 系统设置 → 隐私与安全性 → 辅助功能 中授权当前终端。"; exit 1 }
    print "开始前麦克风占用=$(mic_in_use)"
    for run in {1..$runs}; do
        if [[ -n $cancel_after ]]; then
            # End during connecting, restart at once, then check the microphone is released
            # once that second call ends too (the abandoned build included).
            print -n "第 $run/$runs 次：开始…"
            begin_call
            sleep $cancel_after
            if (( $(count "$ready_re") > readies || $(count "$reason_re") > reasons )); then
                print -u2 "\n$cancel_after 秒内已经 listening 或已结束，取消测试无效，中止。"; exit 1
            fi
            print -n " 连接中取消…"
            end_call
            latency=$(python3 -c "print(round(($(last_reason_time) - $end_click) * 1000))")
            print -n "（点击→REASON ${latency}ms，麦克风占用=$(mic_in_use)）；立即重新开始…"
            full_call
            print " 结束后麦克风释放用时 $(wait_mic_idle) 秒"
        else
            print -n "第 $run/$runs 次：开始…"
            full_call
            print
        fi
        sleep 4   # give the audio device time to be released before the next call
    done
fi
sleep 1
kill $stream_pid 2>/dev/null || true
print "\n原始日志：$log_file"
summarize "$log_file"
