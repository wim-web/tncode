import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { resolve } from "node:path";
import { withModelRoutingFixture } from "./fixtures/model-routing.mjs";

const workspace = resolve(import.meta.dirname, "..");
const contents = process.env.PI_WORKSPACE_VERIFY_APP && resolve(process.env.PI_WORKSPACE_VERIFY_APP, "Contents");
const node = contents ? resolve(contents, "Helpers/node") : process.execPath;
const worker = contents ? resolve(contents, "Resources/Sidecar/worker.mjs") : resolve(workspace, "Sidecar/worker.mjs");
await withModelRoutingFixture(node, worker, async environment => {
  const child = spawn("swift", ["test", "--disable-sandbox", "--filter", "ModelRoutingWireTests", ...process.argv.slice(2)], {
    cwd: workspace, stdio: "inherit", env: { ...process.env, ...environment },
  });
  const [status, signal] = await once(child, "close");
  assert.equal(signal, null);
  assert.equal(status, 0);
});
