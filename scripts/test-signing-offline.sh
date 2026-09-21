#!/bin/zsh
emulate -R zsh
# Exercise real ad-hoc signatures without accessing a signing or login Keychain.
setopt ERR_EXIT NO_UNSET PIPE_FAIL
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
temp_dir="$(mktemp -d "$project_dir/build/signing-offline.XXXXXX")"
trap 'rm -rf "$temp_dir"' EXIT

xcode_build() {
    xcodebuild -project Echo.xcodeproj -scheme Echo -configuration Release \
        CONFIGURATION_BUILD_DIR="$1" "${@:2}" build
}

# A configured personal identity must not reach ad-hoc signing. Nothing in the
# ad-hoc path consults it — the identity is the literal "-" — and this proves it
# from the outside.
export ECHO_SIGNING_IDENTITY=nonexistent-offline-test-identity
app="$temp_dir/adhoc/Echo.app"
xcode_build "$temp_dir/adhoc" > "$temp_dir/build.log" 2>&1
/usr/bin/codesign --verify --strict "$app"
/usr/bin/codesign -d --verbose=4 "$app" 2>&1 | /usr/bin/grep '^Signature=adhoc$' >/dev/null
# An ad-hoc build must stay Keychain-free and entitlement-free.
if [[ -n "$(/usr/bin/codesign -d --entitlements - "$app" 2>/dev/null)" ]]; then
    echo "FAIL: the ad-hoc bundle carries entitlements" >&2
    exit 1
fi
if /usr/bin/grep -q "security find-identity\|unlock-keychain" "$temp_dir/build.log"; then
    echo "FAIL: the ad-hoc build reached a Keychain" >&2
    exit 1
fi

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
# These all stop in the Echo target's first build phase, so none of them
# resolves an identity or reaches a Keychain.
guard_dir="$temp_dir/guards"
expect_rejection "unknown ECHO_SIGNING" xcode_build "$guard_dir" ECHO_SIGNING=invalid
expect_rejection "ECHO_SIGNING must be set" xcode_build "$guard_dir" ECHO_SIGNING=
# An empty identity is Xcode's "do not sign", which reports success by default.
expect_rejection "no development signing identity" xcode_build "$guard_dir" ECHO_SIGNING=development CODE_SIGN_IDENTITY=
expect_rejection "development signing requires a certificate" xcode_build "$guard_dir" ECHO_SIGNING=development CODE_SIGN_IDENTITY=-
expect_rejection "must not reach a Keychain" xcode_build "$guard_dir" \
    ECHO_SIGNING=adhoc "OTHER_CODE_SIGN_FLAGS=--timestamp=none --keychain $temp_dir/nonexistent.keychain-db"
# The resolver rejects an ad-hoc identity before it queries anything.
expect_rejection "certificate-backed signing identity" \
    env ECHO_SIGNING_IDENTITY=- /bin/zsh scripts/signing-identity.sh

# Running the app from Xcode must never launch an ad-hoc bundle: an ad-hoc
# signature is tied to the code hash, so each rebuild drops the app's Keychain
# authorization.
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

# Resource seals must still be enforced.
echo tampered > "$app/Contents/Resources/pets/chiyan/pet.json"
if /usr/bin/codesign --verify --strict "$app" 2>/dev/null; then
    echo "FAIL: a tampered resource passed strict verification" >&2
    exit 1
fi
echo "PASS: ad-hoc signing stays Keychain- and entitlement-free, the signing guards reject every unsafe mode, Run is bound to a certificate, and resource seals hold."
