import assert from "node:assert/strict";
import { mkdirSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

export async function seedPaletteMessageHistory({ sidecar, workspace, projectID, threadID, cwd, keyword }) {
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
  user("What happened later?");
  const latest = reply("Latest active fixture reply.");
  session.branch(firstReplyID);
  const abandonedID = user("palette-abandoned-branch-marker");
  reply("Abandoned reply.");
  session.branch(latest);
  session.appendSessionInfo("Active branch");
  const reopened = SessionManager.open(session.getSessionFile(), directory, cwd);
  assert(reopened.getBranch().some(({ id }) => id === messageID));
  assert(!reopened.getBranch().some(({ id }) => id === abandonedID));
  return { messageID, abandonedID };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const [sidecar, workspace, projectID, threadID, cwd, keyword] = process.argv.slice(2);
  console.log(JSON.stringify(await seedPaletteMessageHistory({ sidecar, workspace, projectID, threadID, cwd, keyword })));
}
