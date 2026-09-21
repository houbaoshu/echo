#!/bin/zsh
emulate -R zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
if [[ "${1:-}" != "" && "${1:-}" != --play ]]; then
    echo "Usage: $0 [--play]" >&2
    exit 1
fi
# Signed under the production bundle identity so the saved voice credentials in
# the Keychain are readable.
/bin/zsh scripts/signing-identity.sh
xcodebuild -project Echo.xcodeproj -target VoiceLiveProbe -configuration Development \
    CONFIGURATION_BUILD_DIR="$project_dir/build/voice-live-probe" build
# A hard overall deadline also covers a service that accepts sockets but never finishes.
python3 - "$@" <<'PY'
import subprocess, sys
try:
    sys.exit(subprocess.run(['build/voice-live-probe/Echo.app/Contents/MacOS/Echo', *sys.argv[1:]], timeout=180).returncode)
except subprocess.TimeoutExpired:
    print('FAIL: live voice check exceeded 180 seconds.', flush=True)
    sys.exit(1)
PY
