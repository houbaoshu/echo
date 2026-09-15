#!/bin/zsh
# Rust/C-only v2 checks; Swift migration is the next planned stage.
emulate -R zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
source scripts/swift-env.sh
cargo test --locked --offline -p echo-agent
cargo build --locked --offline --release --target aarch64-apple-darwin -p echo-agent
probe_root="$(mktemp -d /private/tmp/echo-agent-ffi.XXXXXX)"
cp "$(/bin/zsh "$project_dir/scripts/agent-prompt-path.sh")" "$probe_root/conversation.md"
clang -fsanitize=address -g -I agent-bridge/include tests/AgentBridgeMemory.c \
    target/aarch64-apple-darwin/release/libecho_agent.a \
    -framework Security -framework SystemConfiguration -framework CoreFoundation \
    -o "$probe_root/memory-test"
cd "$probe_root"
"$probe_root/memory-test" "$probe_root/conversation.md"
echo "C ABI probe retained at $probe_root"
