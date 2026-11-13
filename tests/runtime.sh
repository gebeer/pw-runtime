#!/usr/bin/env bash
# Orchestration regression coverage; the fake ddev never contacts a database or site.
set -euo pipefail
trap 'echo "FAIL: assertion at line $LINENO" >&2' ERR
CLI="$(realpath "$(dirname "$0")/../pw-runtime")"
TMP="$(mktemp -d)"
# Tiny upload fixtures beside a private cache on the reflink filesystem of ~/.cache.
BULK="$(mktemp -d "$HOME/.cache/pw-runtime-test.XXXXXX")"
trap 'rm -rf "$TMP" "$BULK"' EXIT
export XDG_CACHE_HOME="$TMP/cache" # never the real seed cache
git() { command git -c user.name=test -c user.email=test@example.invalid "$@"; }
# shellcheck source=/dev/null
source "$CLI"

# The main checkout is the source; opt-in files are tracked, local files are not.
SRC="$TMP/main"
mkdir -p "$TMP/fake" "$SRC/.ddev/traefik/config" "$SRC/site/assets/files" "$SRC/.pw-runtime" "$SRC/build/dist"
git init -q -b main "$SRC"
printf 'name: source\n' > "$SRC/.ddev/config.yaml"
printf '# customized\nrule: HostRegexp(`^www\\.source\\.ddev\\.site$`)\nurl: https://ddev-source-web:443\n' > "$SRC/.ddev/traefik/config/source.yaml"
printf '<?php // tracked\n' > "$SRC/site/config.php"
printf 'UPDATE modules SET data = "" WHERE class = "Mailer";\n' > "$SRC/.pw-runtime/sanitize.sql"
printf 'SELECT COUNT(*) FROM modules WHERE data != "";\n' > "$SRC/.pw-runtime/verify.sql"
# shellcheck disable=SC2016
printf '[[ "${AFTER_UP_FAIL:-}" != yes ]]\nprintf "%%s %%s\\n" "$PW_RUNTIME_SLUG" "$PW_RUNTIME_URL" > "$PW_RUNTIME_SOURCE/../after-up.log"\n' > "$SRC/.pw-runtime/after-up.sh"
printf '# local files\n.htaccess\nbuild/dist/\n' > "$SRC/.pw-runtime/copy-from-main"
printf 'site/assets/\n' > "$SRC/.gitignore"
git -C "$SRC" add .
git -C "$SRC" commit -qm initial
printf '<?php // fake source\n' > "$SRC/site/config-dev.php"
printf 'RewriteEngine On\n' > "$SRC/.htaccess"
printf 'body{}\n' > "$SRC/build/dist/app.css"
printf 'upload\n' > "$SRC/site/assets/files/upload"
git -C "$SRC" worktree add --detach -q "$TMP/123" HEAD

cat > "$TMP/fake/ddev" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FAKE_LOG"
case "$1" in
    list) jq -n --arg root "$FAKE_ROOT" --arg name "$EXPECTED_SLUG" --arg active "$(test -e "$FAKE_ACTIVE" && echo yes || true)" --argjson extra "${FAKE_EXTRA:-[]}" \
        '{raw: ((if $active == "yes" then [{name:$name,approot:$root,status:"running"}] else [] end) + $extra)}' ;;
    describe) jq -n --arg src "$FAKE_SRC" --arg status "${SOURCE_STATUS:-running}" \
        '{raw:{name:"source",approot:$src,status:$status,hostnames:["source.ddev.site","www.source.ddev.site","intranet.ddev.site"]}}' ;;
    utility) printf 'name: %s\n' "$EXPECTED_SLUG" ;;
    start) touch "$FAKE_ACTIVE" ;;
    delete)
        [[ "${DELETE_FAIL:-}" != yes ]] || exit 1
        [[ "$3" != "$EXPECTED_SLUG" ]] || rm -f "$FAKE_ACTIVE" ;;
    export-db | import-db) : ;;
    mysql) if [[ " $* " == *' -N '* ]]; then cat > /dev/null; echo "${VERIFY_RESULT:-0}"; else cat >> "$FAKE_SQL"; fi ;;
    *) echo "Unexpected ddev call: $*" >&2; exit 99 ;;
esac
SH
printf '#!/usr/bin/env bash\nprintf 200\n' > "$TMP/fake/curl" # the readiness poll must not reach the network
chmod +x "$TMP/fake/ddev" "$TMP/fake/curl"
export PATH="$TMP/fake:$PATH" FAKE_SRC="$SRC" FAKE_LOG="$TMP/ddev.log" FAKE_ACTIVE="$TMP/active" FAKE_SQL="$TMP/sql.log"
reject() {
    if "$@" > "$TMP/rejected.log" 2>&1; then echo "FAIL: expected failure (line ${BASH_LINENO[0]})" >&2; exit 1; fi
}
enter() { # run the following commands as the worktree $1
    cd "$1"
    FAKE_ROOT="$PWD" EXPECTED_SLUG="source-$(basename "$PWD")-$(path_hash "$PWD")"
    export FAKE_ROOT EXPECTED_SLUG
}
exports() { grep -c '^export-db ' "$FAKE_LOG" || true; }
can_reflink() { # between the directories $1 and $2
    printf probe > "$1/.probe"
    cp --reflink=always "$1/.probe" "$2/.probe-clone" 2>/dev/null && rm -f "$1/.probe" "$2/.probe-clone"
}

enter "$TMP/123"
export SOURCE_STATUS=stopped
reject bash "$CLI" up
grep -q 'start DDEV there, then retry' "$TMP/rejected.log"
[[ ! -e .pw-runtime/state ]]
! grep -q '^start' "$FAKE_LOG"
unset SOURCE_STATUS

bash "$CLI" up > "$TMP/ready.json" 2> "$TMP/up.log"
jq -e --arg slug "$EXPECTED_SLUG" '.slug == $slug and .ready == true and .url == "https://www." + $slug + ".ddev.site"' "$TMP/ready.json" > /dev/null
[[ "$(wc -l < "$TMP/ready.json")" == 1 ]] # stdout is the JSON line only
[[ -f .pw-runtime/state/seeded && -f .pw-runtime/state/ready ]]
# Hostnames follow the source with the project name replaced; a hostname without it is dropped.
grep -qxF "additional_hostnames: [\"www.$EXPECTED_SLUG\"]" .ddev/config.local.yaml
grep -q 'intranet.ddev.site does not contain the project name' "$TMP/up.log"
# The customized router file is regenerated for the runtime; the tracked one is untouched.
grep -qF "url: https://ddev-$EXPECTED_SLUG-web:443" ".ddev/traefik/config/$EXPECTED_SLUG.yaml"
grep -qF "^www\\.$EXPECTED_SLUG\\.ddev\\.site\$" ".ddev/traefik/config/$EXPECTED_SLUG.yaml"
git diff --quiet
# Local files listed by the project are copied; sanitizing SQL and the hook ran.
cmp "$SRC/.htaccess" .htaccess
cmp "$SRC/build/dist/app.css" build/dist/app.css
grep -q 'UPDATE modules' "$FAKE_SQL"
[[ "$(< "$TMP/after-up.log")" == "$EXPECTED_SLUG https://www.$EXPECTED_SLUG.ddev.site" ]]
[[ -z "$(git status --porcelain)" ]]
# Where a reflink is impossible the source files are mounted read-only, with a notice.
if can_reflink "$TMP" "$TMP"; then
    echo 'SKIP: read-only fallback assertions (temp filesystem supports reflinks)'
else
    jq -e '.fileMode == "readonly"' "$TMP/ready.json" > /dev/null
    grep -qF "$SRC/site/assets/files:/var/www/html/site/assets/files:ro" .ddev/docker-compose.pw-runtime.yaml
    grep -q 'NOTICE: cannot reflink' "$TMP/up.log"
    [[ ! -e "$XDG_CACHE_HOME/pw-runtime/$(printf '%s' "$SRC" | sha1sum | cut -c1-12)/files-seed" && ! -e site/assets/files/upload ]]
fi

# A failed hook or verification must not expose HTTP as ready; a reused runtime keeps its database.
export AFTER_UP_FAIL=yes
reject bash "$CLI" up
[[ ! -e .pw-runtime/state/ready && -f .pw-runtime/state/seeded ]]
unset AFTER_UP_FAIL
export VERIFY_RESULT=1
reject bash "$CLI" up
grep -q 'verification failed' "$TMP/rejected.log"
[[ ! -e .pw-runtime/state/ready ]]
unset VERIFY_RESULT
bash "$CLI" up > /dev/null 2>&1
[[ "$(exports)" == 1 && -f .pw-runtime/state/ready ]]
printf 'edited\n' > .htaccess
bash "$CLI" up > /dev/null 2>&1
[[ "$(< .htaccess)" == edited ]] # existing local copies are kept

# Teardown deletes only this runtime; a failed delete keeps the metadata for a retry.
export DELETE_FAIL=yes
reject bash "$CLI" down
[[ -f .pw-runtime/state/root && -e "$FAKE_ACTIVE" ]]
unset DELETE_FAIL
bash "$CLI" down 2> /dev/null
grep -qxF "delete -Oy $EXPECTED_SLUG" "$FAKE_LOG"
[[ ! -e .pw-runtime/state && ! -e "$FAKE_ACTIVE" && ! -e .ddev/config.local.yaml && ! -e .ddev/docker-compose.pw-runtime.yaml && ! -e ".ddev/traefik/config/$EXPECTED_SLUG.yaml" ]]
grep -qxF '// pw-runtime: generated code-only guard' site/config-dev.php
[[ -f .htaccess && -z "$(git status --porcelain)" ]]

# An interrupted or failed first seed is imported again, never mistaken for a complete database.
export VERIFY_RESULT=1
reject bash "$CLI" up
[[ ! -e .pw-runtime/state/seeded ]]
unset VERIFY_RESULT
bash "$CLI" up > /dev/null 2>&1
[[ "$(exports)" == 3 ]]
bash "$CLI" down 2> /dev/null

# A registration left by a removed worktree at this same path is deleted before a fresh start.
touch "$FAKE_ACTIVE"
: > "$FAKE_LOG"
bash "$CLI" up > /dev/null 2>&1
[[ "$(grep -n -m1 "^delete -Oy $EXPECTED_SLUG$" "$FAKE_LOG" | cut -d: -f1)" -lt "$(grep -n -m1 '^start' "$FAKE_LOG" | cut -d: -f1)" ]]
bash "$CLI" down 2> /dev/null

# Unsafe or missing copy-from-main entries fail closed before any start.
: > "$FAKE_LOG"
printf '../outside\n' > .pw-runtime/copy-from-main
reject bash "$CLI" up
grep -q 'unsafe path' "$TMP/rejected.log"
bash "$CLI" down 2> /dev/null
printf 'not-in-main\n' > .pw-runtime/copy-from-main
reject bash "$CLI" up
grep -q 'not-in-main is missing' "$TMP/rejected.log"
! grep -q '^start' "$FAKE_LOG"
bash "$CLI" down 2> /dev/null
git checkout -q .pw-runtime/copy-from-main

# gc deletes only runtimes whose folder is gone and whose name proves the path; up runs it first.
gone="$TMP/removed-wt"
orphan="source-removed-wt-$(path_hash "$gone")"
FAKE_EXTRA="$(jq -cn --arg gone "$gone" --arg orphan "$orphan" --arg live "$TMP/123" --arg livename "source-123-$(path_hash "$TMP/123")x" '[
    {name:$orphan, approot:$gone, status:"project directory missing"},
    {name:"unrelated", approot:($gone + "2"), status:"project directory missing"},
    {name:("source-removed-wt-" + "000000"), approot:$gone, status:"project directory missing"},
    {name:$orphan, approot:$gone, status:"stopped"},
    {name:$livename, approot:$live, status:"project directory missing"}]')"
export FAKE_EXTRA
: > "$FAKE_LOG"
bash "$CLI" gc 2> /dev/null
[[ "$(grep '^delete' "$FAKE_LOG")" == "delete -Oy $orphan" ]]
: > "$FAKE_LOG"
bash "$CLI" up > /dev/null 2>&1
[[ "$(grep -n -m1 "^delete -Oy $orphan$" "$FAKE_LOG" | cut -d: -f1)" -lt "$(grep -n -m1 '^start' "$FAKE_LOG" | cut -d: -f1)" ]]
export DELETE_FAIL=yes
reject bash "$CLI" gc
unset DELETE_FAIL FAKE_EXTRA
bash "$CLI" down 2> /dev/null

# Private files: seed cache plus reflinks, on a filesystem that supports them.
mkdir "$BULK/cache" "$BULK/wt"
if ! can_reflink "$BULK/cache" "$BULK/wt"; then
    echo 'SKIP: private files assertions (~/.cache does not support reflinks)'
    echo 'PASS: orchestration, hooks, teardown, stale registration and gc (private files skipped)'
    exit 0
fi
export XDG_CACHE_HOME="$BULK/cache"
git -C "$SRC" worktree add --detach -q "$BULK/wt/456" HEAD
enter "$BULK/wt/456"
mkdir -p "$SRC/site/assets/files/sub"
dd if=/dev/urandom of="$SRC/site/assets/files/sub/shared" bs=64K count=2 status=none
printf 'before\n' > "$SRC/site/assets/files/changed"
printf 'delete me\n' > "$SRC/site/assets/files/deleted"
bash "$CLI" up > "$TMP/private.json" 2> "$TMP/up.log"
jq -e '.fileMode == "private"' "$TMP/private.json" > /dev/null
seed="$XDG_CACHE_HOME/pw-runtime/$(printf '%s' "$SRC" | sha1sum | cut -c1-12)/files-seed"
[[ -d "$seed" && ! -e .ddev/docker-compose.pw-runtime.yaml ]]
grep -q 'first files seed' "$TMP/up.log"
cmp "$SRC/site/assets/files/sub/shared" "$seed/sub/shared"
cmp "$SRC/site/assets/files/sub/shared" site/assets/files/sub/shared
# A second checkout shares the seed's extents but not its writes.
mkdir -p "$BULK/wt/789/files"
seed_reflink_copy "$SRC/site/assets/files" "$seed" "$BULK/wt/789/files" 2> /dev/null
if [[ "$(stat -f -c %T "$BULK")" == btrfs ]] && command -v btrfs > /dev/null; then
    [[ "$(btrfs filesystem du -s --raw "$BULK/wt/789/files" | awk 'NR == 2 {print $2}')" == 0 ]]
else
    echo 'SKIP: btrfs exclusive-byte assertion (not btrfs or btrfs command unavailable)'
fi
printf 'private write\n' > "$BULK/wt/789/files/sub/shared"
cmp "$SRC/site/assets/files/sub/shared" "$seed/sub/shared"
cmp "$SRC/site/assets/files/sub/shared" site/assets/files/sub/shared
# Source updates and deletions reach the seed and new copies, never existing private files.
printf 'after, changed size\n' > "$SRC/site/assets/files/changed"
rm "$SRC/site/assets/files/deleted"
mkdir "$BULK/wt/fresh"
seed_reflink_copy "$SRC/site/assets/files" "$seed" "$BULK/wt/fresh" 2> /dev/null
cmp "$SRC/site/assets/files/changed" "$BULK/wt/fresh/changed"
[[ ! -e "$seed/deleted" && ! -e "$BULK/wt/fresh/deleted" ]]
bash "$CLI" up > "$TMP/private-reused.json" 2> /dev/null
jq -e '.fileMode == "private"' "$TMP/private-reused.json" > /dev/null
[[ "$(< site/assets/files/changed)" == before && -f site/assets/files/deleted ]]
# A cross-device seed reports "no reflink" before any bulk copy; a seed inside a checkout is rejected.
rc=0
(seed_reflink_copy "$SRC/site/assets/files" "$TMP/seed" "$BULK/wt/fresh") 2> /dev/null || rc=$?
can_reflink "$TMP" "$BULK/wt" || [[ "$rc" == 3 && ! -e "$TMP/seed" ]]
reject seed_reflink_copy "$SRC/site/assets/files" "$PWD/cache/files-seed" "$BULK/wt/fresh"
grep -q 'seed must be outside Git checkouts' "$TMP/rejected.log"
bash "$CLI" down 2> /dev/null
[[ -f site/assets/files/changed && ! -e .pw-runtime/state ]] # private files stay until the worktree goes
echo 'PASS: orchestration, hooks, teardown, stale registration, gc and private files'
