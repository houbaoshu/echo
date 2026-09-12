#!/bin/zsh
emulate -R zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
source scripts/swift-env.sh
swiftc -swift-version 6 -warnings-as-errors -target arm64-apple-macosx26.0 \
    macos/TaskStore.swift macos/ModelTaskSource.swift macos/SettingsStore.swift \
    macos/VoiceProtocol.swift macos/VoiceDiagnostics.swift tests/ChatTests.swift tests/ModelTests.swift \
    -framework Security -lz -o build/chat-tests
build/chat-tests
