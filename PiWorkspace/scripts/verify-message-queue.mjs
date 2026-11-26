import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

export async function verifyQueue(driver, { workspace, projectID, threadID, gate, requestCount, send, quit, launch }) {
  const { press, visible, until, setField, value, keyFor } = driver;
  const stored = () => {
    const project = JSON.parse(readFileSync(join(workspace, "workspace.json"), "utf8")).projects.find(p => p.id === projectID);
    return project.conversations.find(t => t.id === threadID).queuedMessages ?? [];
  };
  const recorded = () => {
    const dir = join(workspace, "sessions", projectID, threadID);
    const [name] = readdirSync(dir).filter(name => name.endsWith(".jsonl"));
    return readFileSync(join(dir, name), "utf8").trim().split("\n").map(line => JSON.parse(line).message)
      .filter(message => message?.role === "user" && message.workspaceQueuedID)
      .map(message => ({ id: message.workspaceQueuedID.toLowerCase(),
                         text: message.content.map(part => part.text ?? "").join("") }));
  };
  const rows = () => Array.from(driver.tree().matchAll(/id="queued-message-([\dA-F-]+)"/gi), match => match[1]);
  const hasCount = n => value("queue-count").includes(JSON.stringify(n + (n === 1 ? " queued message" : " queued messages")));
  const hasDraft = text => value("composer").includes("value=" + JSON.stringify(text));
  async function held(prompt) {
    const release = gate();
    await send(prompt);
    await until(() => visible("steer-message") && visible("composer").includes("enabled=true") &&
                      driver.tree().includes("Queue fixture is waiting."), "running Pi turn with a recorded user entry");
    return release;
  }
  async function enqueue(text, shortcut = false) {
    await setField("composer", text);
    if (shortcut) keyFor("composer", 36, "cmd");
    else press("queue-message");
    return until(() => stored().find(item => item.text === text)?.id, "queue item " + text);
  }
  async function action(name, id) {
    const actionID = "queue-" + name + "-" + id;
    for (let attempt = 0; attempt < 3; attempt++) {
      press("queue-item-actions-" + id);
      try {
        await until(() => visible(actionID), "queue action " + name, 1800);
        break;
      } catch (error) { if (attempt === 2) throw error; }
    }
    press(actionID);
  }
  function receipt(id, text) { return { id: id.toLowerCase(), text }; }

  const release = await held("Hold the queue editing turn.");
  const activeRequests = requestCount();
  const first = await enqueue("First queued instruction", true);
  const second = await enqueue("Second queued instruction");
  const remove = await enqueue("Remove this instruction");
  const front = await enqueue("Move this instruction first");
  const steerRow = await enqueue("Promote this row into the turn");
  await until(() => hasCount(5) && rows().length === 2, "collapsed queue shows two of five items");
  press("toggle-queued-messages");
  await until(() => hasCount(5) && rows().length === 5, "expanded queue shows all five");
  await setField("composer", "Separate unfinished message");
  await action("edit", second);
  await setField("composer", "Cancelled queue edit");
  press("queue-cancel-edit");
  await until(() => hasDraft("Separate unfinished message") && stored().find(item => item.id === second)?.text === "Second queued instruction",
              "cancelled edit restores both original texts");
  await action("edit", second);
  await setField("composer", "Updated queued instruction");
  press("queue-update");
  await until(() => hasDraft("Separate unfinished message") && stored().find(item => item.id === second)?.text === "Updated queued instruction",
              "update reuses the queue item ID");
  await action("remove", remove);
  await until(() => hasCount(4) && !stored().some(item => item.id === remove), "removed queue row");
  await action("move-first", front);
  assert.deepEqual(stored().map(item => item.id), [front, first, second, steerRow]);
  await setField("composer", "Direct steer instruction");
  press("steer-message");
  const direct = await until(() => stored().find(item => item.text === "Direct steer instruction")?.id, "steering receipt ID");
  press("queue-send-now-" + steerRow);
  await until(() => hasCount(3) && visible("stop-message"), "promoted rows leave the waiting list during this turn");
  await setField("composer", "Keep my independent draft");
  assert.equal(requestCount(), activeRequests);
  release();
  await until(() => stored().length === 0 && visible("send-message") && recorded().length >= 5, "ordered queue fully delivered");
  const receipts = recorded();
  assert.deepEqual(receipts, [
    receipt(direct, "Direct steer instruction"), receipt(steerRow, "Promote this row into the turn"),
    receipt(front, "Move this instruction first"), receipt(first, "First queued instruction"), receipt(second, "Updated queued instruction")
  ]);
  assert(hasDraft("Keep my independent draft"));

  await held("Hold the turn that will be stopped.");
  const waiting = await enqueue("Resume this message after restart");
  const picked = await enqueue("Start this queued message now");
  press("stop-message");
  await until(() => visible("resume-queue") && hasCount(2), "Stop pauses both messages");
  const beforeRestart = requestCount();
  await quit();
  await launch();
  await until(() => visible("resume-queue") && hasCount(2), "restored paused queue");
  assert.equal(requestCount(), beforeRestart);
  const added = await enqueue("Added while paused");
  gate();
  press("queue-send-now-" + picked);
  await until(() => driver.tree().includes("Queue fixture is waiting.") && hasCount(2), "chosen paused item starts a fresh turn");
  press("stop-message");
  await until(() => visible("resume-queue") && stored().every(item => item.id !== picked), "recorded item acknowledged on Stop");
  press("resume-queue");
  await until(() => stored().length === 0 && visible("send-message") && recorded().length === 8, "resume delivers each remaining item once");
  assert.deepEqual(recorded().slice(5), [
    receipt(picked, "Start this queued message now"), receipt(waiting, "Resume this message after restart"), receipt(added, "Added while paused")
  ]);
}
