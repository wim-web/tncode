import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { realpathSync } from "node:fs";
import { setTimeout as delay } from "node:timers/promises";

export async function closeTerminalPane({ press, visible, until }, confirm = true) {
  press("close-terminal");
  const choice = confirm ? "confirm-close-terminal" : "cancel-close-terminal";
  await until(() => visible(choice), "terminal close confirmation");
  try { press(choice); } catch (error) {
    if (!/AX error -2520[04]/.test(String(error.stderr))) throw error;
  }
}

export async function verifyInteractiveShell({ focus, keyFor, until, value }, checkout) {
  const id = "thread-terminal";
  focus(id);
  const screen = () => JSON.parse(value(id).trimEnd().match(/value=(".*")$/)[1]);
  const shell = await until(() => screen().match(/Fixture terminal PID (\d+)/)?.[1], "fixture shell PID");
  const keys = { a: 0, c: 8, d: 2, p: 35, t: 17, w: 13, y: 16 };
  function enter(command) {
    for (const letter of command) keyFor(id, keys[letter]);
    keyFor(id, 36);
  }
  enter("pwd");
  await until(() => {
    const result = screen().match(/[$#] pwd\n(.+?)\n[^\n]*[$#] /s)?.[1];
    return result && realpathSync(result.replaceAll("\n", "")) === realpathSync(checkout);
  }, "pwd in the interactive shell");
  enter("cat");
  const catPID = await until(() => Number(execFileSync("/usr/bin/pgrep", ["-P", shell, "-x", "cat"],
    { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] })), "foreground cat awaiting input");
  keyFor(id, keys.c, "ctrl");
  enter("tty");
  const tty = await until(() => screen().match(/\/dev\/ttys\d+/)?.[0], "tty command runs after Control-C interrupts cat");
  assert.throws(() => process.kill(catPID, 0), { code: "ESRCH" });
  return tty;
}

export async function verifyTerminalPanes(driver, originalPID) {
  const { press, until, visible, value, frame, keyFor } = driver;
  const active = () => Number(value("thread-terminal").match(/Fixture terminal PID (\d+)/)?.[1]);
  const focused = pid => active() === pid && visible("thread-terminal").includes("focused=true");
  const pids = [originalPID];
  const alive = pid => {
    try { process.kill(pid, 0); return true; }
    catch (error) { if (error.code === "ESRCH") return false; throw error; }
  };
  async function add(id) {
    press(id);
    const pid = await until(() => {
      const next = active();
      return next > 0 && !pids.includes(next) && focused(next) && next;
    }, "new PTY from " + id);
    pids.push(pid);
    return pid;
  }
  await until(() => focused(originalPID), "first terminal PID and focus");
  keyFor("thread-terminal", 40, "cmd");
  await delay(250);
  assert(focused(originalPID) && !driver.tree().includes('id="command-palette-search"'));
  driver.sizeWindow(1220, 810);
  const handle = "terminal-drawer-resize-handle";
  const drawerHeight = () => Number(value(handle).match(/value="?([\d.]+)/)?.[1]);
  await until(() => drawerHeight() === 280, "reference default for the terminal drawer");
  let layout, lastMove;
  await until(() => {
    const measured = [frame("workspace"), frame(handle), frame("thread-terminal")].flat().join();
    if (layout !== measured) { layout = measured; lastMove = Date.now(); }
    return Date.now() - lastMove >= 250;
  }, "window, divider and terminal have finished resizing");
  const limits = value(handle);
  assert(Number(limits.match(/max=([\d.]+)/)?.[1]) >= 360, "The test window needs room for the 360-point drawer: " + limits);
  const initialPane = frame("thread-terminal")[3];
  driver.drag(handle, 0.5, 0.5, 0, -80);
  await until(() => Math.abs(drawerHeight() - 360) <= 1 && Math.abs(frame("thread-terminal")[3] - initialPane - 80) <= 1 &&
                    focused(originalPID), "drag grows the existing focused shell by 80 points");
  driver.dismiss("hide-terminal");
  await until(() => !driver.tree().includes('id="thread-terminal"'), "hide the resized drawer");
  press("toggle-terminal");
  await until(() => Math.abs(drawerHeight() - 360) <= 1 && focused(originalPID), "reopened drawer keeps height and PID");
  driver.drag(handle, 0.5, 0.5, 0, 80);
  await until(() => Math.abs(drawerHeight() - 280) <= 1 && Math.abs(frame("thread-terminal")[3] - initialPane) <= 1,
              "drag restores original pane size");
  const second = await add("new-terminal");
  const third = await add("split-terminal-horizontal");
  const [left, row, width] = frame("terminal-pane-2");
  const [right, sameRow] = frame("thread-terminal");
  assert(Math.abs(row - sameRow) < 2 && right >= left + width - 1);
  const fourth = await add("split-terminal-vertical");
  const [column, top, , height] = frame("terminal-pane-2");
  const [sameColumn, middle] = frame("terminal-pane-3");
  const [, bottom] = frame("thread-terminal");
  assert(Math.abs(column - sameColumn) < 2 && middle >= top + height - 1 && bottom > middle);
  keyFor("thread-terminal", 33, "cmd", "shift");
  await until(() => focused(third), "previous pane shortcut");
  for (let i = 0; i < 3; i++) keyFor("thread-terminal", 3);
  await until(() => value("thread-terminal").includes("fff"), "typed marker in the selected shell");
  assert(!value("terminal-pane-2").includes("fff") && !value("terminal-pane-4").includes("fff"));
  keyFor("thread-terminal", 30, "cmd", "shift");
  await until(() => focused(fourth), "next pane shortcut");
  assert(!value("thread-terminal").includes("fff") && value("terminal-pane-3").includes("fff"));
  const fifth = await add("split-terminal-vertical");
  assert(visible("split-terminal-vertical").includes("enabled=false") &&
         visible("split-terminal-horizontal").includes("enabled=false"));
  await closeTerminalPane(driver);
  await until(() => !alive(fifth) && focused(fourth) && visible("split-terminal-vertical").includes("enabled=true"),
              "closing one pane under the four-pane limit re-enables splitting");
  pids.pop();
  press("terminal-tab-1");
  await until(() => focused(originalPID), "original tab with its original shell and output");
  press("terminal-tab-2");
  await until(() => focused(second), "second tab with its first pane");
  await closeTerminalPane(driver, false);
  await until(() => focused(second) && pids.every(alive), "Cancel keeps all terminal shells");
  for (const [pid, next] of [[second, third], [third, fourth], [fourth, originalPID], [originalPID, null]]) {
    await closeTerminalPane(driver);
    await until(() => !alive(pid) && (next ? focused(next) : !driver.tree().includes('id="thread-terminal"')),
                "only the confirmed pane exits");
    pids.splice(pids.indexOf(pid), 1);
    assert(pids.every(alive));
  }
}
