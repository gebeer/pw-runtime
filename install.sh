#!/usr/bin/env bash
# Links the CLI and the agent skill into the user's home. Safe to repeat; never replaces anything.
set -euo pipefail

REPO="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

link() { # link TARGET PATH
    local target="$1" path="$2"
    if [[ -L "$path" && "$(readlink "$path")" == "$target" ]]; then
        echo "ok: $path"
        return
    fi
    if [[ -e "$path" || -L "$path" ]]; then
        echo "install: $path exists and is not this link; remove it yourself, then run again" >&2
        exit 1
    fi
    mkdir -p "$(dirname "$path")"
    ln -s "$target" "$path"
    echo "linked: $path -> $target"
}

link "$REPO/pw-runtime" "$HOME/.local/bin/pw-runtime"
# pi reads ~/.agents/skills; Claude Code reads ~/.claude/skills and gets a link to the same entry.
link "$REPO/.agents/skills/pw-runtime" "$HOME/.agents/skills/pw-runtime"
link "$HOME/.agents/skills/pw-runtime" "$HOME/.claude/skills/pw-runtime"
