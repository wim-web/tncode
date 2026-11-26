import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdirSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

export async function seedPaletteMessageHistory({ sidecar, workspace, projectID, threadID, cwd, keyword, laterKeyword, paddingTurns = 0, findOccurrences = false }) {
  const sdk = resolve(sidecar, "node_modules/@earendil-works/pi-coding-agent");
  assert.equal(JSON.parse(readFileSync(join(sdk, "package.json"), "utf8")).version, "1.6.1");
  const { SessionManager } = await import(pathToFileURL(join(sdk, "dist/index.js")).href);
  const directory = join(workspace, "sessions", projectID, threadID);
  mkdirSync(directory, { recursive: true });
  const session = SessionManager.create(cwd, directory, { id: threadID });
  const user = (text) => session.appendMessage({ role: "user", content: text, timestamp: Date.now() });
  const reply = (text) => session.appendMessage({
    role: "assistant",
    content: [{ type: "text", text }],
    api: "openai-completions",
    provider: "local",
    model: "palette-fixture",
    usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
    stopReason: "stop",
    timestamp: Date.now(),
  });

  const messageID = user(`An older message mentions ${keyword}.`);
  const firstReplyID = reply("First fixture reply.");
  for (let n = 0; n < paddingTurns; n++) {
    user(`Unrelated question ${n + 1}.`);
    reply(`Unrelated response ${n + 1}.`);
  }
  const captionID = findOccurrences ? session.appendMessage({
    role: "user", content: [{ type: "text", text: "Visible caption.\nburiedattachment" }],
    workspaceInput: { text: "Visible caption.", attachments: [
      { id: randomUUID(), name: "note.txt", mimeType: "text/plain" },
    ] }, timestamp: Date.now(),
  }) : user("What happened later?");
  const repeated = "**double**mark DOUBLEMARK 📍 İstanbul ΟΣ ος οσ don't don’t aaaa café cafe\u0301";
  if (findOccurrences) laterKeyword = [laterKeyword, repeated].filter(Boolean).join(" ");
  const latest = reply(laterKeyword ? `Latest active fixture reply mentions ${laterKeyword}.` : "Latest active fixture reply.");
  session.branch(firstReplyID);
  const abandonedID = user("palette-abandoned-branch-marker");
  reply("Abandoned reply.");
  session.branch(latest);
  session.appendSessionInfo("Active branch");
  const reopened = SessionManager.open(session.getSessionFile(), directory, cwd);
  assert(reopened.getBranch().some(({ id }) => id === messageID));
  assert(!reopened.getBranch().some(({ id }) => id === abandonedID));
  return { messageID, captionID, abandonedID, latestID: latest, historyPath: session.getSessionFile() };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const [sidecar, workspace, projectID, threadID, cwd, keyword, laterKeyword, option] = process.argv.slice(2);
  console.log(JSON.stringify(await seedPaletteMessageHistory({ sidecar, workspace, projectID, threadID, cwd, keyword, laterKeyword,
    findOccurrences: option === "--find-occurrences" })));
}
