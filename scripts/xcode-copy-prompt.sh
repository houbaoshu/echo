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
export PATH="$PATH:${CARGO_HOME:-$HOME/.cargo}/bin:$HOME/.cargo/bin"
destination="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/agent"
mkdir -p "$destination"
source_prompt="$(cargo metadata --manifest-path "$project_dir/Cargo.toml" --locked --offline \
    --format-version 1 --filter-platform aarch64-apple-darwin | python3 -c '
import json, pathlib, sys
metadata = json.load(sys.stdin)
packages = {p["id"]: p for p in metadata["packages"]}
bridge = next(p for p in packages.values() if p["name"] == "echo-agent")
node = next(n for n in metadata["resolve"]["nodes"] if n["id"] == bridge["id"])
dependencies = [packages[d["pkg"]] for d in node["deps"] if packages[d["pkg"]]["name"] == "mini-agent-rs"]
if len(dependencies) != 1:
    sys.exit("Expected one resolved mini-agent-rs dependency")
prompt = pathlib.Path(dependencies[0]["manifest_path"]).parent / "config/prompts/conversation.md"
if not prompt.is_file():
    sys.exit("Resolved Mini Agent dependency has no conversation prompt")
print(prompt)
')"
# Copy through a temporary name so an interrupted build cannot leave a partial
# prompt that a later build would treat as current.
/bin/cp "$source_prompt" "$destination/.conversation.md.partial"
/bin/mv "$destination/.conversation.md.partial" "$destination/conversation.md"
