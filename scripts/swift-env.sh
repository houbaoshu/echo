#!/bin/zsh
emulate -R zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL
# Target the installed macOS 26 SDK. The macOS 27 beta SwiftUI interface
# requires macro plugins not shipped by Command Line Tools 6.4.
if [[ -z "${SDKROOT:-}" ]]; then
    # Keep fallible command substitution separate from export and dirname so
    # a failed SDK lookup cannot be masked by a successful outer command.
    sdk_path="$(xcrun --show-sdk-path)"
    SDKROOT="${sdk_path:h}/MacOSX26.sdk"
fi
export SDKROOT
if [[ ! -d "$SDKROOT" ]]; then
    echo "Install a macOS 26 SDK or set SDKROOT to a compatible SDK." >&2
    exit 1
fi
export CLANG_MODULE_CACHE_PATH="$project_dir/build/module-cache"
export SWIFT_MODULECACHE_PATH="$CLANG_MODULE_CACHE_PATH"
export MACOSX_DEPLOYMENT_TARGET=26.0
mkdir -p "$project_dir/build"
