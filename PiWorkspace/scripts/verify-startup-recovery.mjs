import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, renameSync, rmdirSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { seedPaletteMessageHistory } from "./fixtures/palette-message-history.mjs";

export async function verifyStartupRecovery(driver, { root, app, launch, quit, record }) {
  const { press, dismiss, until, visible, value, checkCopy } = driver;
  const run = (tool, args) => execFileSync(tool, args, { encoding: "utf8" }).trim();
  const plist = join(app, "Contents/Info.plist");
  const bundleValue = key => run("/usr/bin/plutil", ["-extract", key, "raw", "-o", "-", plist]);
  const product = bundleValue("CFBundleName") + " " + bundleValue("CFBundleShortVersionString");
  const system = run("/usr/bin/sw_vers", ["-productVersion"]).split(".");
  while (system.length < 3) system.push("0");
  const architectures = run("/usr/bin/lipo", ["-archs", join(app, "Contents/MacOS/PiWorkspace")]).split(/\s+/);
  const id = randomUUID().toUpperCase(), draft = randomUUID().toUpperCase(), submitted = randomUUID().toUpperCase();
  const folder = join(root, "Project"), index = join(root, "workspace.json"), previous = join(root, "workspace.previous.json");
  mkdirSync(folder, { recursive: true });
  const state = { welcomeCompleted: true, selectedProject: id, projects: [{ id, path: folder, title: "Recovery",
    allowEdits: false, selectedConversation: draft, conversations: [
      { id: draft, title: "Saved draft", archived: false, isDraft: true, composerText: "Recover the private draft." },
      { id: submitted, title: "Existing conversation", archived: false, isDraft: false },
    ] }], model: { provider: "local", model: "unused-recovery-model", endpoint: "http://127.0.0.1:1/v1", contextWindow: 8192 } };
  const backupBytes = Buffer.from(JSON.stringify(state));
  writeFileSync(previous, backupBytes, { mode: 0o600 });
  const { historyPath } = await seedPaletteMessageHistory({ sidecar: join(app, "Contents/Resources/Sidecar"),
    workspace: root, projectID: id, threadID: submitted, cwd: folder, keyword: "private history sentinel" });
  const history = readFileSync(historyPath);
  async function copyAndQuit(reason, paths) {
    await launch("workspace-startup-copy-details", root);
    await until(() => value("workspace-startup-error").includes(reason), reason);
    press("workspace-startup-copy-details");
    const matches = arch => {
      const expected = [product + " (macOS " + system.join(".") + " " + arch + ") could not open its workspace.",
        "Workspace: " + root, reason, ...paths].join("\n");
      try { return checkCopy(expected); } catch { return false; }
    };
    await until(() => architectures.some(matches), "exact version, platform, paths and reason on the dedicated pasteboard");
    await quit("workspace-startup-quit");
    assert.deepEqual(readFileSync(previous), backupBytes);
    assert.deepEqual(readFileSync(historyPath), history);
  }
  const corrupt = Buffer.from('{"privateField":"private-corruption-sentinel",');
  writeFileSync(index, corrupt, { mode: 0o600 });
  const paths = ["Index: " + index, "Previous index: " + previous];
  await copyAndQuit("The workspace index is damaged.", paths);
  assert.deepEqual(readFileSync(index), corrupt);
  renameSync(index, index + ".test-backup");
  await copyAndQuit("The workspace index is missing.", paths);
  assert(!existsSync(index));
  mkdirSync(index);
  await copyAndQuit("Could not access workspace.json.", ["Path: " + index, "Expected a regular file."]);
  assert(statSync(index).isDirectory());
  rmdirSync(index);
  await launch("workspace-startup-restore", root);
  dismiss("workspace-startup-restore");
  await until(() => visible("sidebar-home") && value("composer").includes(state.projects[0].conversations[0].composerText), "normal workspace after repair");
  await quit();
  assert.deepEqual(readFileSync(index), backupBytes);
  assert.deepEqual(readFileSync(historyPath), history);
  record("Copy Details and Quit worked for a corrupt index, a missing index and a directory in its place. The private pasteboard contained only the expected version, OS, architecture, reason and paths. Restore reopened the saved draft with the original index and Pi history bytes.");
}
