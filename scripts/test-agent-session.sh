#!/bin/zsh
emulate -R zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
source scripts/swift-env.sh
# The saved-settings source resolves its prompt through Bundle.main.
mkdir -p build/agent
cp ../mini-agent-agent-core-exp/config/prompts/conversation.md build/agent/conversation.md
cargo build --locked --release --target aarch64-apple-darwin
typeset -a sources=()
for source_file in macos/*.swift; do
    if [[ "$source_file" != macos/main.swift ]]; then sources+=("$source_file"); fi
done
swiftc -swift-version 6 -warnings-as-errors -target arm64-apple-macosx26.0 \
    -I runtime/include -I agent-bridge/include "${sources[@]}" tests/AgentSessionTests.swift \
    target/aarch64-apple-darwin/release/libecho_runtime.a \
    target/aarch64-apple-darwin/release/libecho_agent.a \
    -framework AppKit -framework SwiftUI -framework Security -framework AVFoundation -framework Speech -lz \
    -o build/agent-session-tests
build/agent-session-tests "$project_dir"
