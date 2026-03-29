#!/bin/bash
set -euo pipefail

TARGETS=("$HOME/.zshrc" "$HOME/.bashrc")
ALIAS_START="# --- FocusShield Aliases START ---"
ALIAS_END="# --- FocusShield Aliases END ---"
WRAPPER_DIR="/usr/local/lib/focusshield/wrappers"

remove_block() {
    local target="$1"
    [ -f "$target" ] || return 0
    sed -i.bak '/# --- FocusShield Aliases START ---/,/# --- FocusShield Aliases END ---/d' "$target"
    rm -f "${target}.bak"
}

if [ "${1:-}" = "--remove" ]; then
    for target in "${TARGETS[@]}"; do
        remove_block "$target"
    done
    exit 0
fi

ALIAS_BLOCK="$ALIAS_START\n"
if [ -d "$WRAPPER_DIR" ]; then
    for wrapper in "$WRAPPER_DIR"/*; do
        [ -f "$wrapper" ] || continue
        [ -x "$wrapper" ] || continue
        tool=$(basename "$wrapper")
        ALIAS_BLOCK+="alias $tool=\"$wrapper\"\n"
    done
fi
ALIAS_BLOCK+="$ALIAS_END\n"

for target in "${TARGETS[@]}"; do
    [ -f "$target" ] || continue
    remove_block "$target"
    if [ -d "$WRAPPER_DIR" ] && [ "$(ls -A "$WRAPPER_DIR" 2>/dev/null)" ]; then
        printf "%b" "$ALIAS_BLOCK" >> "$target"
    fi
done
