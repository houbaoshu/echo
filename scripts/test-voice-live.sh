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
typeset -a sources=()
for source_file in macos/*.swift; do
    if [[ "$source_file" != macos/main.swift ]]; then sources+=("$source_file"); fi
done
swiftc -swift-version 6 -warnings-as-errors -target arm64-apple-macosx26.0 \
    -I runtime/include -I agent-bridge/include "${sources[@]}" tests/VoiceLiveTests.swift \
    target/aarch64-apple-darwin/release/libecho_runtime.a \
    target/aarch64-apple-darwin/release/libecho_agent.a \
    -framework AppKit -framework SwiftUI -framework Security -framework AVFoundation -lz \
    -o build/voice-live-tests
# A hard overall deadline also covers a service that accepts sockets but never finishes.
python3 - "$@" <<'PY'
import subprocess, sys
try:
    sys.exit(subprocess.run(['build/voice-live-tests', *sys.argv[1:]], timeout=180).returncode)
except subprocess.TimeoutExpired:
    print('FAIL: live voice check exceeded 180 seconds.', flush=True)
    sys.exit(1)
PY
