#!/bin/zsh
emulate -R zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
if [[ $# -gt 1 ]]; then echo "Usage: $0 [existing-Echo.app]" >&2; exit 2; fi
if [[ $# -eq 0 ]]; then
    xcodebuild -project Echo.xcodeproj -scheme Echo -configuration Release \
        CONFIGURATION_BUILD_DIR="$project_dir/build/validation" build
fi
python3 tests/packaged-app-test.py "${1:-build/validation/Echo.app}"
