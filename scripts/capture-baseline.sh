#!/bin/zsh
emulate -R zsh
# Record the build-chain-independent facts about a bundle, for compare-bundle.sh.
setopt ERR_EXIT NO_UNSET PIPE_FAIL
script_name="$0"
usage() {
    echo "Usage: $script_name /path/to/Echo.app /path/to/output-dir"
    echo "Captures payload, Info.plist, linked libraries, signing metadata and resource hashes."
}
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then usage; exit 0; fi
if [[ $# -ne 2 ]]; then usage >&2; exit 1; fi
app="$1"
out="$2"
if [[ ! -d "$app/Contents" ]]; then echo "Not an app bundle: $app" >&2; exit 1; fi
mkdir -p "$out"

# Payload, relative and sorted: link order and filesystem order must not matter.
( cd "$app" && find . \( -type f -o -type l \) -print | sed 's|^\./||' | LC_ALL=C sort ) > "$out/files.txt"

/usr/bin/plutil -p "$app/Contents/Info.plist" > "$out/info.txt"
# JSON alongside it: the comparison is per key, which plutil -p text cannot express.
/usr/bin/plutil -convert json -r -o "$out/info.json" - < "$app/Contents/Info.plist"

executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")"
binary="$app/Contents/MacOS/$executable"
# Sorted: swiftc and ld64 emit the same set in a different order.
/usr/bin/otool -L "$binary" | tail -n +2 | sed 's/^[[:space:]]*//' | LC_ALL=C sort > "$out/libs.txt"
/usr/bin/stat -f%z "$binary" > "$out/size.txt"

# An unsigned bundle is a legitimate intermediate state, not a capture failure.
signature_dump=""
if ! signature_dump="$(/usr/bin/codesign -d --verbose=4 "$app" 2>&1)"; then
    echo "unsigned" > "$out/signature.txt"
    echo "unsigned" > "$out/requirement.txt"
    : > "$out/entitlements.txt"
else
    # Keep only the fields a rebuild must reproduce; sizes and hash counts move
    # with the binary and would mask the fields that matter.
    printf '%s\n' "$signature_dump" | sed -nE \
        -e 's/^(Identifier=.*)$/\1/p' \
        -e 's/^(Format=.*)$/\1/p' \
        -e 's/^(Hash type=[^ ]+).*$/\1/p' \
        -e 's/^CodeDirectory .*(flags=0x[0-9a-f]+\([^)]*\)).*$/CodeDirectory \1/p' \
        -e 's/^(Authority=.*)$/\1/p' \
        -e 's/^(TeamIdentifier=.*)$/\1/p' \
        -e 's/^Signature size=[0-9]+$/Signature=certificate/p' \
        -e 's/^(Signature=adhoc)$/\1/p' \
        -e 's/^Sealed Resources version=([0-9]+) rules=([0-9]+) files=([0-9]+)$/Sealed Resources version=\1 rules=\2 files=\3/p' \
        > "$out/signature.txt"
    # An ad-hoc designated requirement is derived from the cdhash and changes on
    # every build; pin its shape, not its value. A certificate-pinned one is stable.
    /usr/bin/codesign -d -r- "$app" 2>/dev/null | \
        sed -E 's/cdhash H"[0-9a-f]{40}"/cdhash H"<cdhash>"/' > "$out/requirement.txt"
    /usr/bin/codesign -d --entitlements - "$app" 2>/dev/null > "$out/entitlements.txt"
fi

prompt="$app/Contents/Resources/agent/conversation.md"
if [[ -f "$prompt" ]]; then
    /usr/bin/shasum -a 256 "$prompt" | awk '{print $1}' > "$out/prompt.txt"
else
    echo "absent" > "$out/prompt.txt"
fi
echo "Captured $app baseline in $out"
