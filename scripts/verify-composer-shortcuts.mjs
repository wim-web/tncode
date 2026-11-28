import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { withComposerShortcutFixture } from "./fixtures/composer-shortcuts.mjs";
import { requireDedicatedDesktop } from "./fixtures/desktop-session.mjs";

requireDedicatedDesktop();

const workspace = join(import.meta.dirname, "..");
const sidecar = join(workspace, "Sidecar");
const sdk = "node_modules/@earendil-works/pi-coding-agent";
const lock = JSON.parse(readFileSync(join(sidecar, "package-lock.json"), "utf8"));
const installed = JSON.parse(readFileSync(join(sidecar, sdk, "package.json"), "utf8"));
assert.equal(installed.version, lock.packages[sdk].version);
await withComposerShortcutFixture(process.execPath, join(sidecar, "worker.mjs"), async environment => {
  const run = spawn("swift", ["test", "--disable-sandbox", "--filter", "ComposerShortcutTests", ...process.argv.slice(2)], {
    cwd: workspace,
    env: {
      ...process.env, ...environment,
      CLANG_MODULE_CACHE_PATH: process.env.CLANG_MODULE_CACHE_PATH ?? join(workspace, ".build/local-clang-cache"),
      SWIFTPM_MODULECACHE_OVERRIDE: process.env.SWIFTPM_MODULECACHE_OVERRIDE ?? join(workspace, ".build/module-cache"),
    },
    stdio: "inherit",
  });
  const [exitCode, signal] = await once(run, "close");
  assert.equal(signal, null);
  assert.equal(exitCode, 0);
});
