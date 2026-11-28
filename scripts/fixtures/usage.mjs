import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { appendFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const hour = 60 * 60 * 1000;
const day = 24 * hour;
const uuid = () => randomUUID().toUpperCase();
const localModel = {
  id: "usage-local",
  name: "Usage Fixture Local",
  api: "openai-completions",
  provider: "local",
  baseUrl: "http://127.0.0.1:11434/v1",
  input: ["text"],
  reasoning: false,
  contextWindow: 8192,
  maxTokens: 2048,
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
};

export async function createUsageFixture(root, sidecar = join(import.meta.dirname, "../../Sidecar")) {
  const sdk = join(sidecar, "node_modules/@earendil-works");
  assert.equal(JSON.parse(readFileSync(join(sdk, "pi-coding-agent/package.json"), "utf8")).version, "1.6.1");
  const { SessionManager } = await import(join(sdk, "pi-coding-agent/dist/index.js"));
  const { stream } = await import(join(sdk, "pi-ai/dist/api/openai-completions.js"));
  const now = Date.now();
  const alpha = { id: uuid(), title: "Usage Alpha", path: join(root, "alpha"), allowEdits: false, conversations: [] };
  const beta = { id: uuid(), title: "Usage Beta", path: join(root, "beta"), allowEdits: false, conversations: [] };
  const workspace = {
    projects: [alpha, beta],
    selectedProject: beta.id,
    model: { provider: "openai", model: "gpt-5-mini", endpoint: "http://127.0.0.1:11434/v1", contextWindow: 8192 },
    welcomeCompleted: true,
  };
  beta.modelOverride = { ...workspace.model, provider: "local", model: localModel.id };

  function addThread(project, title) {
    const id = uuid();
    project.conversations.push({ id, title, archived: false });
    return { id, dir: join(root, "sessions", project.id, id) };
  }

  function newSession(project, title) {
    const { id, dir } = addThread(project, title);
    return SessionManager.create(project.path, dir, { id });
  }

  function user(manager, timestamp) {
    manager.appendMessage({ role: "user", content: [{ type: "text", text: "Usage fixture prompt" }], timestamp });
  }

  function hostedReply(manager, { timestamp, provider = "openai", tokens, cost, reported, stopReason = "stop" }) {
    const [input, output, cacheRead = 0, cacheWrite = 0] = tokens;
    return manager.appendMessage({
      role: "assistant",
      provider,
      model: "usage-shared-model",
      api: provider === "anthropic" ? "anthropic-messages" : "openai-responses",
      content: [{ type: "text", text: "Usage fixture reply" }],
      timestamp,
      stopReason,
      usage: {
        input, output, cacheRead, cacheWrite, totalTokens: input + output + cacheRead + cacheWrite,
        cost: { input: cost, output: 0, cacheRead: 0, cacheWrite: 0, total: cost, totalFromProvider: reported },
      },
    });
  }

  async function localReply(manager, timestamp, counts) {
    const completion = (choices, usage) => JSON.stringify({
      id: "usage-fixture",
      object: "chat.completion.chunk",
      created: 1,
      model: localModel.id,
      choices,
      usage,
    });
    const chunks = [
      completion([{ index: 0, delta: { role: "assistant", content: "Local accounting fixture" }, finish_reason: null }]),
      completion([{ index: 0, delta: {}, finish_reason: "stop" }]),
    ];
    if (counts) {
      chunks.push(completion([], {
        prompt_tokens: counts[0], completion_tokens: counts[1], total_tokens: counts[0] + counts[1],
        prompt_tokens_details: { cached_tokens: counts[2] },
      }));
    }
    const body = chunks.map(chunk => "data: " + chunk + "\n\n").join("") + "data: [DONE]\n\n";
    const response = await stream(localModel, {
      messages: [{ role: "user", content: "Usage fixture prompt", timestamp }],
    }, {
      apiKey: "fixture-key",
      fetch: async () => new Response(body, { headers: { "Content-Type": "text/event-stream" } }),
    }).result();
    assert.equal(response.stopReason, "stop", response.errorMessage);
    assert.equal(response.usage.totalTokens, counts ? counts[0] + counts[1] : 0);
    manager.appendMessage({ ...response, timestamp });
  }

  mkdirSync(alpha.path, { recursive: true });
  mkdirSync(beta.path, { recursive: true });
  const parent = newSession(alpha, "Usage parent");
  user(parent, now - 2 * hour);
  const shared = hostedReply(parent, { timestamp: now - 2 * hour, tokens: [60, 20, 15, 5], cost: 0.00125 });
  const parentFile = parent.getSessionFile();
  const forkRef = addThread(alpha, "Usage fork");
  alpha.conversations.at(-1).forkOrigin = { threadID: parent.getSessionId(), messageID: shared };
  mkdirSync(forkRef.dir, { recursive: true });
  const forkFile = join(forkRef.dir, forkRef.id + ".jsonl");
  const forkHeader = SessionManager.inMemory(alpha.path, { id: forkRef.id, parentSession: parentFile }).getHeader();
  writeFileSync(forkFile, [forkHeader, ...parent.getBranch(shared)].map(entry => JSON.stringify(entry) + "\n").join(""));
  const fork = SessionManager.open(forkFile, forkRef.dir);
  user(fork, now - 4 * hour);
  hostedReply(fork, { timestamp: now - 4 * hour, tokens: [30, 30], cost: 0.00195 });

  user(parent, now - 2 * day);
  hostedReply(parent, { timestamp: now - 2 * day, tokens: [35, 5], cost: 0.0005 });
  parent.branch(shared);
  user(parent, now - 15 * day);
  hostedReply(parent, {
    timestamp: now - 15 * day, provider: "anthropic", tokens: [80, 30, 10, 10], cost: 0.0045, reported: true,
  });
  user(parent, now - 45 * day);
  hostedReply(parent, { timestamp: now - 45 * day, tokens: [200, 40], cost: 0.0024 });
  user(parent, now - 105 * day);
  hostedReply(parent, { timestamp: now - 105 * day, tokens: [600, 200], cost: 0.008 });
  const replayed = parent.getEntries().find(entry => entry.id === shared);
  appendFileSync(parentFile, JSON.stringify(replayed) + "\n");

  const betaSession = newSession(beta, "Usage beta");
  user(betaSession, now - 3 * hour);
  await localReply(betaSession, now - 3 * hour, [100, 40, 35]);
  user(betaSession, now - hour);
  hostedReply(betaSession, {
    timestamp: now - hour, provider: "anthropic", tokens: [8, 2], cost: 0, reported: true, stopReason: "aborted",
  });
  user(betaSession, now - hour);
  await localReply(betaSession, now - hour);
  betaSession.appendMessage({
    role: "assistant", provider: "local", model: localModel.id, api: localModel.api,
    content: [{ type: "text", text: "Legacy reply without usage" }], stopReason: "stop", timestamp: now - hour,
  });

  const draft = addThread(beta, "Usage draft");
  Object.assign(beta.conversations.at(-1), { isDraft: true, composerText: "Preserve this usage fixture draft." });
  beta.selectedConversation = draft.id;
  const workspaceFile = join(root, "workspace.json");
  writeFileSync(workspaceFile, JSON.stringify(workspace));

  return {
    alpha: alpha.id, beta: beta.id, now: new Date(now).toISOString(), workspaceFile,
    betaFile: betaSession.getSessionFile(), forkFile,
    appendUsage: () => localReply(betaSession, Date.now(), [10, 13, 0]),
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const [root, sidecar] = process.argv.slice(2);
  assert(root, "Pass a disposable workspace path.");
  const fixture = await createUsageFixture(resolve(root), sidecar && resolve(sidecar));
  console.log(JSON.stringify(fixture));
}
