#!/bin/zsh
emulate -R zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
# A disposable app bundle tests Bundle.main from a cwd with no source/config files,
# which is why this suite is an app target rather than an XCTest bundle. Build it
# before sourcing swift-env.sh: an inherited SDKROOT would override the project's.
probe_root="$(mktemp -d /private/tmp/echo-agent-probe.XXXXXX)"
xcodebuild -project Echo.xcodeproj -target AgentBridgeProbe -configuration Release \
    CONFIGURATION_BUILD_DIR="$probe_root" build
source scripts/swift-env.sh
cargo test --locked -p echo-agent
clang -fsanitize=address -g -I agent-bridge/include tests/AgentBridgeMemory.c \
    target/aarch64-apple-darwin/release/libecho_agent.a \
    -framework Security -framework SystemConfiguration -framework CoreFoundation \
    -o "$probe_root/memory-test"
cd "$probe_root"
"$probe_root/Echo.app/Contents/MacOS/Echo" "$project_dir/tests/agent-model-server.py"
"$probe_root/memory-test" "$probe_root/Echo.app/Contents/Resources/agent/conversation.md"
echo "Bridge probe retained at $probe_root"
