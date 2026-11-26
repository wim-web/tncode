import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

function readHistory(workspace, projectID, threadID) {
  const dir = join(workspace, "sessions", projectID, threadID);
  const files = readdirSync(dir).filter(name => name.endsWith(".jsonl"));
  assert.equal(files.length, 1);
  return readFileSync(join(dir, files[0]), "utf8");
}

const messages = file => file.trim().split("\n").map(line => JSON.parse(line)).filter(e => e.type === "message");

export async function verifyInterruptedReply(driver, workspace, projectID, threadID) {
  const id = await driver.until(() => messages(readHistory(workspace, projectID, threadID)).findLast(e =>
    e.message.role === "assistant" && e.message.stopReason === "aborted" &&
    e.message.content.some(p => p.text?.includes("Partial reply before Stop.")))?.id, "saved stopped response");
  await driver.until(() => driver.visible("transcript-message-" + id) &&
    driver.tree().includes("Pi skips this interrupted reply in future model requests."), "interrupted reply notice");
  assert(!driver.tree().includes('id="fork-from-response-' + id + '"'));
}

export async function verifyFork(driver, { workspace, projectID, threadID, index, targets, send }) {
  const { press, until, setField, visible, value } = driver;
  const project = () => index().projects.find(p => p.id === projectID);
  const thread = id => project().conversations.find(t => t.id === id);
  const history = id => readHistory(workspace, projectID, id);
  const parentFile = history(threadID);
  const entries = messages(parentFile);
  const replies = entries.filter(e => e.message.role === "assistant" && e.message.stopReason === "stop");
  assert(replies.length >= 3);
  const cutoff = replies[1].id;
  const prefix = entries.slice(0, entries.findIndex(e => e.id === cutoff) + 1);
  const prefixIDs = prefix.map(e => e.id);
  const draft = "Keep this draft in the parent";
  await setField("composer", draft);
  await until(() => thread(threadID).composerText === draft, "parent draft on disk");
  const initialCount = targets.length;
  const forkButton = "fork-from-response-" + cutoff;
  await until(() => visible(forkButton).includes("enabled=true"), "fork command on the second reply");
  press(forkButton);
  const childID = await until(() => project().selectedConversation !== threadID && project().selectedConversation,
                              "new selected conversation");
  await until(() => visible("open-source-conversation") && visible("send-message"), "child opened in Pi");
  assert.deepEqual(thread(childID).forkOrigin, { threadID, messageID: cutoff });
  assert.deepEqual(thread(childID).location, thread(threadID).location);
  assert.deepEqual(messages(history(childID)).map(e => e.id), prefixIDs);
  assert(value("composer").includes('value=""'));
  assert.equal(targets.length, initialCount);
  assert.deepEqual(thread(childID).queuedMessages ?? [], []);
  assert.equal(history(threadID), parentFile);

  const continuation = "Continue only inside this fork.";
  await send(continuation);
  await until(() => targets.length === initialCount + 1 && targets.at(-1).completed &&
                    messages(history(childID)).length === prefixIDs.length + 2 && visible("send-message"),
              "one completed child continuation");
  const spoken = m => m.role === "user" || m.role === "assistant";
  const turn = m => [m.role, typeof m.content === "string" ? m.content : m.content.map(p => p.text ?? "").join("")];
  const context = targets.at(-1).body.messages.filter(spoken).map(turn);
  assert.deepEqual(context, [...prefix.map(e => e.message).filter(spoken).map(turn), ["user", continuation]]);
  const continued = history(childID);
  press("open-source-conversation");
  const sourceReady = () => project().selectedConversation === threadID && value("composer").includes(draft) &&
                            visible("open-fork-" + childID).includes("enabled=true");
  await until(sourceReady, "parent draft and fork link restored after opening its history");
  assert.equal(history(threadID), parentFile);
  press("open-fork-" + childID);
  await until(() => project().selectedConversation === childID && driver.tree().includes(continuation) &&
                    visible("open-source-conversation").includes("enabled=true"), "linked child continuation");
  assert.equal(history(childID), continued);
  press("open-source-conversation");
  await until(sourceReady, "return to source");
  assert.equal(targets.length, initialCount + 1);
  return childID;
}
