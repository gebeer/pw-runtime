#!/usr/bin/env bash
# Safety failures against a fake ddev: these tests cannot touch a real database or container.
set -euo pipefail
trap 'echo "FAIL: assertion at line $LINENO" >&2' ERR
CLI="$(realpath "$(dirname "$0")/../pw-runtime")"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export XDG_CACHE_HOME="$TMP/cache" # never the real seed cache
git() { command git -c user.name=test -c user.email=test@example.invalid "$@"; }

# The main checkout is the source; fixtures are tracked like in a real project.
SRC="$TMP/main"
mkdir -p "$TMP/fake" "$SRC/.ddev" "$SRC/site/assets/files" "$SRC/.pw-runtime"
git init -q -b main "$SRC"
printf 'name: source\n' > "$SRC/.ddev/config.yaml"
printf '<?php // tracked\n' > "$SRC/site/config.php"
printf 'SELECT 1;\n' > "$SRC/.pw-runtime/sanitize.sql"
printf 'site/assets/\n' > "$SRC/.gitignore"
mkdir "$SRC/.agents"
printf 'tracked\n' > "$SRC/.agents/tracked.md"
git -C "$SRC" add .
git -C "$SRC" commit -qm initial
# Untracked agent config in the main checkout: files, an absolute symlink and an empty folder.
mkdir -p "$SRC/.claude/skills" "$SRC/.pi" "$TMP/skill-target"
printf '{}\n' > "$SRC/.claude/settings.local.json"
ln -s "$TMP/skill-target" "$SRC/.claude/skills/shared"
printf 'untracked\n' > "$SRC/.agents/local.md"
printf '<?php // fixture\n' > "$SRC/site/config-dev.php"
git -C "$SRC" worktree add --detach -q "$TMP/123" HEAD

cat > "$TMP/fake/ddev" <<'SH'
#!/usr/bin/env bash
set -eu
case "$1" in
    list) jq -n --arg root "${REGISTERED_ROOT:-}" --arg name "$EXPECTED_SLUG" '{raw: (if $root == "" then [] else [{name:$name,approot:$root}] end)}' ;;
    describe) jq -n --arg root "$FAKE_SRC" --arg status "${SOURCE_STATUS:-running}" '{raw:{name:"source",approot:$root,status:$status,hostnames:["source.ddev.site","www.source.ddev.site"]}}' ;;
    utility)
        if [[ "${CONFIG_MATCH:-}" == yes ]]; then
            printf 'name: %s\n' "$EXPECTED_SLUG"
            # Keep writing after the match: an early grep -q exit must not kill DDEV.
            for ((i=0; i<4000; i++)); do printf 'extra-config: %0100d\n' "$i"; done
        else
            printf 'name: wrong-project\n'
        fi ;;
    *) echo "UNEXPECTED DDEV MUTATION: $*" >&2; exit 99 ;;
esac
SH
chmod +x "$TMP/fake/ddev"
export PATH="$TMP/fake:$PATH" FAKE_SRC="$SRC"
reject() {
    local expected="$1"
    shift
    if "$@" > "$TMP/rejected.log" 2>&1; then echo 'FAIL: unsafe command succeeded' >&2; exit 1; fi
    grep -F -- "$expected" "$TMP/rejected.log" || { echo "FAIL: expected rejection: $expected" >&2; cat "$TMP/rejected.log" >&2; exit 1; }
}

# The main checkout is never a runtime; hook commands are no-ops there and in non-opted-in repos.
cd "$SRC"
reject 'never the main checkout' bash "$CLI" up
bash "$CLI" guard 2>&1 | grep -q 'nothing to do'
bash "$CLI" down 2>&1 | grep -q 'nothing to tear down'
[[ "$(<site/config-dev.php)" == '<?php // fixture' ]]
git init -q "$TMP/plain"
(cd "$TMP/plain" && bash "$CLI" guard 2>&1 | grep -q 'nothing to do' && bash "$CLI" down 2>&1 | grep -q 'nothing to tear down')
reject 'usage: pw-runtime' bash "$CLI" bogus

cd "$TMP/123"
# shellcheck source=/dev/null
source "$CLI"
export EXPECTED_SLUG="source-123-$(path_hash "$PWD")"
bash "$CLI" down 2>&1 | grep -q 'nothing to tear down'
reject 'unknown: --unknown' bash "$CLI" up --unknown
mv .pw-runtime/sanitize.sql "$TMP/sanitize.sql"
reject 'has not opted in' bash "$CLI" up
mv "$TMP/sanitize.sql" .pw-runtime/sanitize.sql

export REGISTERED_ROOT="$SRC"
reject 'belongs to a different checkout' bash "$CLI" up
mkdir .pw-runtime/state # down is only strict once metadata exists
reject 'belongs to a different checkout' bash "$CLI" down
rmdir .pw-runtime/state
unset REGISTERED_ROOT
export SOURCE_STATUS=stopped
reject 'source must already be running' bash "$CLI" up
[[ ! -e .pw-runtime/state && ! -e site/config-dev.php ]]
unset SOURCE_STATUS
printf '<?php // custom local config\n' > site/config-dev.php
reject 'refusing to overwrite custom' bash "$CLI" up
rm site/config-dev.php
bash "$CLI" guard
# Untracked agent config comes along from the main checkout: symlinks as they are, existing copies kept,
# a folder the repository tracks left alone, nothing visible to git.
[[ "$(readlink .claude/skills/shared)" == "$TMP/skill-target" && -f .claude/settings.local.json && -d .pi ]]
[[ ! -e .agents/local.md ]]
printf 'mine\n' > .claude/settings.local.json
rm -rf .agents .pi
bash "$CLI" guard # safe to replay
[[ "$(<.claude/settings.local.json)" == mine && -d .pi && ! -e .agents ]]
git checkout -q .agents
grep -qxF '// pw-runtime: generated code-only guard' site/config-dev.php
# The guard blocks an accidental ProcessWire boot instead of falling back to the tracked config.
if php -n -r 'require "site/config-dev.php";' >/dev/null 2>&1; then echo 'FAIL: code-only boot was not blocked' >&2; exit 1; fi
[[ -z "$(git status --porcelain)" ]] # generated files are ignored through info/exclude
reject 'effective DDEV project name differs' bash "$CLI" up # Never start.
[[ -f .pw-runtime/state/root && ! -e .pw-runtime/state/ready ]]
CONFIG_MATCH=yes reject 'UNEXPECTED DDEV MUTATION: start' bash "$CLI" up
# Evaluate the generated config only, with a synthetic config object; never bootstrap ProcessWire.
# shellcheck disable=SC2016
php -n -r '$config = new stdClass(); require "site/config-dev.php"; if($config->dbHost !== "db" || $config->dbSocket !== "" || $config->dbReader !== [] || $config->wireMail["module"] !== "WireMail" || $config->httpHosts !== [getenv("EXPECTED_SLUG") . ".ddev.site", "www." . getenv("EXPECTED_SLUG") . ".ddev.site"]) exit(1);'
[[ "$(stat -c %a site/config-pw-runtime.php)" == 600 ]]
cmp -s "$SRC/site/config-dev.php" site/config-pw-runtime.php
printf '%s\n' "$TMP/other-source" > .pw-runtime/state/source
reject 'runtime identity changed' bash "$CLI" up
# Teardown is guarded for partial provisioning with no registered project.
printf '%s\n' "$TMP/elsewhere" > .pw-runtime/state/root
reject 'no owned runtime metadata' bash "$CLI" down
printf '%s\n' "$PWD" > .pw-runtime/state/root
printf '# someone else wrote this\n' > .ddev/config.local.yaml
reject 'refusing to remove unrecognized .ddev/config.local.yaml' bash "$CLI" down
rm .ddev/config.local.yaml
bash "$CLI" down
[[ ! -e .pw-runtime/state && ! -e .ddev/config.local.yaml && ! -e site/config-pw-runtime.php ]]
grep -qxF '// pw-runtime: generated code-only guard' site/config-dev.php
bash "$CLI" down 2>&1 | grep -q 'nothing to tear down'
[[ "$(<"$SRC/site/config-dev.php")" == '<?php // fixture' && -z "$(git status --porcelain)" ]]
# Nothing the tool generated or copied blocks a plain worktree removal.
cd "$SRC"
git worktree remove "$TMP/123"
[[ ! -e "$TMP/123" && -f .claude/settings.local.json && -L .claude/skills/shared ]] # the main checkout keeps its own
echo 'PASS: agent config copy, main checkout, opt-in, wrong registration, stopped source, custom config, identity change, config collision and teardown guards'
