#!/bin/zsh
emulate -R zsh
# Default regression is Keychain-free; --keychain opts into OS integration.
setopt ERR_EXIT NO_UNSET PIPE_FAIL
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
case "${1:-}" in
    "")
        if [[ $# -ne 0 ]]; then echo "Usage: $0 [--keychain]" >&2; exit 1; fi
        exec /bin/zsh scripts/test-signing-offline.sh
        ;;
    --keychain)
        if [[ $# -ne 1 ]]; then echo "Usage: $0 [--keychain]" >&2; exit 1; fi
        echo "Running certificate signing and real Keychain authorization tests (outside the sandbox)."
        ;;
    --help|-h)
        echo "Usage: $0 [--keychain]"
        echo "Default: ad-hoc signing regression, without Keychain access."
        echo "--keychain: certificate-backed signing and synthetic login-Keychain credentials; run outside the sandbox."
        exit 0
        ;;
    *) echo "Usage: $0 [--keychain]" >&2; exit 1 ;;
esac
mkdir -p build
temp_dir="$(mktemp -d "$project_dir/build/signing-test.XXXXXX")"
test_service="local.chiyan.keychain-regression.$(/usr/bin/uuidgen)"
cleanup() {
    /usr/bin/security delete-generic-password -s "$test_service" -a test-only >/dev/null 2>&1 || true
    rm -rf "$temp_dir"
}
trap cleanup EXIT
source scripts/swift-env.sh
for version in 0 1; do
    app="$temp_dir/$version/Echo.app"
    mkdir -p "$app/Contents/MacOS"
    cp macos/Info.plist "$app/Contents/Info.plist"
    typeset -a flags=()
    if [[ "$version" == 1 ]]; then flags+=(-D SECOND_BUILD); fi
    swiftc -suppress-warnings "${flags[@]}" tests/KeychainAuthorizationProbe.swift \
        -framework Security -o "$app/Contents/MacOS/Echo"
    /bin/zsh scripts/sign-app.sh --signing development "$app"
    /usr/bin/codesign -d -r- "$app" 2>&1 | sed -n 's/^designated => //p' > "$temp_dir/$version.requirement"
    /usr/bin/codesign -d --verbose=4 "$app" 2>&1 | sed -n 's/^CDHash=//p' > "$temp_dir/$version.hash"
done
test -s "$temp_dir/0.requirement"
test -s "$temp_dir/0.hash"
test -s "$temp_dir/1.hash"
cmp -s "$temp_dir/0.requirement" "$temp_dir/1.requirement"
if cmp -s "$temp_dir/0.hash" "$temp_dir/1.hash"; then
    echo "FAIL: fixtures must have different code hashes" >&2
    exit 1
fi
requirement="$(cat "$temp_dir/0.requirement")"
/usr/bin/codesign --verify --strict -R "=$requirement" "$temp_dir/1/Echo.app"
# Use the same installation path, with separate processes for each launch.
installed="$temp_dir/installed/Echo.app"
mkdir -p "$(dirname "$installed")"
ditto "$temp_dir/0/Echo.app" "$installed"
"$installed/Contents/MacOS/Echo" create "$test_service"
"$installed/Contents/MacOS/Echo" read "$test_service"
rm -rf "$installed"
ditto "$temp_dir/1/Echo.app" "$installed"
if /usr/bin/codesign --verify -R '=anchor apple generic' "$installed" >/dev/null 2>&1; then
    "$installed/Contents/MacOS/Echo" read "$test_service"
    echo "PASS: Apple-signed code changes preserve Keychain access."
else
    "$installed/Contents/MacOS/Echo" expect-denied "$test_service"
    echo "LIMITATION: self-signed code preserves its requirement, but a changed cdhash needs a new Keychain grant."
fi
# An unrelated ad-hoc build with the same bundle ID must not inherit access.
/usr/bin/codesign --force --sign - "$temp_dir/1/Echo.app" >/dev/null 2>&1
if /usr/bin/codesign --verify -R "=$requirement" "$temp_dir/1/Echo.app" >/dev/null 2>&1; then
    echo "FAIL: an unrelated signer matched the development identity" >&2
    exit 1
fi
rm -rf "$installed"
ditto "$temp_dir/1/Echo.app" "$installed"
"$installed/Contents/MacOS/Echo" expect-denied "$test_service"
echo "PASS: same-build relaunch works; an unrelated signer is rejected."
