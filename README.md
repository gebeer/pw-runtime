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
ln -s ~/repos/pw-runtime/pw-runtime ~/.local/bin/pw-runtime
```

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
- **Router** = if the project tracks a customized `.ddev/traefik/config/<name>.yaml` (no `#ddev-generated`), the runtime gets its own copy with the name replaced.
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

- A tracked customized router file also lands in the worktree. DDEV merges it into the runtime's router config, so the main project's routers are defined twice. Harmless while both copies are equal; a branch that changes that file may change the main project's routing while its runtime runs.
- Fixed host ports in `.ddev/config.yaml` (`host_db_port` and similar) would collide; `additional_fqdns` are not carried over.

## Tests

```sh
bash tests/guards.sh        # fake ddev: safety refusals
bash tests/runtime.sh       # fake ddev: orchestration, hooks, gc, private files
bash tests/integration.sh   # real DDEV, about a minute: builds and deletes its own throwaway projects (pwrt-itest*)
bash tests/integration.sh mysql 8.0
```
