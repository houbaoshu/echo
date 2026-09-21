#!/bin/zsh
emulate -R zsh
# Stage the Agent conversation prompt where the test suites look for it.
#
# AgentSessionTests and AgentVoiceTests resolve build/agent/conversation.md
# relative to the working directory, the way the shell scripts staged it before
# running them. The path inside the resolved mini-agent-rs dependency is only
# known after Cargo resolves the graph, so this cannot be a file reference.
setopt ERR_EXIT NO_UNSET PIPE_FAIL
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
export PATH="$HOME/.cargo/bin:$PATH"
mkdir -p build/agent
source_prompt="$(/bin/zsh "$project_dir/scripts/agent-prompt-path.sh")"
/bin/cp "$source_prompt" build/agent/.conversation.md.partial
/bin/mv build/agent/.conversation.md.partial build/agent/conversation.md
