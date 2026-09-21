#!/bin/zsh
emulate -R zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
# The target generates its audio fixtures before Xcode signs the bundle.
xcodebuild -project Echo.xcodeproj -target AppleSpeechDeviceProbe -configuration Release \
    CONFIGURATION_BUILD_DIR="$project_dir/build/apple-speech-device" build
app_dir="$project_dir/build/apple-speech-device/AppleSpeechCheck.app"
"$app_dir/Contents/MacOS/AppleSpeechCheck" "$@"
