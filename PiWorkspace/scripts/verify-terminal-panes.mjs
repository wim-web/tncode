import assert from "node:assert/strict";
import { setTimeout as delay } from "node:timers/promises";

export async function closeTerminalPane({ press, visible, until }, confirm = true) {
  press("close-terminal");
  const choice = confirm ? "confirm-close-terminal" : "cancel-close-terminal";
  await until(() => visible(choice), "terminal close confirmation");
  try { press(choice); } catch (error) {
    if (!/AX error -2520[04]/.test(String(error.stderr))) throw error;
  }
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
