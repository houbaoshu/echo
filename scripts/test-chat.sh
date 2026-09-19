#!/bin/zsh
emulate -R zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
source scripts/swift-env.sh
cargo build --locked --release --target aarch64-apple-darwin
swiftc -swift-version 6 -warnings-as-errors -target arm64-apple-macosx27.0 \
    -I agent-bridge/include macos/AgentWire.swift macos/AgentBridge.swift macos/AgentConnectionTester.swift \
    macos/TaskStore.swift macos/ModelTaskSource.swift macos/SettingsStore.swift \
    macos/VoiceProtocol.swift macos/VoiceDiagnostics.swift tests/ChatTests.swift tests/ModelTests.swift tests/SettingsTests.swift \
    target/aarch64-apple-darwin/release/libecho_agent.a -framework Security -lz -o build/chat-tests
build/chat-tests
