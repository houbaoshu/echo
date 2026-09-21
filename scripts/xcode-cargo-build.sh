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
# The two variables that must survive are the ones the existing chain already
# sets, so both entry points produce the same artifacts and cargo does not
# rebuild the workspace whenever they alternate.
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
# Xcode's SDKROOT is version-qualified (MacOSX27.0.sdk) where xcrun reports the
# unqualified path; resolve it the same way the command line build does.
unset SDKROOT
source scripts/swift-env.sh
typeset -a environment=(
    "HOME=$HOME"
    "PATH=${cargo_executable:h}:/usr/bin:/bin:/usr/sbin:/sbin"
    "SDKROOT=$SDKROOT"
    "MACOSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET"
)
# Honour a relocated Cargo or rustup, and proxy settings needed for a first fetch.
for name in CARGO_HOME RUSTUP_HOME RUSTUP_TOOLCHAIN SSL_CERT_FILE HTTPS_PROXY HTTP_PROXY ALL_PROXY NO_PROXY; do
    value="${(P)name-}"
    if [[ -n "$value" ]]; then environment+=("$name=$value"); fi
done
# Always release: the Swift side has only ever linked the optimized libraries, and
# an Xcode configuration does not change which Rust profile the app expects.
exec /usr/bin/env -i "${environment[@]}" \
    "$cargo_executable" build --locked --release --target aarch64-apple-darwin
