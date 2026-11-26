import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const workspace = fileURLToPath(new URL("../../PiWorkspace/", import.meta.url));
const sdk = process.argv[2] ? path.resolve(process.argv[2])
  : path.join(workspace, "Sidecar/node_modules/@earendil-works/pi-coding-agent");
const swift = await readFile(path.join(workspace, "Sources/PiWorkspace/PiProcess.swift"), "utf8");
const childEnvironment = swift.match(/child\.environment\s*=\s*\[([^\]]+)\]/)?.[1];
assert(childEnvironment, "Pi helper launch environment not found");
const telemetry = childEnvironment.match(/"PI_TELEMETRY"\s*:\s*"([^"]*)"/)?.[1];
const offline = childEnvironment.match(/"PI_OFFLINE"\s*:\s*"([^"]*)"/)?.[1];
assert.equal(telemetry, "0");
assert.equal(offline, "1");

const pkg = JSON.parse(await readFile(path.join(sdk, "package.json"), "utf8"));
const { isInstallTelemetryEnabled } = await import(pathToFileURL(path.join(sdk, "dist/core/telemetry.js")));
const { getClientIdentity } = await import(pathToFileURL(path.join(sdk, "dist/core/client-identity.js")));
const settings = { getEnableInstallTelemetry: () => true };

function evaluate(value) {
  process.env.PI_TELEMETRY = value;
  return {
    installReporting: isInstallTelemetryEnabled(settings),
    attributionEnabled: getClientIdentity(settings).attribution !== null,
  };
}

const enabledControl = evaluate("1");
const nativeDefault = evaluate(telemetry);
assert.deepEqual(enabledControl, { installReporting: true, attributionEnabled: true });
assert.deepEqual(nativeDefault, { installReporting: false, attributionEnabled: false });
console.log(JSON.stringify({ sdkVersion: pkg.version, helperEnvironment: { PI_TELEMETRY: telemetry, PI_OFFLINE: offline },
  enabledControl, nativeDefault, scope: "Swift launch configuration and bundled SDK decisions; no network capture." }, null, 2));
