#!/bin/bash
# Fetch and test Echo's production Core AI pin, without any local package overrides.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
resolved="$root/Echo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
repository="$(python3 -c 'import json,sys; print(next(p for p in json.load(open(sys.argv[1]))["pins"] if p["identity"] == "coreai-models")["location"])' "$resolved")"
revision="$(python3 -c 'import json,sys; print(next(p for p in json.load(open(sys.argv[1]))["pins"] if p["identity"] == "coreai-models")["state"]["revision"])' "$resolved")"
checkout="$(mktemp -d "${TMPDIR:-/tmp}/echo-coreai-regression.XXXXXX")"
printf 'Testing %s at %s\nClean checkout: %s\n' "$repository" "$revision" "$checkout"
git clone --no-checkout "$repository" "$checkout"
git -C "$checkout" checkout --detach "$revision"
test "$(git -C "$checkout" rev-parse HEAD)" = "$revision"
# Fail if the pin predates these regressions; a filter matching no tests must not pass.
test -f "$checkout/swift/Tests/LanguageModelsTests/IncrementalDetokenizerTests.swift"
grep -q "func fmToolCallArgumentsRender" "$checkout/swift/Tests/LanguageModelsTests/ToolCallDialectTests.swift"
# These dependency regressions exercise byte-split Chinese, SentencePiece spacing,
# incomplete bytes, and Qwen2.5/Qwen3 tool-call arguments including nested JSON nulls.
swift test --package-path "$checkout" --scratch-path "$checkout/.build" \
    --filter 'IncrementalDetokenizerTests|ToolCallDialectTests'
# Leave the checkout and build available for inspection, but require untouched sources.
test -z "$(git -C "$checkout" status --porcelain --untracked-files=no)"
