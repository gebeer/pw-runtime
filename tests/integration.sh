#!/usr/bin/env bash
# Opt-in integration test with real DDEV. It builds its own throwaway source project
# (pwrt-itest: ProcessWire-shaped) plus one runtime, and deletes both. No real project is touched.
# Usage: bash tests/integration.sh [DB_TYPE DB_VERSION]   (default: mariadb 10.11)
set -euo pipefail
trap 'echo "FAIL: assertion at line $LINENO" >&2' ERR
CLI="$(realpath "$(dirname "$0")/../pw-runtime")"
DB_TYPE="${1:-mariadb}" DB_VERSION="${2:-10.11}"
TMP="$(mktemp -d "$HOME/.cache/pw-runtime-itest.XXXXXX")" # reflink-capable here, so files are private
export XDG_CACHE_HOME="$TMP/cache"                         # never the real seed cache
SRC="$TMP/main"
WT="$TMP/wt/Feature_X"
git() { command git -c user.name=test -c user.email=test@example.invalid "$@"; }
cleanup() {
    local status=$?
    trap - EXIT ERR
    (cd "$WT" 2>/dev/null && bash "$CLI" down) || true
    bash "$CLI" gc || true
    ddev delete -Oy pwrt-itest >/dev/null 2>&1 || true
    rm -rf "$TMP"
    if ddev list -j | jq -e '[.raw[]? | select(.name | startswith("pwrt-itest"))] | length > 0' >/dev/null; then
        echo 'CLEANUP INCOMPLETE: pwrt-itest* DDEV projects remain' >&2
        status=1
    fi
    exit "$status"
}
trap cleanup EXIT

mkdir -p "$SRC/.ddev" "$SRC/site/assets/files" "$SRC/.pw-runtime" "$TMP/wt"
git init -q -b main "$SRC"
cat > "$SRC/.ddev/config.yaml" <<YAML
name: pwrt-itest
type: php
docroot: ""
php_version: "8.4"
webserver_type: apache-fpm
additional_hostnames: ["www.pwrt-itest"]
database:
    type: $DB_TYPE
    version: "$DB_VERSION"
YAML
# Like ProcessWire: site/config-dev.php replaces site/config.php when present.
cat > "$SRC/index.php" <<'PHP'
<?php
$config = new stdClass();
$dev = __DIR__ . '/site/config-dev.php';
require is_file($dev) ? $dev : __DIR__ . '/site/config.php';
$pdo = new PDO("mysql:host=$config->dbHost;dbname=$config->dbName;port=$config->dbPort", $config->dbUser, $config->dbPass);
header('Content-Type: text/plain');
echo 'secrets=' . $pdo->query("SELECT COUNT(*) FROM modules WHERE data != ''")->fetchColumn()
    . ' hosts=' . implode(',', $config->httpHosts) . ' mail=' . $config->wireMail['module'] . "\n";
PHP
printf '<?php namespace ProcessWire;\n$config->dbHost = "live.invalid";\n' > "$SRC/site/config.php"
printf "UPDATE modules SET data = '' WHERE class = 'Mailer';\n" > "$SRC/.pw-runtime/sanitize.sql"
printf "SELECT COUNT(*) FROM modules WHERE class = 'Mailer' AND data != '';\n" > "$SRC/.pw-runtime/verify.sql"
printf 'site/assets/\n' > "$SRC/.gitignore"
git -C "$SRC" add .
git -C "$SRC" commit -qm initial
cat > "$SRC/site/config-dev.php" <<'PHP'
<?php namespace ProcessWire;
$config->dbHost = 'db'; $config->dbName = 'db'; $config->dbUser = 'db'; $config->dbPass = 'db'; $config->dbPort = '3306';
$config->httpHosts = ['pwrt-itest.ddev.site', 'www.pwrt-itest.ddev.site'];
$config->wireMail = ['module' => 'WireMailSmtp'];
PHP
printf 'upload\n' > "$SRC/site/assets/files/upload.txt"
(cd "$SRC" && ddev start -y >/dev/null 2>&1)
(cd "$SRC" && ddev mysql -e "CREATE TABLE modules (class VARCHAR(64), data TEXT); INSERT INTO modules VALUES ('Mailer', 'secret');")
source_state() { (cd "$SRC" && ddev mysql -N -e 'CHECKSUM TABLE modules;'); }
before="$(source_state)"
http() { # expected status, URL; the body lands in $TMP/body
    local code
    code="$(curl --noproxy '*' -ksS -o "$TMP/body" -w '%{http_code}' "$2")"
    [[ "$code" == "$1" ]] || { echo "FAIL: expected HTTP $1 from $2, got $code: $(head -c 300 "$TMP/body")" >&2; return 1; }
}
http 200 https://pwrt-itest.ddev.site/
[[ "$(<"$TMP/body")" == 'secrets=1 '* ]]

git -C "$SRC" worktree add --detach -q "$WT" HEAD
cd "$WT"
bash "$CLI" guard
if php -n -r 'require "site/config-dev.php";' >/dev/null 2>&1; then echo 'FAIL: code-only boot was not blocked' >&2; exit 1; fi
bash "$CLI" up > "$TMP/ready.json"
slug="$(jq -r .slug "$TMP/ready.json")"
url="$(jq -r .url "$TMP/ready.json")"
[[ "$slug" =~ ^pwrt-itest-feature-x-[0-9a-f]{6}$ && "$url" == "https://www.$slug.ddev.site" ]]
jq -e '.fileMode == "private" and .ready == true' "$TMP/ready.json" >/dev/null
[[ "$(ddev describe -j | jq -r '.raw | .name + " " + .approot + " " + .database_type + ":" + .database_version')" == "$slug $WT $DB_TYPE:$DB_VERSION" ]]
[[ -z "$(git status --porcelain)" ]]
# Private files: no source mount, and container writes stay in this worktree.
docker inspect "ddev-$slug-web" | jq -e --arg src "$SRC" '.[0].Mounts | all(.Source | startswith($src) | not)' >/dev/null
ddev exec --raw -- touch site/assets/files/probe
[[ -f site/assets/files/probe && -f site/assets/files/upload.txt && ! -e "$SRC/site/assets/files/probe" ]]
# Own sanitized database, own hostnames, core mail transport.
http 200 "$url/"
[[ "$(<"$TMP/body")" == "secrets=0 hosts=$slug.ddev.site,www.$slug.ddev.site mail=WireMail" ]]
http 200 "https://$slug.ddev.site/"
# A mutation in the runtime database survives a repeated up (no re-import).
ddev mysql -e 'CREATE TABLE runtime_only (id INT); INSERT INTO runtime_only VALUES (1);'
bash "$CLI" up >/dev/null
[[ "$(ddev mysql -N -e 'SELECT COUNT(*) FROM runtime_only')" == 1 ]]
# HTTP is blocked before the application boots whenever readiness is absent.
rm .pw-runtime/state/ready
http 503 "$url/"
touch .pw-runtime/state/ready
http 200 "$url/"
[[ "$(source_state)" == "$before" ]] || { echo 'FAIL: source database changed' >&2; exit 1; }
[[ "$(cd "$SRC" && ddev describe -j | jq -r .raw.status)" == running ]]
echo 'PASS: source unchanged; runtime has its own database, hostnames and private files; retry and HTTP gate verified'

bash "$CLI" down
[[ -z "$(ddev list -j | jq -r --arg slug "$slug" '.raw[]? | select(.name == $slug) | .name')" ]]
[[ ! -e .pw-runtime/state && ! -e .ddev/config.local.yaml && ! -e site/config-pw-runtime.php && -z "$(git status --porcelain)" ]]
grep -q 'code-only guard' site/config-dev.php
echo 'PASS: teardown removed only the runtime'

# gc: the worktree folder disappears without a teardown.
bash "$CLI" up >/dev/null
cd "$TMP"
rm -rf "$WT"
git -C "$SRC" worktree prune
bash "$CLI" gc
[[ -z "$(ddev list -j | jq -r --arg slug "$slug" '.raw[]? | select(.name == $slug) | .name')" ]]
http 200 https://pwrt-itest.ddev.site/
[[ "$(source_state)" == "$before" ]]
echo 'PASS: gc removed the orphaned runtime and left the source alone'
