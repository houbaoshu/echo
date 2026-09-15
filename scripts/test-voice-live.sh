#!/bin/zsh
emulate -R zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
if [[ "${1:-}" != "" && "${1:-}" != --play ]]; then
    echo "Usage: $0 [--play]" >&2
    exit 1
fi
export CLANG_MODULE_CACHE_PATH="$project_dir/build/module-cache"
export SWIFT_MODULECACHE_PATH="$CLANG_MODULE_CACHE_PATH"
source scripts/swift-env.sh
cargo build --locked --release --target aarch64-apple-darwin
probe_app="$project_dir/build/voice-live-probe/Echo.app"
mkdir -p "$probe_app/Contents/MacOS" "$probe_app/Contents/Resources/agent"
cp macos/Info.plist "$probe_app/Contents/Info.plist"
cp "$(/bin/zsh "$project_dir/scripts/agent-prompt-path.sh")" "$probe_app/Contents/Resources/agent/conversation.md"
typeset -a sources=()
for source_file in macos/*.swift; do
    if [[ "$source_file" != macos/main.swift ]]; then sources+=("$source_file"); fi
done
swiftc -swift-version 6 -warnings-as-errors -target arm64-apple-macosx26.0 \
    -I runtime/include -I agent-bridge/include "${sources[@]}" tests/VoiceLiveTests.swift \
    target/aarch64-apple-darwin/release/libecho_runtime.a \
    target/aarch64-apple-darwin/release/libecho_agent.a \
    -framework AppKit -framework SwiftUI -framework Security -framework AVFoundation -framework Speech -lz \
    -o "$probe_app/Contents/MacOS/Echo"
/bin/zsh scripts/sign-app.sh --signing development "$probe_app"
# A hard overall deadline also covers a service that accepts sockets but never finishes.
python3 - "$@" <<'PY'
import subprocess, sys
try:
    sys.exit(subprocess.run(['build/voice-live-probe/Echo.app/Contents/MacOS/Echo', *sys.argv[1:]], timeout=180).returncode)
except subprocess.TimeoutExpired:
    print('FAIL: live voice check exceeded 180 seconds.', flush=True)
    sys.exit(1)
PY
