import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { withSideChatFixture } from "./fixtures/side-chat.mjs";

const workspace = join(import.meta.dirname, "..");
const app = resolve(process.argv[2] ?? join(workspace, "dist", "tncode.app"));
const sidecar = join(app, "Contents/Resources/Sidecar");
const node = join(app, "Contents/Helpers/node");
const installed = JSON.parse(readFileSync(join(sidecar, "node_modules/@earendil-works/pi-coding-agent/package.json")));
assert.equal(installed.version, "1.6.1");
await withSideChatFixture(node, join(sidecar, "worker.mjs"), async environment => {
  const run = spawn("swift", ["test", "--disable-sandbox", "--filter", "SideChatWorkflowTests", ...process.argv.slice(3)], {
    cwd: workspace, stdio: "inherit",
    env: { ...process.env, ...environment, SWIFTPM_MODULECACHE_OVERRIDE: process.env.SWIFTPM_MODULECACHE_OVERRIDE ?? join(workspace, ".build/module-cache") },
  });
  const [status, signal] = await once(run, "close");
  assert.equal(signal, null);
  assert.equal(status, 0);
});
