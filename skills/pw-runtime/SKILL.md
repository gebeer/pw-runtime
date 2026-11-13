---
name: pw-runtime
description: Use when working in a linked git worktree of a ProcessWire + DDEV project that has a `.pw-runtime/` folder and the task needs the site running - browser or HTTP checks, PHP or database work through `ddev`, sending test mail - or when ProcessWire throws "Code-only worktree".
---

# pw-runtime

A **runtime** is this worktree's own DDEV project: own database (a sanitized copy of the main project's), own hostnames, own uploads, own Mailpit. A fresh worktree is **code-only**: ProcessWire refuses to boot there until a runtime exists.

All work happens in the worktree and against the runtime URL. The main checkout is read-only for you: `up` reads its database and files, and its DDEV project stays exactly as the user left it. Never start, stop, restart or import into the main project, and never run tests against it.

Contract and details: `README.md` beside the script, `$(dirname "$(readlink -f "$(command -v pw-runtime)")")/README.md`.

## Steps

1. **Edit-only task:** no runtime needed. Start one when the task first needs HTTP, PHP or the database.
2. **Start** from the worktree root:
   ```bash
   out="$(pw-runtime up)" && url="$(jq -r .url <<<"$out")"
   ```
   It takes about a minute; the first run in a project also copies all uploads. Progress goes to stderr. On success stdout is exactly one JSON line and the exit code is 0:
   ```json
   {"slug":"site-feature-ab12cd","url":"https://www.site-feature-ab12cd.ddev.site","fileMode":"private","ready":true}
   ```
   `fileMode: "readonly"` means uploads and image variations fail in this runtime; say so in your report and test those elsewhere.
3. **Use it:** every HTTP check goes to `url`. Once `up` has succeeded, `ddev` commands run from the worktree root act on the runtime. Mail sent with `wireMail()` lands in the runtime's Mailpit: `ddev exec curl -s http://127.0.0.1:8025/api/v1/messages`, or the Mailpit URL in `ddev describe`.
4. **Again:** a repeated `up` is safe; it keeps the runtime database and files. For a fresh database copy run `down`, then `up`.
5. **Finish:** `pw-runtime down` from the worktree root, then `git worktree remove`. `down` deletes the runtime database.

## When `up` fails

Exit code non-zero and no JSON: there is no usable runtime. The last stderr line names the cause. Fix that cause and run `up` again.

| stderr says | Do |
| --- | --- |
| `source must already be running` | Ask the user to start the main project. |
| `this project has not opted in` | Ask the user; what a copy must blank is their decision. |
| `run from a linked git worktree` | You are in the main checkout. Change into the worktree. |
| `verification failed` | The copy still holds live credentials and stays blocked. Report it with the `.pw-runtime/verify.sql` result. |
| `answers HTTP 5xx` (or 502, 404, nothing) | The runtime exists but the site is broken. Read `ddev logs` in the worktree, fix the code, run `up` again. |
| `refusing to overwrite` / `unrecognized` | A file the tool did not write is in the way. Show it to the user. |

`site/config-dev.php`, `site/config-pw-runtime.php` and `.ddev/config.local.yaml` are generated: `up` rewrites them, so change behaviour in the project's own files.
