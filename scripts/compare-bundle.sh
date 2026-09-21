#!/bin/zsh
emulate -R zsh
# Diff a bundle against a captured baseline. The only differences the Xcode build
# chain is allowed to introduce are the ones --allow-xcode-extras names explicitly.
setopt ERR_EXIT NO_UNSET PIPE_FAIL
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
script_name="$0"
usage() {
    echo "Usage: $script_name [--allow-xcode-extras] /path/to/baseline-dir /path/to/Echo.app"
    echo "Compares payload, Info.plist keys, linked libraries, entitlements, designated"
    echo "requirement, signature metadata and the bundled prompt. Binary size is reported"
    echo "but never fails."
    echo "--allow-xcode-extras: tolerate Contents/PkgInfo, Xcode's DT*/platform Info.plist"
    echo "keys, and the sealed-file count those imply. Nothing else."
}
allow_extras=false
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then usage; exit 0; fi
if [[ "${1:-}" == --allow-xcode-extras ]]; then allow_extras=true; shift; fi
if [[ $# -ne 2 || "$1" == -* ]]; then usage >&2; exit 1; fi
baseline="$1"
app="$2"
if [[ ! -f "$baseline/files.txt" ]]; then echo "Not a baseline directory: $baseline" >&2; exit 1; fi

candidate="$(mktemp -d "${TMPDIR:-/tmp}/echo-compare.XXXXXX")"
trap 'rm -rf "$candidate"' EXIT
/bin/zsh "$project_dir/scripts/capture-baseline.sh" "$app" "$candidate" >/dev/null

failures=0
report() {
    # $1 = item, $2 = verdict, $3... = detail lines
    local item="$1" verdict="$2"
    shift 2
    printf '%-14s %s\n' "$item" "$verdict"
    if [[ $# -gt 0 ]]; then printf '                 %s\n' "$@"; fi
    if [[ "$verdict" == FAIL ]]; then failures=$((failures + 1)); fi
}

compare_lines() {
    # $1 = item, $2 = filename, $3 = newline-separated tolerated additions
    local item="$1" name="$2" tolerated="${3:-}"
    local -a missing=() added=() unexpected=()
    while IFS= read -r line; do [[ -n "$line" ]] && missing+=("$line"); done \
        < <(LC_ALL=C comm -23 "$baseline/$name" "$candidate/$name")
    while IFS= read -r line; do [[ -n "$line" ]] && added+=("$line"); done \
        < <(LC_ALL=C comm -13 "$baseline/$name" "$candidate/$name")
    for line in "${added[@]}"; do
        if [[ "$allow_extras" == true && -n "$tolerated" && $'\n'"$tolerated"$'\n' == *$'\n'"$line"$'\n'* ]]; then
            continue
        fi
        unexpected+=("$line")
    done
    if [[ ${#missing[@]} -eq 0 && ${#unexpected[@]} -eq 0 ]]; then
        if [[ ${#added[@]} -eq 0 ]]; then
            report "$item" PASS
        else
            report "$item" "PASS (expected additions)" "${added[@]/#/+ }"
        fi
    else
        report "$item" FAIL "${missing[@]/#/- }" "${unexpected[@]/#/+ }"
    fi
}

compare_exact() {
    # $1 = item, $2 = filename
    local item="$1" name="$2"
    if cmp -s "$baseline/$name" "$candidate/$name"; then
        report "$item" PASS
    else
        local -a detail=()
        while IFS= read -r line; do detail+=("$line"); done < <(diff "$baseline/$name" "$candidate/$name" || true)
        report "$item" FAIL "${detail[@]}"
    fi
}

compare_lines payload files.txt "Contents/PkgInfo"
compare_lines libraries libs.txt ""

# Per key: every baseline key must survive with the same value. Additions are the
# build system's own metadata and are listed either way.
info_result="$(ECHO_ALLOW_EXTRAS="$allow_extras" python3 - "$baseline/info.json" "$candidate/info.json" <<'PY'
import json, os, sys
tolerated = {"BuildMachineOSBuild", "CFBundleSupportedPlatforms", "DTCompiler", "DTPlatformBuild",
             "DTPlatformName", "DTPlatformVersion", "DTSDKBuild", "DTSDKName", "DTXcode", "DTXcodeBuild"}
allow = os.environ["ECHO_ALLOW_EXTRAS"] == "true"
base = json.load(open(sys.argv[1]))
new = json.load(open(sys.argv[2]))
problems, notes = [], []
for key, value in base.items():
    if key not in new:
        problems.append(f"- {key} (dropped)")
    elif new[key] != value:
        problems.append(f"~ {key}: {value!r} -> {new[key]!r}")
for key in new.keys() - base.keys():
    (notes if allow and key in tolerated else problems).append(f"+ {key}")
print("FAIL" if problems else "PASS")
print("\n".join(problems + notes))
PY
)"
info_verdict="${info_result%%$'\n'*}"
info_detail=""
if [[ "$info_result" == *$'\n'* ]]; then info_detail="${info_result#*$'\n'}"; fi
if [[ -n "$info_detail" ]]; then
    report "Info.plist" "$info_verdict" "${(f)info_detail}"
else
    report "Info.plist" "$info_verdict"
fi

compare_exact entitlements entitlements.txt
compare_exact requirement requirement.txt

# The sealed-file count follows the payload; compare it only when the payload did.
if [[ "$allow_extras" == true ]]; then
    for side in "$baseline" "$candidate"; do
        sed -E 's/^(Sealed Resources version=[0-9]+ rules=[0-9]+) files=[0-9]+$/\1 files=<n>/' \
            "$side/signature.txt" > "$side/signature.normalized"
    done
    if cmp -s "$baseline/signature.normalized" "$candidate/signature.normalized"; then
        report signature "PASS (payload owns the sealed-file count)" "sealed files: $(sed -nE 's/.*files=([0-9]+)$/\1/p' "$baseline/signature.txt") -> $(sed -nE 's/.*files=([0-9]+)$/\1/p' "$candidate/signature.txt")"
    else
        local_detail=()
        while IFS= read -r line; do local_detail+=("$line"); done \
            < <(diff "$baseline/signature.normalized" "$candidate/signature.normalized" || true)
        report signature FAIL "${local_detail[@]}"
    fi
    rm -f "$baseline/signature.normalized"
else
    compare_exact signature signature.txt
fi

compare_exact prompt prompt.txt
report size INFO "$(cat "$baseline/size.txt") -> $(cat "$candidate/size.txt") bytes"

if [[ $failures -gt 0 ]]; then
    echo "FAIL: $failures item(s) differ from $baseline" >&2
    exit 1
fi
echo "PASS: $app matches $baseline"
