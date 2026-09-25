#!/bin/zsh
# System validation only: consume Xcode products, never build or re-sign them.
emulate -R zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL
app="" first="" rebuilt="" unrelated=""
while (( $# )); do
    case "$1" in
        --app) app="$2"; shift 2 ;;
        --keychain-first) first="$2"; shift 2 ;;
        --keychain-rebuilt) rebuilt="$2"; shift 2 ;;
        --keychain-unrelated) unrelated="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 --app BUILT_APP [--keychain-first APP --keychain-rebuilt APP --keychain-unrelated APP]"
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done
[[ -d "$app/Contents" ]] || { echo "--app must name an Xcode-built App" >&2; exit 2 }
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/echo-signing.XXXXXX")"
test_service=""
cleanup() {
    if [[ -n "$test_service" ]]; then
        /usr/bin/security delete-generic-password -s "$test_service" -a test-only >/dev/null 2>&1 || true
    fi
    rm -rf "$temp_dir"
}
trap cleanup EXIT
/usr/bin/codesign --verify --deep --strict "$app"
# The default Release acceptance is ad-hoc and entitlement-free.
/usr/bin/codesign -d --verbose=4 "$app" 2>&1 | /usr/bin/grep '^Signature=adhoc$' >/dev/null
[[ -z "$(/usr/bin/codesign -d --entitlements - "$app" 2>/dev/null)" ]] || {
    echo "FAIL: the Release bundle carries entitlements" >&2; exit 1
}
ditto "$app" "$temp_dir/tampered.app"
echo tampered > "$temp_dir/tampered.app/Contents/Resources/pets/chiyan/pet.json"
if /usr/bin/codesign --verify --strict "$temp_dir/tampered.app" 2>/dev/null; then
    echo "FAIL: a tampered resource passed strict verification" >&2; exit 1
fi
echo "PASS: ad-hoc signature, no entitlements, resource seal rejects tampering"
[[ -n "$first$rebuilt$unrelated" ]] || exit 0
for fixture in "$first" "$rebuilt" "$unrelated"; do
    [[ -x "$fixture/Contents/MacOS/Echo" ]] || {
        echo "All three prebuilt Keychain fixtures are required" >&2; exit 2
    }
done
for version in 0 1; do
    fixture="$first"; [[ "$version" == 0 ]] || fixture="$rebuilt"
    /usr/bin/codesign --verify --strict -R '=anchor apple generic' "$fixture"
    /usr/bin/codesign -d -r- "$fixture" 2>&1 | sed -n 's/^designated => //p' > "$temp_dir/$version.requirement"
    /usr/bin/codesign -d --verbose=4 "$fixture" 2>&1 | sed -n 's/^CDHash=//p' > "$temp_dir/$version.hash"
done
[[ -s "$temp_dir/0.requirement" && -s "$temp_dir/0.hash" && -s "$temp_dir/1.hash" ]]
cmp -s "$temp_dir/0.requirement" "$temp_dir/1.requirement"
if cmp -s "$temp_dir/0.hash" "$temp_dir/1.hash"; then
    echo "FAIL: fixtures must have different code hashes" >&2; exit 1
fi
requirement="$(cat "$temp_dir/0.requirement")"
/usr/bin/codesign --verify --strict -R "=$requirement" "$rebuilt"
/usr/bin/codesign --verify --strict "$unrelated"
if /usr/bin/codesign --verify -R "=$requirement" "$unrelated" >/dev/null 2>&1; then
    echo "FAIL: unrelated signer matches the development identity" >&2; exit 1
fi
test_service="local.chiyan.keychain-regression.$(/usr/bin/uuidgen)"
installed="$temp_dir/installed/Echo.app"
mkdir -p "$temp_dir/installed"
ditto "$first" "$installed"
"$installed/Contents/MacOS/Echo" create "$test_service"
"$installed/Contents/MacOS/Echo" read "$test_service"
rm -rf "$installed"
ditto "$rebuilt" "$installed"
"$installed/Contents/MacOS/Echo" read "$test_service"
rm -rf "$installed"
ditto "$unrelated" "$installed"
"$installed/Contents/MacOS/Echo" expect-denied "$test_service"
echo "PASS: same-path relaunch/rebuild keeps access; unrelated signature is rejected"
