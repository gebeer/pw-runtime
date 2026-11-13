#!/usr/bin/env bash
# install.sh against a throwaway HOME: links, repeat, and refusal to replace foreign entries.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME"

bash "$REPO/install.sh" > /dev/null
[[ "$(readlink "$HOME/.local/bin/pw-runtime")" == "$REPO/pw-runtime" ]]
[[ "$(readlink "$HOME/.agents/skills/pw-runtime")" == "$REPO/.agents/skills/pw-runtime" ]]
[[ "$(readlink "$HOME/.claude/skills/pw-runtime")" == "$HOME/.agents/skills/pw-runtime" ]]
[[ -f "$HOME/.claude/skills/pw-runtime/SKILL.md" ]] # the chain resolves to the skill

[[ "$(bash "$REPO/install.sh" | grep -c '^ok: ')" == 3 ]] # a repeat changes nothing
[[ ! -e "$HOME/.config" ]] # no Herdr here: no mod link, no folder made for it

mkdir -p "$HOME/.config/herdr-app/mods"
bash "$REPO/install.sh" > /dev/null
[[ "$(readlink "$HOME/.config/herdr-app/mods/pw-worktree")" == "$REPO/herdr/pw-worktree" ]]

# A foreign link and a real folder are both refused and left alone.
rm "$HOME/.claude/skills/pw-runtime"
ln -s /nonexistent "$HOME/.claude/skills/pw-runtime"
! bash "$REPO/install.sh" > /dev/null 2>&1
[[ "$(readlink "$HOME/.claude/skills/pw-runtime")" == /nonexistent ]]
rm "$HOME/.agents/skills/pw-runtime" "$HOME/.claude/skills/pw-runtime"
mkdir "$HOME/.agents/skills/pw-runtime"
! bash "$REPO/install.sh" > /dev/null 2>&1
[[ -d "$HOME/.agents/skills/pw-runtime" && ! -L "$HOME/.agents/skills/pw-runtime" && ! -e "$HOME/.claude/skills/pw-runtime" ]]

echo 'PASS: install links, repeat and refusals'
