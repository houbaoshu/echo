#!/bin/zsh
emulate -R zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
source scripts/swift-env.sh
# Compile the production adapter against a controllable bridge for receipt races.
swiftc -swift-version 6 -warnings-as-errors -target arm64-apple-macosx26.0 \
    macos/AgentTaskSource.swift macos/AgentConnectionTester.swift \
    macos/TaskStore.swift macos/ModelTaskSource.swift macos/SettingsStore.swift \
    macos/VoiceProtocol.swift macos/VoiceDiagnostics.swift tests/AgentTaskSourceTests.swift \
    -framework Security -o build/agent-task-source-tests
build/agent-task-source-tests
