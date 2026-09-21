#!/bin/zsh
emulate -R zsh
# Exercise real ad-hoc signatures without accessing a signing or login Keychain.
setopt ERR_EXIT NO_UNSET PIPE_FAIL
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
mkdir -p "$project_dir/build"
temp_dir="$(mktemp -d "$project_dir/build/signing-offline.XXXXXX")"
trap 'rm -rf "$temp_dir"' EXIT

xcode_build() {
    xcodebuild -project Echo.xcodeproj -scheme Echo -configuration Release \
        CONFIGURATION_BUILD_DIR="$1" "${@:2}" build
}

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

# Running the app from Xcode must never launch an ad-hoc bundle: an ad-hoc
# signature is tied to the code hash, so each rebuild drops the app's Keychain
# authorization.
scheme="Echo.xcodeproj/xcshareddata/xcschemes/Echo.xcscheme"
run_configuration="$(python3 - "$scheme" <<'PYTHON'
import sys, xml.etree.ElementTree as ElementTree
print(ElementTree.parse(sys.argv[1]).getroot().find('LaunchAction').get('buildConfiguration'))
PYTHON
)"
# Inspect Xcode's resolved configuration without requiring an installed identity.
xcodebuild -project Echo.xcodeproj -target Echo -configuration "$run_configuration" \
    -showBuildSettings -json > "$temp_dir/run-settings.json"
python3 - "$temp_dir/run-settings.json" <<'PYTHON'
import json, sys
settings = next(item['buildSettings'] for item in json.load(open(sys.argv[1])) if item['target'] == 'Echo')
assert settings['CODE_SIGN_IDENTITY'] == 'Apple Development', 'Run must use Apple Development signing'
assert settings['CODE_SIGNING_ALLOWED'] == 'YES', 'Run must allow signing'
assert settings['CODE_SIGNING_REQUIRED'] == 'YES', 'Run must require signing'
flags = settings.get('OTHER_CODE_SIGN_FLAGS', '').split()
assert '--keychain' not in flags and '-r' not in flags, 'Run must use native signing requirements'
PYTHON

# Resource seals must still be enforced.
echo tampered > "$app/Contents/Resources/pets/chiyan/pet.json"
if /usr/bin/codesign --verify --strict "$app" 2>/dev/null; then
    echo "FAIL: a tampered resource passed strict verification" >&2
    exit 1
fi
echo "PASS: ad-hoc signing stays Keychain- and entitlement-free, Run selects Apple Development signing, and resource seals hold."
