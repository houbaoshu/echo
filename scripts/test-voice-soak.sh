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
export CLANG_MODULE_CACHE_PATH="$project_dir/build/module-cache"
export SWIFT_MODULECACHE_PATH="$CLANG_MODULE_CACHE_PATH"
source scripts/swift-env.sh
cargo build --locked --release --target aarch64-apple-darwin
# Signed under the production bundle identity: the saved voice key lives in the Keychain
# and an unsigned CLI cannot read it. No microphone entitlement is exercised.
probe_app="$project_dir/build/voice-soak-probe/Echo.app"
mkdir -p "$probe_app/Contents/MacOS" "$probe_app/Contents/Resources/agent"
cp macos/Info.plist "$probe_app/Contents/Info.plist"
cp "$(/bin/zsh "$project_dir/scripts/agent-prompt-path.sh")" "$probe_app/Contents/Resources/agent/conversation.md"
typeset -a sources=()
for source_file in macos/*.swift; do
    if [[ "$source_file" != macos/main.swift ]]; then sources+=("$source_file"); fi
done
swiftc -swift-version 6 -warnings-as-errors -target arm64-apple-macosx27.0 \
    -I runtime/include -I agent-bridge/include "${sources[@]}" tests/VoiceSoakTests.swift \
    target/aarch64-apple-darwin/release/libecho_runtime.a \
    target/aarch64-apple-darwin/release/libecho_agent.a \
    -framework AppKit -framework SwiftUI -framework Security -framework AVFoundation -framework Speech -lz \
    -o "$probe_app/Contents/MacOS/Echo"
/bin/zsh scripts/sign-app.sh --signing development "$probe_app"
mkdir -p build/test-logs
log="build/test-logs/voice-soak-$(date +%Y%m%d-%H%M%S).log"
# Diagnostics are written to stderr; keep both streams in one ordered file.
code=0
"$probe_app/Contents/MacOS/Echo" "$seconds" "$@" 2>&1 | tee "$log" || code=$?
echo "Log: $project_dir/$log"
exit $code
