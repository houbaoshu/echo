#!/bin/zsh
emulate -R zsh
# Guard the signing mode before anything is built.
#
# Xcode treats an empty CODE_SIGN_IDENTITY as "do not sign" and still reports
# success, which is exactly the silent fall back that development signing must
# never do. It also cannot express "the dedicated Keychain must be unlocked".
# Both belong here, where a failure stops the build.
setopt ERR_EXIT NO_UNSET PIPE_FAIL
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
flags="${OTHER_CODE_SIGN_FLAGS:-}"
case "${ECHO_SIGNING:-}" in
    adhoc)
        if [[ "${CODE_SIGN_IDENTITY:-}" != - ]]; then
            echo "error: ad-hoc signing expects CODE_SIGN_IDENTITY '-', got '${CODE_SIGN_IDENTITY:-}'." >&2
            exit 1
        fi
        # Keychain-free by construction. A generated config left by an earlier
        # development build must not leak into this mode.
        if [[ "$flags" == *--keychain* || "$flags" == *" -r "* ]]; then
            echo "error: ad-hoc signing must not reach a Keychain or a pinned requirement: $flags" >&2
            exit 1
        fi
        ;;
    development)
        if [[ -z "${CODE_SIGN_IDENTITY:-}" ]]; then
            echo "error: no development signing identity is available." >&2
            echo "note: run scripts/signing-identity.sh, then build again." >&2
            exit 1
        fi
        if [[ "${CODE_SIGN_IDENTITY}" == - ]]; then
            echo "error: development signing requires a certificate; ad-hoc signing resets Keychain authorization after rebuilds." >&2
            exit 1
        fi
        if [[ "${ECHO_RESOLVED_PINNED:-}" == YES ]]; then
            # A locally bootstrapped certificate is only as good as its pinned
            # requirement; losing the flag would quietly widen who can claim
            # this bundle identifier.
            if [[ "$flags" != *" -r "* ]]; then
                echo "error: a bootstrapped certificate must sign with its pinned designated requirement, but none was passed: $flags" >&2
                exit 1
            fi
            if [[ ! -f "${ECHO_RESOLVED_REQUIREMENT:-}" ]]; then
                echo "error: the pinned requirement '${ECHO_RESOLVED_REQUIREMENT:-}' does not exist." >&2
                exit 1
            fi
            /bin/zsh "$project_dir/scripts/signing-identity.sh" --unlock
        fi
        ;;
    "")
        echo "error: ECHO_SIGNING must be set to adhoc or development." >&2
        exit 1
        ;;
    *)
        echo "error: unknown ECHO_SIGNING '${ECHO_SIGNING}'; expected adhoc or development." >&2
        exit 1
        ;;
esac
