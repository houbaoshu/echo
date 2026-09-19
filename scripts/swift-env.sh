#!/bin/zsh
emulate -R zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL
# Use the default SDK selected by the active developer directory (macOS 27).
if [[ -z "${SDKROOT:-}" ]]; then
    # Keep fallible command substitution separate from export so a failed SDK
    # lookup cannot be masked by a successful outer command.
    sdk_path="$(xcrun --show-sdk-path)"
    SDKROOT="$sdk_path"
fi
export SDKROOT
if [[ ! -d "$SDKROOT" ]]; then
    echo "Install a macOS 27 SDK or set SDKROOT to a compatible SDK." >&2
    exit 1
fi
export CLANG_MODULE_CACHE_PATH="$project_dir/build/module-cache"
export SWIFT_MODULECACHE_PATH="$CLANG_MODULE_CACHE_PATH"
export MACOSX_DEPLOYMENT_TARGET=27.0
mkdir -p "$project_dir/build"
