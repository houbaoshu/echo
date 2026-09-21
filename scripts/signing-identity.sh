#!/bin/zsh
emulate -R zsh
# Resolve the development signing identity and publish it for both the shell
# signer and Xcode. This is the only code allowed to query signing identities,
# unlock a Keychain or create .local-signing/, so ad-hoc signing must never
# reach it.
#
# Two outcomes, which sign differently and must stay distinguishable:
#   pinned = NO   an identity given through ECHO_SIGNING_IDENTITY, or the single
#                 Apple certificate found on this machine. Signed with codesign's
#                 default designated requirement and the default Keychain.
#   pinned = YES  a certificate this script generated. Signed through the
#                 dedicated Keychain with the requirement pinned to the
#                 certificate, because a bundle identifier alone is copyable.
setopt ERR_EXIT NO_UNSET PIPE_FAIL
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
script_name="$0"
usage() {
    echo "Usage: $script_name [--config-path]"
    echo "Writes build/signing/Signing.xcconfig, and a compiled requirement"
    echo "beside it when the identity is a locally bootstrapped certificate."
    echo "--config-path: print the config path without resolving an identity."
}
output_dir="$project_dir/build/signing"
config="$output_dir/Signing.xcconfig"
requirement_source="$output_dir/requirement.req"
# Compiled, because codesign only accepts a requirement as inline source text or
# as a compiled blob, and inline text cannot survive an xcconfig's word splitting.
requirement="$output_dir/requirement.bin"
case "${1:-}" in
    --help|-h) usage; exit 0 ;;
    --config-path) echo "$config"; exit 0 ;;
    "") ;;
    *) usage >&2; exit 1 ;;
esac

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

pinned=NO
keychain=""
if [[ -n "$identity" ]]; then
    if [[ "$identity" == - ]]; then
        echo "Use a certificate-backed signing identity; ad-hoc signing resets Keychain authorization after rebuilds." >&2
        exit 1
    fi
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
        # Signing and strict verification work without trusting this certificate.
        # The designated requirement below pins its fingerprint; do not write
        # user/admin trust settings (which are not scoped to this keychain).
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
    pinned=YES
fi

mkdir -p "$output_dir"
rm -f "$requirement_source" "$requirement"
if [[ "$pinned" == YES ]]; then
    # Pin to our certificate, never merely to a bundle ID that others can copy.
    printf 'designated => identifier "local.chiyan.desktop-pet" and certificate leaf = H"%s"\n' \
        "$identity" > "$requirement_source"
    /usr/bin/csreq -r"=$(cat "$requirement_source")" -b "$requirement"
fi
cat > "$config" <<CONFIG
// Generated by scripts/signing-identity.sh; per machine, never committed.
ECHO_SIGNING_IDENTITY = $identity
ECHO_SIGNING_PINNED = $pinned
ECHO_SIGNING_KEYCHAIN = $keychain
ECHO_SIGNING_REQUIREMENT = $([[ "$pinned" == YES ]] && echo "$requirement")
CONFIG
