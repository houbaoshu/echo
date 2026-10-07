#!/bin/zsh
emulate -R zsh
# Run cargo in the workspace root with a minimal environment, passing every argument
# through. This is the only place that decides how cargo is found and which variables
# reach it. Xcode's Rust build phase (xcode-cargo-build.sh) and the cargo test runs in
# EchoRustTests (tests/support/CargoTestRun.swift) both start cargo through here, so
# the build and the tests always see the same toolchain and environment.
#
# Xcode exports a whole build environment (CC, LD, CFLAGS, SDKROOT, …) that both
# the cc crate and rustc's host toolchain pick up. Letting it reach cargo once
# already produced proc-macro dylibs that dyld refuses to load ("mis-aligned
# LINKEDIT string pool"), breaking every plain command line build until
# target/release was deleted. A test process inherits the same kind of environment
# from Xcode, so cargo always runs in a minimal one.
#
setopt ERR_EXIT NO_UNSET PIPE_FAIL
# Resolve the caller's toolchain before isolating the environment. GUI builds and
# test runs may omit Cargo from PATH, so also check relocated and default homes.
if ! cargo_executable="$(PATH="$PATH:${CARGO_HOME:-$HOME/.cargo}/bin:$HOME/.cargo/bin" whence -p cargo)"; then
    echo "error: cargo not found in PATH or the Cargo bin directories." >&2
    exit 1
fi
cargo_executable="${cargo_executable:a}"
cd "${0:a:h}/.."
# Do not export Xcode's SDK/deployment flags to Rust host proc macros. On Xcode
# 27 they can produce a dylib with a misaligned LINKEDIT string table. Cargo's
# target triple and the selected developer toolchain resolve the SDK themselves.
typeset -a environment=(
    "HOME=$HOME"
    "PATH=${cargo_executable:h}:/usr/bin:/bin:/usr/sbin:/sbin"
)
# Honour a relocated Cargo or rustup, and proxy settings needed for a first fetch.
for name in CARGO_HOME RUSTUP_HOME RUSTUP_TOOLCHAIN SSL_CERT_FILE HTTPS_PROXY HTTP_PROXY ALL_PROXY NO_PROXY; do
    value="${(P)name-}"
    if [[ -n "$value" ]]; then environment+=("$name=$value"); fi
done
exec /usr/bin/env -i "${environment[@]}" "$cargo_executable" "$@"
