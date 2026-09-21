#!/bin/zsh
emulate -R zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
seconds="${1:-120}"
if [[ $# -gt 0 ]]; then shift; fi
if [[ ! "$seconds" =~ '^[0-9]+$' ]]; then
    echo "Usage: $0 [seconds] [--cut seconds]" >&2
    exit 1
fi
# Signed under the production bundle identity: the saved voice key lives in the
# Keychain and an unsigned CLI cannot read it. No microphone entitlement is exercised.
xcodebuild -project Echo.xcodeproj -target VoiceSoakProbe -configuration Development \
    CONFIGURATION_BUILD_DIR="$project_dir/build/voice-soak-probe" build
mkdir -p build/test-logs
log="build/test-logs/voice-soak-$(date +%Y%m%d-%H%M%S).log"
# Diagnostics are written to stderr; keep both streams in one ordered file.
code=0
"build/voice-soak-probe/Echo.app/Contents/MacOS/Echo" "$seconds" "$@" 2>&1 | tee "$log" || code=$?
echo "Log: $project_dir/$log"
exit $code
