#!/bin/zsh
emulate -R zsh
# Exercise real ad-hoc signatures without accessing a signing or login Keychain.
setopt ERR_EXIT NO_UNSET PIPE_FAIL
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
source scripts/swift-env.sh
temp_dir="$(mktemp -d "$project_dir/build/signing-offline.XXXXXX")"
trap 'rm -rf "$temp_dir"' EXIT
app="$temp_dir/Echo.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp macos/Info.plist "$app/Contents/Info.plist"
cat > "$temp_dir/main.swift" <<'SWIFT'
print("PASS: ad-hoc executable runs")
SWIFT
swiftc -swift-version 6 -warnings-as-errors -target arm64-apple-macosx27.0 \
    "$temp_dir/main.swift" -o "$app/Contents/MacOS/Echo"
echo original > "$app/Contents/Resources/marker"

assert_ad_hoc() {
    /usr/bin/codesign --verify --strict "$app"
    /usr/bin/codesign -d --verbose=4 "$app" 2>&1 | /usr/bin/grep '^Signature=adhoc$' >/dev/null
    "$app/Contents/MacOS/Echo"
}

# A configured personal identity must not affect either validation entry point.
export ECHO_SIGNING_IDENTITY=nonexistent-offline-test-identity
/bin/zsh scripts/sign-app.sh "$app"
assert_ad_hoc
/bin/zsh scripts/sign-app.sh --signing ad-hoc "$app"
assert_ad_hoc

expect_failure() {
    if "$@" > "$temp_dir/failure.log" 2>&1; then
        echo "FAIL: expected rejection: $*" >&2
        exit 1
    fi
}
expect_failure /bin/zsh scripts/sign-app.sh --signing invalid "$app"
expect_failure /bin/zsh scripts/sign-app.sh --signing
expect_failure /bin/zsh scripts/sign-app.sh "$app" extra
expect_failure /bin/zsh scripts/build.sh --signing invalid
expect_failure /bin/zsh scripts/build.sh --signing
expect_failure /bin/zsh scripts/build.sh --run
expect_failure /bin/zsh scripts/build.sh --signing ad-hoc --run
# Reject an ad-hoc identity in certificate mode before touching any Keychain.
expect_failure env ECHO_SIGNING_IDENTITY=- /bin/zsh scripts/sign-app.sh --signing development "$app"

# The same guarantees at the Xcode entry point, which owns signing for the app.
# All of these stop in the Echo target's first build phase, so none of them
# resolves an identity or reaches a Keychain.
expect_rejection() {
    local pattern="$1"
    shift
    if "$@" > "$temp_dir/failure.log" 2>&1; then
        echo "FAIL: expected rejection: $*" >&2
        exit 1
    fi
    if ! /usr/bin/grep -q "$pattern" "$temp_dir/failure.log"; then
        echo "FAIL: rejected for the wrong reason, expected /$pattern/: $*" >&2
        exit 1
    fi
}
build_dir="$temp_dir/xcodebuild"
xcode_build() {
    xcodebuild -project Echo.xcodeproj -scheme Echo -configuration Release \
        CONFIGURATION_BUILD_DIR="$build_dir" "$@" build
}
expect_rejection "unknown ECHO_SIGNING" xcode_build ECHO_SIGNING=invalid
expect_rejection "ECHO_SIGNING must be set" xcode_build ECHO_SIGNING=
# An empty identity is Xcode's "do not sign", which reports success by default.
expect_rejection "no development signing identity" xcode_build ECHO_SIGNING=development CODE_SIGN_IDENTITY=
expect_rejection "development signing requires a certificate" xcode_build ECHO_SIGNING=development CODE_SIGN_IDENTITY=-
expect_rejection "must not reach a Keychain" xcode_build \
    ECHO_SIGNING=adhoc "OTHER_CODE_SIGN_FLAGS=--timestamp=none --keychain $temp_dir/nonexistent.keychain-db"

# Running the app from Xcode must never launch an ad-hoc bundle: an ad-hoc
# signature is tied to the code hash, so each rebuild drops the app's Keychain
# authorization. This replaces build.sh's refusal to combine --run with ad-hoc.
scheme="Echo.xcodeproj/xcshareddata/xcschemes/Echo.xcscheme"
run_configuration="$(python3 - "$scheme" <<'PYTHON'
import sys, xml.etree.ElementTree as ElementTree
print(ElementTree.parse(sys.argv[1]).getroot().find('LaunchAction').get('buildConfiguration'))
PYTHON
)"
run_signing="$(xcodebuild -project Echo.xcodeproj -target Echo -configuration "$run_configuration" \
    -showBuildSettings 2>/dev/null | sed -nE 's/^ +ECHO_SIGNING = (.*)$/\1/p' | head -1)"
if [[ "$run_signing" != development ]]; then
    echo "FAIL: the scheme's Run action builds configuration $run_configuration, which signs $run_signing" >&2
    exit 1
fi

# Resource seals must still be enforced, and a signing failure must propagate.
echo tampered > "$app/Contents/Resources/marker"
expect_failure /usr/bin/codesign --verify --strict "$app"
expect_failure /bin/zsh scripts/sign-app.sh "$temp_dir/missing.app"
echo "PASS: default/explicit ad-hoc signing, identity isolation, option validation, signature failures, and the Xcode signing guards."
