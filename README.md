# pw-runtime

Gives a linked git worktree of a ProcessWire + DDEV project its own runtime: own DDEV
project, database, hostnames, cache, logs and sessions. It never writes to the main
checkout's database or files, and never starts, stops or changes the main DDEV project.

```sh
pw-runtime guard   # fresh worktree: block ProcessWire until a runtime exists, copy agent config (no DDEV)
pw-runtime up      # create or reuse this worktree's runtime; prints one JSON line
pw-runtime down    # delete this worktree's runtime; run before removing the worktree
pw-runtime gc      # delete runtimes whose worktree folder is gone
```

Run every command inside the worktree. Needs `ddev`, `jq`, `flock`, `rsync`, `curl`, GNU `cp`.

## Install

```sh
./install.sh
```

It links the CLI to `~/.local/bin/pw-runtime` and the agent skill
([`.agents/skills/pw-runtime/SKILL.md`](.agents/skills/pw-runtime/SKILL.md)) to `~/.agents/skills/pw-runtime`
(pi) and, through that entry, to `~/.claude/skills/pw-runtime` (Claude Code). It can be repeated
and never replaces an entry it did not create.

## Project opt-in: `.pw-runtime/` (tracked)

| File | Required | Purpose |
| --- | --- | --- |
| `sanitize.sql` | yes | Runs in the runtime database after the import and on every `up`, before ProcessWire may boot. Blank mail credentials, API keys, cron triggers. Must be idempotent. |
| `verify.sql` | no | Runs after `sanitize.sql`; must print exactly `0`, else `up` fails and HTTP stays 503. |
| `after-up.sh` | no | Runs from the worktree root on every `up` (`bash -e -o pipefail`), after sanitizing, while HTTP still answers 503 (CLI works). Gets `PW_RUNTIME_SLUG`, `PW_RUNTIME_URL`, `PW_RUNTIME_SOURCE`. A failure keeps the runtime not ready. |
| `copy-from-main` | no | Untracked paths to copy from the main checkout, one per line (`#` comments), e.g. `.htaccess`, `site/templates/dist`. Copied once; an existing copy is kept. The paths are added to the repository's `info/exclude`. |

A project without `.pw-runtime/sanitize.sql` is refused by `up`; `guard` and `down` do nothing there.
`.pw-runtime/state/` is generated runtime metadata, never committed.

## What is derived

- **Source** = the main worktree (parent of `git rev-parse --git-common-dir`). It must already be running in DDEV; `up` never starts it.
- **Name** = `<source DDEV name>-<worktree folder>-<6 hex of a salted path hash>`.
- **Hostnames** = the source's hostnames with the project name replaced; a hostname without the project name is dropped with a notice. The URL uses `www.` when the source has a `www.` hostname.
- **Database type and version, PHP, add-ons** = the tracked `.ddev/config.yaml` of the worktree. Name and hostnames are overridden in a generated `.ddev/config.local.yaml`.
- **Config** = generated `site/config-dev.php`. It answers 503 to HTTP until the database is imported and sanitized, then loads a private copy of the source's `site/config-dev.php` (or the tracked `site/config.php` if the source has none) and forces the database to the runtime's own `db` container, core WireMail (DDEV's Mailpit) and the runtime `httpHosts`.
- **Files** = private: a per-source seed in `~/.cache/pw-runtime/<hash>/files-seed` is refreshed with `rsync -a --delete` and reflinked into the worktree. The first seed is one full copy. Where a reflink is impossible, the source's `site/assets/files` is mounted read-only instead, with a notice; uploads and new image variations then fail.
- **Agent config** = `guard` and `up` copy `.agents`, `.claude` and `.pi` from the main checkout, each only if it exists there, the repository does not track it and the worktree has none. Symlinks are copied as symlinks. An existing copy is never updated, and `down` leaves the copies; they go with the worktree.
- **Ignore rules** for generated and copied files go into the repository's `info/exclude`, so they never show in `git status` and do not block `git worktree remove`.

## Safety

- One lock per worktree; identity is checked by name and by the folder DDEV registered.
- `down` deletes only the DDEV project with this worktree's name, registered at this folder, and only files carrying the `pw-runtime: generated` marker. Private files, cache and logs stay until the worktree is removed. Without runtime metadata it does nothing and succeeds.
- `gc` deletes a DDEV project only if DDEV reports its folder missing and its name ends in the folder name and path hash recomputed from that folder. `up` runs `gc` first.
- A repeated `up` keeps the runtime database and private files. A failed first import is imported again.
- `up` prints its JSON line and exits 0 only once the runtime URL answers. It polls up to 30 times while DDEV's router answers 502, 404 or nothing; if that persists, or the site answers 5xx, `up` fails without JSON and points to `ddev logs`. The runtime stays provisioned (HTTP stays open) so the error can be debugged; run `up` again after the fix.
- The seed cache is never deleted by the tool. To rebuild it: `(flock 7; rm -rf -- "$seed") 7>"$seed.lock"`.

Known limits:

- Fixed host ports in `.ddev/config.yaml` (`host_db_port` and similar) would collide; `additional_fqdns` are not carried over.

## Apache-level HTTPS in DDEV

DDEV's router ends TLS and talks plain http to the web container, so Apache's `%{HTTPS}` stays
off and `.htaccess` redirects built on it point to `http://`. Do not fix this with a tracked
`.ddev/traefik/config/<project>.yaml`: in a worktree the project has another name, DDEV merges
that file as an extra one, the main project's routers are defined twice, and every start waits
60 s for a router count that never matches.

Track a name-free delta instead and let DDEV generate its own router file:

1. Copy [`examples/https-parity.tpl.yaml`](examples/https-parity.tpl.yaml) to `.ddev/traefik/https-parity.tpl.yaml`.
2. Add the hook to `.ddev/config.yaml` (merge it with hooks already there):

   ```yaml
   hooks:
     pre-start:
       - exec-host: mkdir -p .ddev/traefik/config && sed "s/__NAME__/$DDEV_SITENAME/g" .ddev/traefik/https-parity.tpl.yaml > .ddev/traefik/config/https-parity.yaml
   ```

3. Ignore `/.ddev/traefik/config/` in the project's `.gitignore` and track no file there.

DDEV merges the generated delta over its own config: the https router forwards to Apache's TLS
vhost on port 443, the http router redirects to https. It works the same in the main project
and in every runtime.

## Tests

```sh
bash tests/guards.sh        # fake ddev: safety refusals
bash tests/runtime.sh       # fake ddev: orchestration, hooks, gc, private files
bash tests/install.sh       # install.sh against a throwaway HOME
bash tests/integration.sh   # real DDEV, about a minute: builds and deletes its own throwaway projects (pwrt-itest*)
bash tests/integration.sh mysql 8.0
```
