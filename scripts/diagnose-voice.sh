#!/bin/zsh
emulate -R zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
/bin/zsh scripts/build.sh --signing development
mkdir -p build/test-logs
# Run within the production bundle identity. An external CLI does not inherit
# Echo's microphone permission. This captures locally and uploads only silence.
python3 - <<'PY'
import subprocess, sys
from pathlib import Path
log = Path('build/test-logs/voice-diagnostic.log')
try:
    with log.open('w') as output:
        result = subprocess.run(['build/Echo.app/Contents/MacOS/Echo', '--diagnose-voice'],
                                stdout=output, stderr=subprocess.STDOUT, timeout=180)
    print(log.read_text())
    print(f'Log: {log.resolve()}')
    sys.exit(result.returncode)
except subprocess.TimeoutExpired:
    with log.open('a') as output:
        output.write('\n[诊断结果] FAIL 总耗时超过 180 秒，进程已终止；未完成的阶段未验证。\n')
    print(log.read_text())
    sys.exit(1)
PY
