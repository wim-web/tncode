import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, symlinkSync } from "node:fs";
import { withCommitWritingFixture } from "./fixtures/commit-writing.mjs";
import { join, resolve } from "node:path";

const workspace = join(import.meta.dirname, "..");
const sidecar = join(workspace, "Sidecar");
const sdk = "node_modules/@earendil-works/pi-coding-agent";
const modules = resolve(process.env.PI_TEST_NODE_MODULES ?? join(sidecar, "node_modules"));
const lock = JSON.parse(readFileSync(join(sidecar, "package-lock.json"), "utf8"));
const pi = JSON.parse(readFileSync(join(modules, "@earendil-works/pi-coding-agent/package.json"), "utf8"));
assert.equal(pi.version, lock.packages[sdk].version);

const root = realpathSync(mkdtempSync("/private/tmp/pi-commit-writing-"));
const worker = join(root, "sidecar", "worker.mjs");
mkdirSync(join(root, "sidecar"));
for (const path of ["worker.mjs", "agent-questions.mjs", "tool-approval.mjs"]) {
  copyFileSync(join(sidecar, path), join(root, "sidecar", path));
}
symlinkSync(modules, join(root, "sidecar", "node_modules"));
console.log(`Pi ${pi.version} evidence in ${root}`);
await withCommitWritingFixture(process.execPath, worker, async environment => {
  const run = spawn("swift", ["test", "--disable-sandbox", "--filter", "CommitWritingTests", ...process.argv.slice(2)], {
    cwd: workspace,
    env: {
      ...Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith("GIT_"))),
      GIT_CONFIG_GLOBAL: "/dev/null",
      GIT_CONFIG_NOSYSTEM: "1",
      ...environment,
    },
    stdio: "inherit",
  });
  const [code, signal] = await once(run, "close");
  assert.equal(signal, null);
  assert.equal(code, 0);
}, root);
