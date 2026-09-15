#!/bin/zsh
# Resolve resources from echo-agent's actual Cargo dependency, including patches.
emulate -R zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL
agent_project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cargo metadata --manifest-path "$agent_project_dir/Cargo.toml" --locked --offline \
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
'
