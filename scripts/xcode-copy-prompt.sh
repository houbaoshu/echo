#!/bin/zsh
emulate -R zsh
# Stage the Agent conversation prompt into the bundle.
#
# The prompt lives inside echo-agent's resolved mini-agent-rs dependency, whose
# directory is only known after Cargo resolves the graph — including patches — so
# it cannot be a static file reference in the project.
setopt ERR_EXIT NO_UNSET PIPE_FAIL
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
if [[ -z "${TARGET_BUILD_DIR:-}" || -z "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ]]; then
    echo "Run this from an Xcode build phase; it needs TARGET_BUILD_DIR." >&2
    exit 1
fi
# Xcode's PATH does not include the Cargo bin directory.
export PATH="$HOME/.cargo/bin:$PATH"
destination="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/agent"
mkdir -p "$destination"
source_prompt="$(/bin/zsh "$project_dir/scripts/agent-prompt-path.sh")"
# Copy through a temporary name so an interrupted build cannot leave a partial
# prompt that a later build would treat as current.
/bin/cp "$source_prompt" "$destination/.conversation.md.partial"
/bin/mv "$destination/.conversation.md.partial" "$destination/conversation.md"
