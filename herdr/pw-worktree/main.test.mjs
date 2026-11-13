// The two pw-runtime additions of this clone, with Herdr's functions stubbed:
// node herdr/pw-worktree/main.test.mjs
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const source = readFileSync(new URL("./main.js", import.meta.url), "utf8")
  .replace(/^import .*;\n/gm, "").replace("export default class", "class");

// pw: what `pw-runtime` does: "missing" (cannot start), or its exit code.
function fixture(pw) {
  const w = { calls: [], notes: [], git: [] };
  const sandbox = {
    View: class {},
    props: () => ({ space: "space" }),
    spaces: () => [{ id: "space", name: "wt" }],
    run: (name, args) => w.calls.push(name),
    notify: (n) => w.notes.push(n),
    exec: async (command, args) => {
      if (command === "pw-runtime") {
        w.calls.push(`pw-runtime ${args[0]}`);
        if (pw === "missing") throw new Error("not installed");
        return { code: pw, stdout: "", stderr: pw ? "pw-runtime: working\npw-runtime: ERROR: boom\n" : "" };
      }
      w.git.push(args.find((a) => ["show-ref", "worktree", "status", "rev-parse", "config"].includes(a)) + (args.includes("remove") ? " remove" : ""));
      // No such branch yet, and no submodules.
      return { code: args.includes("show-ref") || args.includes("config") ? 1 : 0, stdout: "", stderr: "" };
    },
  };
  vm.runInNewContext(source + "\nglobalThis.Mod = Worktree;", sandbox);
  w.mod = Object.assign(Object.create(sandbox.Mod.prototype), {
    text: "feature/x", userHome: "/home/u", on: null, dirty: false, unpushed: [],
    repo: { top: "/repo/wt", main: "/repo", name: "repo", linked: true },
  });
  return w;
}

// Create: the space opens whatever the guard does; a missing or failing guard is only reported.
for (const [pw, body] of [[0, null], [1, "pw-runtime: ERROR: boom"], ["missing", "pw-runtime is not installed."]]) {
  const w = fixture(pw);
  assert.equal(await w.mod.create(), "");
  assert.deepEqual(w.calls, ["pw-runtime guard", "space.new"]);
  assert.deepEqual(w.notes.map((n) => n.body), body ? [body] : []);
}

// Remove: a failing down stops before the space is closed or the worktree removed.
{
  const w = fixture(1);
  assert.equal(await w.mod.remove(), "pw-runtime: ERROR: boom");
  assert.deepEqual(w.calls, ["pw-runtime down"]);
  assert.ok(!w.git.includes("worktree remove"));
}

// Remove: with down done, or pw-runtime not installed, it goes on as Herdr's mod does.
for (const pw of [0, "missing"]) {
  const w = fixture(pw);
  assert.equal(await w.mod.remove(), "");
  assert.deepEqual(w.calls, ["pw-runtime down", "space.close"]);
  assert.ok(w.git.includes("worktree remove"));
}

console.log("pw-worktree tests passed");
