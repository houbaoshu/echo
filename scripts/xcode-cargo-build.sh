#!/bin/zsh
emulate -R zsh
# Build the Rust static libraries the app target links against.
#
# Xcode exports a whole build environment (CC, LD, CFLAGS, SDKROOT, …) that both
# the cc crate and rustc's host toolchain pick up. Letting it reach cargo once
# already produced proc-macro dylibs that dyld refuses to load ("mis-aligned
# LINKEDIT string pool"), breaking every plain command line build until
# target/release was deleted. cargo therefore runs in a minimal environment.
#
setopt ERR_EXIT NO_UNSET PIPE_FAIL
# Resolve the caller's toolchain before isolating Xcode's environment. GUI
# builds may omit Cargo from PATH, so also check relocated and default homes.
if ! cargo_executable="$(PATH="$PATH:${CARGO_HOME:-$HOME/.cargo}/bin:$HOME/.cargo/bin" whence -p cargo)"; then
    echo "error: cargo not found in PATH or the Cargo bin directories." >&2
    exit 1
fi
cargo_executable="${cargo_executable:a}"
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
# Do not export Xcode's SDK/deployment flags to Rust host proc macros. On Xcode
# 27 they can produce a dylib with a misaligned LINKEDIT string table. Cargo's
# target triple and the selected developer toolchain resolve the SDK themselves.
: "${ECHO_CARGO_TARGET_DIR:?Xcode must set ECHO_CARGO_TARGET_DIR to an output directory}"
typeset -a environment=(
    "HOME=$HOME"
    "PATH=${cargo_executable:h}:/usr/bin:/bin:/usr/sbin:/sbin"
)
# Honour a relocated Cargo or rustup, and proxy settings needed for a first fetch.
for name in CARGO_HOME RUSTUP_HOME RUSTUP_TOOLCHAIN SSL_CERT_FILE HTTPS_PROXY HTTP_PROXY ALL_PROXY NO_PROXY; do
    value="${(P)name-}"
    if [[ -n "$value" ]]; then environment+=("$name=$value"); fi
done
# Always release: the Swift side has only ever linked the optimized libraries, and
# an Xcode configuration does not change which Rust profile the app expects.
exec /usr/bin/env -i "${environment[@]}" \
    "$cargo_executable" build --locked --release --target aarch64-apple-darwin --target-dir "$ECHO_CARGO_TARGET_DIR"
