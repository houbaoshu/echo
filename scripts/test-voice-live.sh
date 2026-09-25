#!/bin/zsh
# Transitional manual comparison only. Native plan exists; retain this old probe
# until its real-service/device behavior has been compared on this machine.
emulate -R zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL
[[ "${1:-}" == --app && $# -ge 2 ]] || { echo "Usage: $0 --app BUILT_PROBE_APP [probe arguments]" >&2; exit 2 }
probe="$2/Contents/MacOS/Echo"
shift 2
[[ -x "$probe" ]] || { echo "Missing Xcode-built probe: $probe" >&2; exit 2 }
python3 - "$probe" "$@" <<'PYTHON'
import subprocess, sys
timeout = 180
try:
    sys.exit(subprocess.run(sys.argv[1:], timeout=timeout).returncode)
except subprocess.TimeoutExpired:
    print('INCOMPLETE: manual probe exceeded its deadline.', flush=True)
    sys.exit(1)
PYTHON
