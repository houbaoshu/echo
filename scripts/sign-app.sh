#!/bin/zsh
emulate -R zsh
# Validation is Keychain-free; certificate-backed signing is explicit.
setopt ERR_EXIT NO_UNSET PIPE_FAIL
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
script_name="$0"
usage() {
    echo "Usage: $script_name [--signing ad-hoc|development] /path/to/Echo.app"
    echo "Default: ad-hoc (no signing Keychain). Development uses ECHO_SIGNING_IDENTITY or certificate discovery."
}
signing_mode=ad-hoc
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then usage; exit 0; fi
if [[ "${1:-}" == --signing ]]; then
    if [[ $# -lt 3 ]]; then usage >&2; exit 1; fi
    signing_mode="$2"
    shift 2
fi
if [[ $# -ne 1 || "$1" == -* ]]; then usage >&2; exit 1; fi
app_dir="$1"
case "$signing_mode" in
    ad-hoc)
        # Do not discover identities, unlock keychains, or create .local-signing.
        # Ignore inherited ECHO_SIGNING_IDENTITY in this mode.
        /usr/bin/codesign --force --sign - --timestamp=none "$app_dir"
        /usr/bin/codesign --verify --strict "$app_dir"
        exit 0
        ;;
    development) ;;
    *) usage >&2; exit 1 ;;
esac

# Apple-issued signing preserves Keychain partitions across code changes.
# Identity resolution, including bootstrapping a local certificate, lives in
# signing-identity.sh, so this script and Xcode sign with the same identity and
# the same designated requirement.
# Failures in this mode must never fall back to ad-hoc signing.
/bin/zsh "$project_dir/scripts/signing-identity.sh"
config="$(/bin/zsh "$project_dir/scripts/signing-identity.sh" --config-path)"
read_setting() { sed -nE "s/^$1 = (.*)\$/\\1/p" "$config"; }
identity="$(read_setting ECHO_SIGNING_IDENTITY)"
pinned="$(read_setting ECHO_SIGNING_PINNED)"
keychain="$(read_setting ECHO_SIGNING_KEYCHAIN)"
compiled_requirement="$(read_setting ECHO_SIGNING_REQUIREMENT)"
if [[ -z "$identity" ]]; then
    echo "No development signing identity was resolved; refusing to leave $app_dir unsigned." >&2
    exit 1
fi
typeset -a signing_flags=(--force --sign "$identity" --timestamp=none)
if [[ "$pinned" == YES ]]; then
    signing_flags+=(--keychain "$keychain" -r "$compiled_requirement")
fi
/usr/bin/codesign "${signing_flags[@]}" "$app_dir"
/usr/bin/codesign --verify --strict "$app_dir"
if ! /usr/bin/codesign --verify -R '=anchor apple generic' "$app_dir" >/dev/null 2>&1; then
    echo "WARNING: Local self-signed build: Always Allow persists for this code hash only. Code changes can prompt again, even with a stable designated requirement. Use an Apple Development / Developer ID identity via ECHO_SIGNING_IDENTITY for access across rebuilds." >&2
fi
