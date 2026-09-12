#!/bin/zsh
emulate -R zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
script_name="$0"
usage() {
    echo "Usage: $script_name [--signing ad-hoc|development] [--run]"
    echo "Default: ad-hoc validation build in build/validation/Echo.app (no signing Keychain)."
    echo "Use --signing development for build/Echo.app; --run requires this mode."
}
signing_mode=ad-hoc
run=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --signing)
            if [[ $# -lt 2 ]]; then usage >&2; exit 1; fi
            signing_mode="$2"
            shift 2
            ;;
        --run) run=true; shift ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 1 ;;
    esac
done
case "$signing_mode" in
    ad-hoc) app_dir="$project_dir/build/validation/Echo.app" ;;
    development) app_dir="$project_dir/build/Echo.app" ;;
    *) usage >&2; exit 1 ;;
esac
if [[ "$run" == true && "$signing_mode" != development ]]; then
    echo "Use --signing development --run to launch with a certificate-backed identity for Keychain access." >&2
    exit 1
fi
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    echo "This app requires an Apple Silicon Mac." >&2
    exit 1
fi
source scripts/swift-env.sh
cargo build --locked --release --target aarch64-apple-darwin
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources/pets/chiyan"
# Include new app sources automatically, matching the test scripts' discovery.
typeset -a sources=(macos/*.swift)
swiftc -swift-version 6 -O -target arm64-apple-macosx26.0 \
    -I runtime/include "${sources[@]}" \
    target/aarch64-apple-darwin/release/libecho_runtime.a \
    -framework AppKit -framework SwiftUI -framework Security -framework AVFoundation -lz \
    -o "$app_dir/Contents/MacOS/Echo"
cp macos/Info.plist "$app_dir/Contents/Info.plist"
rsync -a --delete --exclude .DS_Store assets/pets/ "$app_dir/Contents/Resources/pets/"
/bin/zsh "$project_dir/scripts/sign-app.sh" --signing "$signing_mode" "$app_dir"
echo "Built $app_dir (signing: $signing_mode)"
if [[ "$run" == true ]]; then open "$app_dir"; fi
