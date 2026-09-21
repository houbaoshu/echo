#!/bin/zsh
emulate -R zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
if [[ $# -ne 0 ]]; then echo "Usage: $0" >&2; exit 2; fi
# Runs under the production bundle identity with a certificate: the saved model
# credentials live in the Keychain and an unsigned build cannot read them.
/bin/zsh scripts/signing-identity.sh
xcodebuild -project Echo.xcodeproj -target AgentLiveProbe -configuration Development \
    CONFIGURATION_BUILD_DIR="$project_dir/build/agent-live-probe" build
python3 - <<'PY'
import subprocess, sys
try:
    sys.exit(subprocess.run(['build/agent-live-probe/Echo.app/Contents/MacOS/Echo'], timeout=480).returncode)
except subprocess.TimeoutExpired:
    print('FAIL: live Agent check exceeded 480 seconds.', flush=True)
    sys.exit(1)
PY
