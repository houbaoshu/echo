#!/bin/zsh
# Builds SandboxProbeHost.app with the embedded SandboxProbeExec.xpc and signs both with an
# Apple Development identity (team signing; the XPC peer requirement is "same team").
# Usage: ./build.sh [OUTPUT_DIR]   (default: ./build, ignored by git)
emulate -R zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL
here="${0:a:h}"
out="${1:-$here/build}"
# ECHO_PROBE_VARIANT=exceptions: toolchain read-only exceptions + LSFileQuarantineEnabled=false on the service.
variant="${ECHO_PROBE_VARIANT:-base}"
identity="${ECHO_PROBE_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}"
[[ -n "$identity" ]] || { echo "No Apple Development identity found; set ECHO_PROBE_IDENTITY." >&2; exit 2 }
app="$out/SandboxProbeHost.app"
xpc="$app/Contents/XPCServices/local.chiyan.sandbox-probe.exec.xpc"
mkdir -p "$app/Contents/MacOS" "$xpc/Contents/MacOS"
flags=(-swift-version 5 -O -target arm64-apple-macos27.0 -sdk "$(xcrun --sdk macosx --show-sdk-path)")
xcrun swiftc $flags "$here"/Sources/Shared/*.swift "$here/Sources/Exec/main.swift" -o "$xpc/Contents/MacOS/SandboxProbeExec"
xcrun swiftc $flags "$here"/Sources/Shared/*.swift "$here/Sources/Host/main.swift" -o "$app/Contents/MacOS/SandboxProbeHost"
cp "$here/Support/Exec-Info.plist" "$xpc/Contents/Info.plist"
entitlements="$here/Support/Exec.entitlements"
if [[ "$variant" == exceptions ]]; then
    entitlements="$here/Support/Exec-exceptions.entitlements"
    /usr/libexec/PlistBuddy -c "Add :LSFileQuarantineEnabled bool false" "$xpc/Contents/Info.plist"
elif [[ "$variant" == executable || "$variant" == executable-rw || "$variant" == executable-sbpl ]]; then
    entitlements="$here/Support/Exec-$variant.entitlements"   # user-selected.executable measurement variants
elif [[ "$variant" == rwexception ]]; then
    entitlements="$here/Support/Exec-rwexception.entitlements"   # regenerate for your $TMPDIR before use
fi
cp "$here/Support/Host-Info.plist" "$app/Contents/Info.plist"
codesign --force --timestamp=none -s "$identity" --entitlements "$entitlements" "$xpc"
codesign --force --timestamp=none -s "$identity" "$app"   # host: no entitlements → not sandboxed
codesign --verify --deep --strict "$app"
echo "built: $app"
echo "signed with: $identity (variant: $variant)"
