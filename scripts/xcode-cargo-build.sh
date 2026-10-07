#!/bin/zsh
emulate -R zsh
# Build the Rust static libraries the app target links against.
#
# cargo runs through cargo-isolated.sh, which finds it and keeps Xcode's build
# environment away from it; EchoRustTests runs cargo test through the same script.
#
setopt ERR_EXIT NO_UNSET PIPE_FAIL
: "${ECHO_CARGO_TARGET_DIR:?Xcode must set ECHO_CARGO_TARGET_DIR to an output directory}"
# Always release: the Swift side has only ever linked the optimized libraries, and
# an Xcode configuration does not change which Rust profile the app expects.
exec "${0:a:h}/cargo-isolated.sh" build --locked --release --target aarch64-apple-darwin --target-dir "$ECHO_CARGO_TARGET_DIR"
