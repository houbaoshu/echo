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
# Failures in this mode must never fall back to ad-hoc signing.
identity="${ECHO_SIGNING_IDENTITY:-}"
if [[ -z "$identity" ]]; then
    # A self-signed certificate stabilizes the designated requirement, but
    # securityd still identifies it by cdhash, which changes on rebuild.
    typeset -a apple_identities=()
    if ! available_identities="$(/usr/bin/security find-identity -v -p codesigning)"; then
        echo "Cannot query signing identities. Run development signing outside the sandbox with an accessible Keychain." >&2
        exit 1
    fi
    # Capture the pipeline status before reading; process substitution would
    # hide a producer failure from ERR_EXIT / PIPE_FAIL.
    apple_candidates="$(printf '%s\n' "$available_identities" | \
        sed -nE 's/^[[:space:]]*[0-9]+\) ([A-Fa-f0-9]{40}) "(Apple Development|Mac Developer|Developer ID Application|Apple Distribution|3rd Party Mac Developer Application):.*$/\1/p')"
    while IFS= read -r candidate; do
        if [[ -n "$candidate" ]]; then apple_identities+=("$candidate"); fi
    done <<< "$apple_candidates"
    if [[ ${#apple_identities[@]} -gt 1 ]]; then
        echo "Multiple Apple signing identities found. Set ECHO_SIGNING_IDENTITY to one certificate SHA-1 and reuse it for subsequent builds." >&2
        exit 1
    elif [[ ${#apple_identities[@]} -eq 1 ]]; then
        identity="${apple_identities[1]}"
    fi
fi

if [[ -n "$identity" ]]; then
    if [[ "$identity" == - ]]; then
        echo "Use a certificate-backed signing identity; ad-hoc signing resets Keychain authorization after rebuilds." >&2
        exit 1
    fi
    /usr/bin/codesign --force --sign "$identity" --timestamp=none "$app_dir"
else
    # This directory deliberately lives outside build/ and is never committed.
    # The dedicated keychain contains only the local development signing key.
    umask 077
    signing_dir="$project_dir/.local-signing"
    keychain="$signing_dir/echo.keychain-db"
    mkdir -p "$signing_dir"
    chmod 700 "$signing_dir"
    if [[ ! -f "$signing_dir/ready" ]]; then
        if [[ -e "$keychain" || -e "$signing_dir/password" ]]; then
            echo "Incomplete signing setup in $signing_dir; restore it or remove it before retrying (removal resets the signing identity)." >&2
            exit 1
        fi
        echo "Creating a persistent local development signing identity…"
        openssl rand -hex 32 > "$signing_dir/password"
        signing_password="$(cat "$signing_dir/password")"
        temp_dir="$(mktemp -d "$signing_dir/setup.XXXXXX")"
        trap 'rm -rf "$temp_dir"' EXIT
        openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
            -subj '/CN=Echo Local Development/' \
            -keyout "$temp_dir/key.pem" -out "$temp_dir/cert.pem" \
            -config /dev/stdin <<'CONFIG' >/dev/null 2>&1
[req]
distinguished_name = dn
x509_extensions = signing
[dn]
[signing]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONFIG
        # macOS Security supports the legacy PKCS#12 algorithms across SDKs.
        openssl pkcs12 -export -inkey "$temp_dir/key.pem" -in "$temp_dir/cert.pem" \
            -out "$temp_dir/identity.p12" -passout "file:$signing_dir/password" \
            -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
        /usr/bin/security create-keychain -p "$signing_password" "$keychain"
        /usr/bin/security unlock-keychain -p "$signing_password" "$keychain"
        /usr/bin/security import "$temp_dir/identity.p12" -k "$keychain" \
            -P "$signing_password" -T /usr/bin/codesign -x >/dev/null
        /usr/bin/security set-key-partition-list -S apple-tool:,apple: -s \
            -k "$signing_password" "$keychain" >/dev/null
        cp "$temp_dir/cert.pem" "$signing_dir/certificate.pem"
        # User-domain trust, restricted to code signing (never TLS or system trust).
        /usr/bin/security add-trusted-cert -r trustRoot -p codeSign \
            -k "$keychain" "$signing_dir/certificate.pem"
        openssl x509 -in "$temp_dir/cert.pem" -outform DER | /usr/bin/shasum -a 1 | \
            awk '{print toupper($1)}' > "$signing_dir/identity"
        touch "$signing_dir/ready"
    fi
    # codesign also needs the keychain in the user search list to find the key.
    typeset -a keychains=()
    found=false
    search_list="$(/usr/bin/security list-keychains -d user)"
    while IFS= read -r existing; do
        existing="$(printf '%s' "$existing" | sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//')"
        [[ -n "$existing" ]] || continue
        keychains+=("$existing")
        if [[ "$existing" == "$keychain" ]]; then found=true; fi
    done <<< "$search_list"
    if [[ "$found" == false ]]; then
        /usr/bin/security list-keychains -d user -s "${keychains[@]}" "$keychain"
    fi
    /usr/bin/security unlock-keychain -p "$(cat "$signing_dir/password")" "$keychain"
    identity="$(cat "$signing_dir/identity")"
    # Pin to our certificate, never merely to a bundle ID that others can copy.
    /usr/bin/codesign --force --sign "$identity" --keychain "$keychain" \
        --timestamp=none -r "=designated => identifier \"local.chiyan.desktop-pet\" and certificate leaf = H\"$identity\"" \
        "$app_dir"
fi
/usr/bin/codesign --verify --strict "$app_dir"
if ! /usr/bin/codesign --verify -R '=anchor apple generic' "$app_dir" >/dev/null 2>&1; then
    echo "WARNING: Local self-signed build: Always Allow persists for this code hash only. Code changes can prompt again, even with a stable designated requirement. Use an Apple Development / Developer ID identity via ECHO_SIGNING_IDENTITY for access across rebuilds." >&2
fi
