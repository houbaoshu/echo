#!/bin/zsh
emulate -R zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
# Under NATIVE_SHORTCUT_TESTS the suite runs NSApplication.run() and ends with
# exit(0), which an XCTest host reports as a crash. The native menu routing and
# real pointer events these scenarios verify need that event loop, so this half
# stays an executable, driven from here; the hosted half is an XCTest bundle in
# the EchoTests scheme.
xcodebuild -project Echo.xcodeproj -target EchoShortcutUITests -configuration Debug \
    CONFIGURATION_BUILD_DIR="$project_dir/build" build
build/EchoShortcutUITests
