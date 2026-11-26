import { strict as assert } from "node:assert";
import { spawn, spawnSync } from "node:child_process";
import { randomBytes, randomUUID, timingSafeEqual } from "node:crypto";
import { once } from "node:events";
import { appendFileSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, unlinkSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { join } from "node:path";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";

const root = import.meta.dirname;
const run = mkdtempSync(join(root, "run-"));
const cwd = join(run, "work");
const config = join(run, "config");
const logs = join(run, "logs");
for (const path of [cwd, config, logs]) mkdirSync(path, { mode: 0o700 });
const report = join(logs, "report.log");
const keychain = join(run, "keychain");
const id = randomUUID();
const key = randomBytes(32).toString("hex");
const bearer = Buffer.from(`Bearer ${key}`);
const upstream = "http://127.0.0.1:18541/v1/chat/completions";
const endpoint = "/v1/chat/completions";
let rejected = 0;
let forwarded = 0;
let upstreamStatus;

const server = createServer(async (request, response) => {
  if (request.method !== "POST" || request.url !== endpoint) {
    response.writeHead(404).end();
    return;
  }
  const header = Buffer.from(request.headers.authorization ?? "");
  if (header.length !== bearer.length || !timingSafeEqual(header, bearer)) {
    rejected++;
    request.resume();
    response.writeHead(401).end();
    return;
  }
  forwarded++;
  try {
    const result = await fetch(upstream, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: request,
      duplex: "half",
      redirect: "error",
      signal: AbortSignal.timeout(45_000),
    });
    upstreamStatus = result.status;
    response.writeHead(result.status, { "content-type": result.headers.get("content-type") });
    await pipeline(Readable.fromWeb(result.body), response);
  } catch {
    if (!response.headersSent) response.writeHead(502).end();
    else response.destroy();
  }
});

function record(line) {
  const safe = line.replaceAll(key, "[redacted]");
  appendFileSync(report, `${safe}\n`, { mode: 0o600 });
  console.log(safe);
}

function keychainCommand(command, input) {
  const result = spawnSync(keychain, [command, id], { input, encoding: "utf8", timeout: 10_000 });
  if (result.error) throw result.error;
  return result;
}

async function worker(mode, label, port) {
  const child = spawn(process.execPath, [join(root, "worker.mjs"), mode, keychain, id, String(port)], {
    cwd,
    env: { PATH: "/usr/bin:/bin", PI_CODING_AGENT_DIR: config, PI_OFFLINE: "1", PI_TELEMETRY: "0" },
    stdio: ["ignore", "pipe", "pipe"],
    timeout: 55_000,
  });
  const output = { stdout: [], stderr: [] };
  for (const stream of ["stdout", "stderr"]) {
    child[stream].setEncoding("utf8").on("data", (chunk) => output[stream].push(chunk));
  }
  const [status] = await once(child, "close");
  for (const stream of ["stdout", "stderr"]) {
    const value = output[stream].join("");
    assert(!value.includes(key), `Raw ${label} ${stream} contained the key`);
    if (value) writeFileSync(join(logs, `${label}.${stream}.log`), value, { mode: 0o600 });
  }
  assert.equal(status, 0, `${label} failed: ${output.stderr.join("").trim()}`);
  return JSON.parse(output.stdout.join(""));
}

function scan(directory, needle) {
  const matches = { authFiles: [], plaintext: [] };
  for (const entry of readdirSync(directory, { recursive: true, withFileTypes: true })) {
    const path = join(entry.parentPath, entry.name);
    if (entry.name === "auth.json") matches.authFiles.push(path);
    if (entry.isFile() && readFileSync(path).includes(needle)) matches.plaintext.push(path);
    assert(!entry.isSymbolicLink(), `Unscanned symlink: ${path}`);
  }
  return matches;
}

let added = false;
try {
  const compiled = spawnSync("/usr/bin/swiftc", ["-module-cache-path", join(run, "swift-cache"), join(root, "keychain.swift"), "-o", keychain], { encoding: "utf8", timeout: 45_000 });
  if (compiled.error) throw compiled.error;
  assert.equal(compiled.status, 0, compiled.stderr);
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const port = server.address().port;
  record(`Run directory: ${run}`);

  const control = join(cwd, "auth.json");
  const marker = "public-scanner-control";
  writeFileSync(control, marker, { flag: "wx", mode: 0o600 });
  try {
    assert.deepEqual(scan(cwd, marker), { authFiles: [control], plaintext: [control] });
  } finally {
    unlinkSync(control);
  }
  record("File scanner control: detected auth.json and a public marker");

  const missing = await worker("check", "missing", port);
  assert.equal(missing.auth, null);
  const denied = await fetch(`http://127.0.0.1:${port}${endpoint}`, { method: "POST" });
  assert.equal(denied.status, 401);
  assert.equal(forwarded, 0);
  record("Missing Keychain item: no SDK auth. Gateway without a key: HTTP 401, no inference");

  const stored = keychainCommand("add", key);
  assert.equal(stored.status, 0, stored.stderr);
  added = true;
  const before = await worker("check", "before-restart", port);
  assert.equal(before.auth, "stored credential");
  const after = await worker("prompt", "after-restart", port);
  assert.notEqual(before.pid, after.pid);
  assert.equal(rejected, 1);
  assert.equal(forwarded, 1);
  assert.equal(upstreamStatus, 200);
  record(`SDK processes: ${before.pid} (${before.auth}) then ${after.pid}`);
  record(`Authenticated requests: ${forwarded}. Ollama: HTTP ${upstreamStatus}. Pi stop reason: ${after.stop}`);
  record(`Model answer: ${JSON.stringify(after.answer)}`);
} catch (error) {
  record(`FAIL: ${error.message}`);
  process.exitCode = 1;
} finally {
  try {
    if (added) {
      const deleted = keychainCommand("delete");
      const found = keychainCommand("exists");
      assert(deleted.status === 0 && found.status === 44,
        `could not confirm cleanup of Keychain service dev.pi-keychain-probe.${id.toUpperCase()}`);
      record("Disposable Keychain item deleted and confirmed absent");
    }
  } catch (error) {
    record(`FAIL: ${error.message}`);
    process.exitCode = 1;
  }
  try {
    for (const path of [cwd, config, logs]) {
      const matches = scan(path, key);
      assert.deepEqual(matches, { authFiles: [], plaintext: [] });
      record(`Scanned ${path}: no auth.json or plaintext probe key`);
    }
  } catch (error) {
    record(`FAIL: ${error.message}`);
    process.exitCode = 1;
  } finally {
    server.close();
  }
}
