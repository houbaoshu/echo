#!/bin/zsh
# Installs an exported Core AI model directory as Echo's local chat model. The source is only
# read: --link places a symbolic link to it (development), otherwise it is copied.
emulate -R zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL
name="qwen3_0_6b_4bit_dynamic"
usage="Usage: $0 EXPORTED_MODEL_DIR [--link]"
source="" link=0
while (( $# )); do
    case "$1" in
        --link) link=1; shift ;;
        --help|-h) echo "$usage"; exit 0 ;;
        *) [[ -z "$source" ]] || { echo "$usage" >&2; exit 2 }; source="$1"; shift ;;
    esac
done
[[ -n "$source" && -d "$source" ]] || { echo "$usage" >&2; exit 2 }
source="${source:A}"

# The same checks the app makes before loading (LocalModelLocation.problem).
metadata="$source/metadata.json"
[[ -f "$metadata" ]] || { echo "Missing metadata.json in $source" >&2; exit 1 }
field() { plutil -extract "$1" raw -o - "$metadata" 2>/dev/null || true }
[[ "$(field kind)" == llm ]] || { echo "metadata.json does not describe a language model" >&2; exit 1 }
main="$(field assets.main)"
[[ -n "$main" && -e "$source/$main" ]] || { echo "Missing model asset '$main'" >&2; exit 1 }
[[ "$(field language.embedded_tokenizer)" == true && -f "$source/tokenizer/tokenizer.json" ]] \
    || { echo "Missing embedded tokenizer; Core AI would fetch one from the network" >&2; exit 1 }

models="$HOME/Library/Application Support/local.chiyan.desktop-pet/Models"
target="$models/$name"
mkdir -p "$models"
if [[ -L "$target" ]]; then
    # Only a link is replaced; an installed copy is left for the user to move.
    rm "$target"
elif [[ -e "$target" ]]; then
    echo "$target already exists; move it away first" >&2; exit 1
fi
if (( link )); then
    ln -s "$source" "$target"
    echo "Linked $target -> $source"
else
    partial="$models/.$name.partial-$$"
    ditto "$source" "$partial"
    mv "$partial" "$target"
    echo "Copied to $target"
fi
