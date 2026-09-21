#!/bin/zsh
emulate -R zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
# The suite exercises the production AgentTaskSource(settings:), which resolves
# its prompt from Bundle.main.resourceURL — for a bare executable, the directory
# it sits in. That is why this stays a command line tool rather than an XCTest
# bundle, and why the prompt is staged next to the product.
/bin/zsh scripts/xcode-stage-agent-prompt.sh
xcodebuild -project Echo.xcodeproj -target EchoAgentSessionTests -configuration Debug \
    CONFIGURATION_BUILD_DIR="$project_dir/build" build
build/EchoAgentSessionTests "$project_dir"
