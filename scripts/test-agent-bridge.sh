#!/bin/zsh
emulate -R zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
source scripts/swift-env.sh
cargo test --locked -p echo-agent
cargo build --locked --release --target aarch64-apple-darwin -p echo-agent
# A disposable app bundle tests Bundle.main from a cwd with no source/config files.
probe_root="$(mktemp -d /private/tmp/echo-agent-probe.XXXXXX)"
probe_app="$probe_root/BridgeProbe.app"
mkdir -p "$probe_app/Contents/MacOS" "$probe_app/Contents/Resources/agent"
cp "$(/bin/zsh "$project_dir/scripts/agent-prompt-path.sh")" "$probe_app/Contents/Resources/agent/conversation.md"
cp macos/Info.plist "$probe_app/Contents/Info.plist"
swiftc -swift-version 6 -warnings-as-errors -target arm64-apple-macosx26.0 \
    -I agent-bridge/include macos/AgentBridge.swift tests/AgentBridgeTests.swift \
    target/aarch64-apple-darwin/release/libecho_agent.a \
    -framework Security -framework SystemConfiguration \
    -o "$probe_app/Contents/MacOS/Echo"
clang -fsanitize=address -g -I agent-bridge/include tests/AgentBridgeMemory.c \
    target/aarch64-apple-darwin/release/libecho_agent.a \
    -framework Security -framework SystemConfiguration -framework CoreFoundation \
    -o "$probe_root/memory-test"
cd "$probe_root"
"$probe_app/Contents/MacOS/Echo" "$project_dir/tests/agent-model-server.py"
"$probe_root/memory-test" "$probe_app/Contents/Resources/agent/conversation.md"
echo "Bridge probe retained at $probe_root"
