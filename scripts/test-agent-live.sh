#!/bin/zsh
emulate -R zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
if [[ $# -ne 0 ]]; then echo "Usage: $0" >&2; exit 2; fi
source scripts/swift-env.sh
cargo build --locked --release --target aarch64-apple-darwin
probe_app="$project_dir/build/agent-live-probe/Echo.app"
mkdir -p "$probe_app/Contents/MacOS" "$probe_app/Contents/Resources/agent"
cp macos/Info.plist "$probe_app/Contents/Info.plist"
cp ../mini-agent-agent-core-exp/config/prompts/conversation.md "$probe_app/Contents/Resources/agent/conversation.md"
typeset -a sources=()
for source_file in macos/*.swift; do
    if [[ "$source_file" != macos/main.swift ]]; then sources+=("$source_file"); fi
done
swiftc -swift-version 6 -warnings-as-errors -target arm64-apple-macosx26.0 \
    -I runtime/include -I agent-bridge/include "${sources[@]}" tests/AgentLiveTests.swift \
    target/aarch64-apple-darwin/release/libecho_runtime.a \
    target/aarch64-apple-darwin/release/libecho_agent.a \
    -framework AppKit -framework SwiftUI -framework Security -framework AVFoundation -framework Speech -lz \
    -o "$probe_app/Contents/MacOS/Echo"
/bin/zsh scripts/sign-app.sh --signing development "$probe_app"
python3 - <<'PY'
import subprocess, sys
try:
    sys.exit(subprocess.run(['build/agent-live-probe/Echo.app/Contents/MacOS/Echo'], timeout=480).returncode)
except subprocess.TimeoutExpired:
    print('FAIL: live Agent check exceeded 480 seconds.', flush=True)
    sys.exit(1)
PY
