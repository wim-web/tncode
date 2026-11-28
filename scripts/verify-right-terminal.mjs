import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { join } from "node:path";

export async function verifyRightTerminal(driver, { root, git, launch, quit, record }) {
  const { press, dismiss, visible, value, until, tree } = driver;
  const project = join(root, "Project"), checkout = join(root, "Linked checkout"), proof = join(root, "proof");
  mkdirSync(project, { recursive: true });
  mkdirSync(proof);
  git(project, "init", "--template=", "-b", "main");
  git(project, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false",
      "-c", "core.hooksPath=/dev/null", "commit", "--allow-empty", "-m", "Fixture");
  git(project, "worktree", "add", "-b", "linked", checkout);
  const shell = join(root, "terminal-fixture");
  writeFileSync(shell, '#!/bin/sh\nif [ -t 0 ]; then\n  { pwd -P; tty; } > "$(dirname "$0")/proof/$$"\n  printf "PANEL-SHELL %s\\n" "$$"\nfi\nexec /bin/sh -i\n', { mode: 0o700 });
  const uuid = () => randomUUID().toUpperCase();
  const projectID = uuid(), local = uuid(), linked = uuid();
  const index = join(root, "workspace.json");
  writeFileSync(index, JSON.stringify({ welcomeCompleted: true, selectedProject: projectID,
    projects: [{ id: projectID, title: "Terminal workspace", path: project, allowEdits: false, selectedConversation: local, conversations: [
      { id: local, title: "Local thread", archived: false, isDraft: true, composerText: "Keep local text." },
      { id: linked, title: "Linked thread", archived: false, isDraft: true, composerText: "Keep linked text.",
        location: { worktree: { path: checkout, base: "main" } } },
    ] }], model: { provider: "local", model: "unused-pty-model", endpoint: "http://127.0.0.1:1/v1", contextWindow: 8192 },
  }), { mode: 0o600 });
  const pane = n => "right-terminal-pane-" + n;
  const tab = n => "right-panel-tab-terminal-" + n;
  const readPID = id => Number(value(id).match(/PANEL-SHELL (\d+)/)?.[1]);
  const active = pid => { try { process.kill(pid, 0); return true; } catch (error) { if (error.code === "ESRCH") return false; throw error; } };
  const proofOf = pid => readFileSync(join(proof, String(pid)), "utf8").trimEnd().split("\n");
  async function openPanelSurface(surface) {
    if (!tree().includes('id="hide-right-panel"')) press("toggle-right-panel");
    await until(() => visible("add-panel-surface"), "Add Panel Surface in the right panel");
    press("add-panel-surface");
    await until(() => visible("add-panel-" + surface).includes("enabled=true"), surface + " in Add Panel Surface");
    dismiss("add-panel-" + surface);
  }
  async function add(n) {
    await openPanelSurface("terminal");
    return until(() => readPID(pane(n)), "new right panel PTY " + n);
  }
  async function select(thread, text) {
    press("thread-row-" + thread);
    await until(() => value("composer").includes(text), "selected " + text);
  }
  await launch("toggle-terminal", root, shell);
  press("toggle-terminal");
  const drawer = await until(() => readPID("thread-terminal"), "drawer PTY");
  const right = await add(2);
  assert.notEqual(right, drawer);
  press("hide-right-panel");
  await until(() => !tree().includes('id="' + pane(2) + '"') && readPID("thread-terminal") === drawer, "hidden right pane with independent drawer");
  assert(active(right));
  press("toggle-right-panel");
  await until(() => readPID(pane(2)) === right, "right pane with the same PID");
  await openPanelSurface("files");
  await until(() => visible("files-search"), "Files tab");
  await openPanelSurface("browser");
  await until(() => visible("browser-address"), "Browser tab");
  press(tab(2));
  await until(() => readPID(pane(2)) === right, "terminal tab keeps its shell across Files and Browser");
  await select(linked, "Keep linked text.");
  const other = await add(1);
  assert.deepEqual([drawer, right, other].map(pid => proofOf(pid)[0]), [project, project, checkout].map(path => realpathSync(path)));
  const ttys = [drawer, right, other].map(pid => proofOf(pid)[1]);
  assert(ttys.every(tty => /^\/dev\/ttys\d+$/.test(tty)));
  assert.equal(new Set(ttys).size, 3);
  await select(local, "Keep local text.");
  await until(() => readPID(pane(2)) === right && readPID("thread-terminal") === drawer, "restored two original PTYs");
  press("close-right-panel-terminal-2");
  dismiss("cancel-close-right-terminal");
  await until(() => readPID(pane(2)) === right && !tree().includes('id="cancel-close-right-terminal"'), "cancel kept the tab");
  press("close-right-panel-terminal-2");
  dismiss("confirm-close-right-terminal");
  await until(() => !active(right) && readPID("thread-terminal") === drawer, "only the selected right PTY closed");
  assert(active(other));
  await select(linked, "Keep linked text.");
  await until(() => readPID(pane(1)) === other, "linked checkout retained its own right pane");
  const setting = "terminal-close-confirmation", reset = "reset-terminal-close-confirmation";
  async function showPreference() {
    driver.openSettingsLink("tncode://settings/general#terminal-close-confirmation");
    await until(() => visible(setting), "terminal close confirmation in General");
  }
  await showPreference();
  assert(value(setting).includes("value=1"));
  press(setting);
  await until(() => value(setting).includes("value=0") && visible(reset), "confirmations switched off");
  dismiss("settings-close");
  await until(() => readPID(pane(1)) === other && !tree().includes('id="settings-close"'), "linked terminal after Settings");
  dismiss("close-right-panel-terminal-1");
  await until(() => !active(other) && !tree().includes('id="confirm-close-right-terminal"'), "linked PTY closed directly");
  assert(active(drawer));
  await quit();
  await until(() => !active(drawer), "normal quit closed the remaining drawer shell");
  await launch("toggle-terminal", root, shell);
  await showPreference();
  assert(value(setting).includes("value=0"));
  press(reset);
  await until(() => value(setting).includes("value=1") && !tree().includes('id="' + reset + '"'), "Reset restored confirmations");
  dismiss("settings-close");
  await quit();
  record("Three PTYs had distinct device names and the expected working directories. Hiding or switching tabs and threads retained their PIDs. Cancel kept the right shell, Confirm closed only that shell, and turning confirmations off closed the selected linked PTY directly. Quit stopped the remaining drawer shell. The Off setting survived relaunch, and Reset restored On.");
}
