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

# Resource seals must still be enforced, and a signing failure must propagate.
echo tampered > "$app/Contents/Resources/marker"
expect_failure /usr/bin/codesign --verify --strict "$app"
expect_failure /bin/zsh scripts/sign-app.sh "$temp_dir/missing.app"
echo "PASS: default/explicit ad-hoc signing, identity isolation, option validation, and signature failures."
