import { existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { createInterface } from "node:readline";
import { editingTools, installToolApproval, readTools } from "./tool-approval.mjs";
const write = process.stdout.write.bind(process.stdout);
process.stdout.write = process.stderr.write.bind(process.stderr);

const {
  createAgentSession,
  createExtensionRuntime,
  ModelRuntime,
  parseSessionEntries,
  SessionManager,
  SettingsManager,
} = await import("@earendil-works/pi-coding-agent");

const input = createInterface({ input: process.stdin, crlfDelay: Infinity });
const emit = (event) => { if (connected) write(JSON.stringify(event) + "\n"); };
const pendingCredentials = new Map();
const redacted = "[API key removed]";
let nextRequest = 0;
let credential;
let session;
let manager;
let initializing = false;
let connected = true;
let active;
let approvals;
const steeredMessages = new WeakMap();
const validID = (id) => typeof id === "string" && /^[a-f0-9-]{36}$/i.test(id);

function requestCredential(operation) {
  if (!connected) return Promise.reject(new Error("Host disconnected"));
  const requestID = String(++nextRequest);
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      pendingCredentials.delete(requestID);
      reject(new Error("Keychain request timed out"));
    }, 15_000);
    pendingCredentials.set(requestID, { resolve, reject, timeout });
    emit({ type: "credential", requestID, operation });
  });
}

function redact(text) {
  return credential && typeof text === "string" ? text.replaceAll(credential, redacted) : text;
}

function redactValue(value) {
  if (typeof value === "string") return redact(value);
  if (Array.isArray(value)) return value.map(redactValue);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [redact(key), redactValue(item)]));
  }
  return value;
}

function guardModelStream(runtime) {
  const stream = runtime.streamSimple.bind(runtime);
  runtime.streamSimple = (...args) => {
    const incoming = stream(...args);
    return {
      async *[Symbol.asyncIterator]() {
        for await (const event of incoming) {
          yield event.type === "done" || event.type === "error" ? redactValue(event) : event;
        }
      },
      async result() {
        return redactValue(await incoming.result());
      },
    };
  };
}

function messageText(message) {
  if (typeof message.content === "string") return message.content;
  return message.content?.filter((block) => block.type === "text").map((block) => block.text).join("") ?? "";
}

function isForkableReply(entry) {
  return entry?.type === "message" && entry.message.role === "assistant" &&
    ["stop", "length", "error", "aborted"].includes(entry.message.stopReason) &&
    Boolean(messageText(entry.message));
}

function history() {
  return manager.getBranch().flatMap((entry) => {
    if (entry.type !== "message") return [];
    const { role } = entry.message;
    if (role !== "user" && role !== "assistant") return [];
    const text = redact(messageText(entry.message));
    return text ? [{
      id: entry.id, role, text, queuedID: entry.message.workspaceQueuedID, canFork: isForkableReply(entry),
    }] : [];
  });
}

function forkConversation({ threadID, messageID }) {
  if (!validID(threadID) || typeof messageID !== "string") return;
  const finish = (error) => emit({ type: "forked", threadID, error });
  if (!session || active) return finish("Wait for the current turn to finish before forking.");
  if (threadID === manager.getSessionId()) return finish("Choose a new conversation for the fork.");
  const branch = manager.getBranch();
  const cutoff = branch.findIndex((entry) => entry.id === messageID);
  if (!isForkableReply(branch[cutoff])) return finish("This response is no longer available on the active conversation branch.");

  const sourceFile = manager.getSessionFile();
  let prefix;
  try {
    const [header, ...saved] = parseSessionEntries(readFileSync(sourceFile, "utf8"));
    if (header?.type !== "session" || header.id !== manager.getSessionId()) throw new Error();
    const byID = new Map(saved.map((entry) => [entry.id, entry]));
    prefix = branch.slice(0, cutoff + 1).map(({ id, parentId }, index, path) => {
      const entry = byID.get(id);
      if (!entry || entry.parentId !== parentId || parentId !== (path[index - 1]?.id ?? null)) throw new Error();
      if (entry.type !== "message") return entry;
      const { workspaceQueuedID, ...message } = entry.message;
      return { ...entry, message };
    });
    if (!isForkableReply(prefix.at(-1))) throw new Error();
  } catch {
    return finish("The source history is missing or incomplete. Reconnect before trying again.");
  }

  try {
    // Pi's createBranchedSession switches the manager and assigns its own session ID.
    const header = SessionManager.inMemory(manager.getCwd(), { id: threadID, parentSession: sourceFile }).getHeader();
    const destination = join(dirname(manager.getSessionDir()), threadID, threadID + ".jsonl");
    const contents = [header, ...prefix].map((entry) => JSON.stringify(entry) + "\n").join("");
    writeFileSync(destination, contents, { flag: "wx", mode: 0o600, flush: true });
    finish();
  } catch {
    finish("Could not save the fork history. Try again.");
  }
}

function localModel(runtime, config) {
  const url = new URL(config.endpoint);
  if (!["http:", "https:"].includes(url.protocol) ||
      !["127.0.0.1", "localhost", "[::1]"].includes(url.hostname) ||
      url.username || url.password || url.search || url.hash) {
    throw new Error("Enter a loopback URL such as http://127.0.0.1:11434/v1.");
  }
  runtime.registerProvider("local", {
    api: "openai-completions",
    baseUrl: url.href.replace(/\/$/, ""),
    models: [{
      id: config.model,
      name: config.model,
      input: ["text"],
      reasoning: false,
      contextWindow: config.contextWindow,
      maxTokens: Math.min(2048, config.contextWindow - 4096),
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      compat: { maxTokensField: "max_tokens", supportsStore: false },
    }],
  });
}

async function open(command) {
  const { cwd, sessionDir, threadID, config, toolPermission, forkMessageID } = command;
  if (!/^[a-f0-9-]{36}$/i.test(threadID) ||
      !["local", "openai", "anthropic"].includes(config.provider) ||
      typeof config.model !== "string" || !config.model.trim() ||
      !Number.isInteger(config.contextWindow) || config.contextWindow < 8192) {
    throw new Error("Choose a provider and enter a model ID in Settings.");
  }
  const credentials = {
    async read(provider) {
      if (provider !== config.provider) return undefined;
      const key = await requestCredential("read");
      if (!key) return undefined;
      credential = key;
      return { type: "api_key", key };
    },
    async list() {
      return await requestCredential("exists") ? [{ providerId: config.provider, type: "api_key" }] : [];
    },
    async modify() { throw new Error("Credential updates belong to the macOS app"); },
    async delete() { throw new Error("Credential removal belongs to the macOS app"); },
  };
  const runtime = await ModelRuntime.create({
    credentials,
    modelsPath: null,
    allowModelNetwork: false,
    refreshOnCreate: false,
  });
  if (config.provider === "local") localModel(runtime, config);
  guardModelStream(runtime);
  const model = runtime.getModel(config.provider, config.model);
  if (!model) throw new Error("This model is unavailable for the selected provider in the bundled Pi catalog.");

  if (forkMessageID) {
    if (!existsSync(sessionDir)) throw new Error("The fork history is missing.");
  } else {
    mkdirSync(sessionDir, { recursive: true, mode: 0o700 });
  }
  const files = readdirSync(sessionDir).filter((name) => name.endsWith(".jsonl"));
  if (files.length > 1) throw new Error("This conversation has more than one history file.");
  const historyFile = files[0] && join(sessionDir, files[0]);
  if (forkMessageID && (!historyFile || statSync(historyFile).size === 0)) {
    throw new Error("The fork history is missing.");
  }
  manager = historyFile
    ? SessionManager.open(historyFile, sessionDir, cwd)
    : SessionManager.create(cwd, sessionDir, { id: threadID });
  if (manager.getSessionId() !== threadID) throw new Error("Conversation history does not match its ID.");
  if (forkMessageID && !manager.getBranch().some((entry) => entry.id === forkMessageID && isForkableReply(entry))) {
    throw new Error("The fork history is incomplete.");
  }
  const appendMessage = manager.appendMessage.bind(manager);
  manager.appendMessage = (message) => {
    const safeMessage = redactValue(message);
    if (message.role === "user") {
      // Store the queue ID with the transcript entry so reopening can acknowledge it.
      const queuedID = steeredMessages.get(message);
      if (queuedID) {
        safeMessage.workspaceQueuedID = queuedID;
      } else if (active?.promptID) {
        safeMessage.workspaceQueuedID = active.promptID;
        active.promptID = undefined;
      }
    }
    return appendMessage(safeMessage);
  };

  const result = await createAgentSession({
    cwd,
    agentDir: process.env.PI_CODING_AGENT_DIR,
    model,
    thinkingLevel: config.thinkingLevel ?? "off",
    modelRuntime: runtime,
    tools: config.provider === "local" && !config.localTools
      ? []
      : toolPermission === "supervised" || toolPermission === "shellAndEdits" ? editingTools : readTools,
    excludeTools: ["mcp__*"],
    settingsManager: SettingsManager.inMemory({
      retry: { enabled: false, provider: { maxRetries: 0 } },
      cacheWarming: "off",
    }),
    sessionManager: manager,
    resourceLoader: {
      getExtensions: () => ({ extensions: [], errors: [], runtime: createExtensionRuntime() }),
      getSkills: () => ({ skills: [], diagnostics: [] }),
      getPrompts: () => ({ prompts: [], diagnostics: [] }),
      getThemes: () => ({ themes: [], diagnostics: [] }),
      getAgentsFiles: () => ({ agentsFiles: [] }),
      getSystemPrompt: () => "You are a coding assistant. Follow the user's instructions and be concise.",
      getSystemPromptSource: () => undefined,
      getAppendSystemPrompt: () => [],
      getAppendSystemPromptSources: () => [],
      extendResources: () => {},
      reload: async () => {},
    },
  });
  if (!connected) {
    result.session.dispose();
    return;
  }
  session = result.session;
  if (toolPermission === "supervised") {
    approvals = installToolApproval(session.agent, {
      threadID,
      currentTurn: () => active?.cancelled ? undefined : active?.id,
      requestApproval: (request, args) => emit({
        type: "toolApproval",
        ...request,
        details: JSON.stringify(redactValue(args), null, 2),
      }),
    });
  }
  session.subscribe((event) => {
    if (active) {
      if (event.type === "agent_start") {
        active.started = true;
        if (active.cancelled) void session.abort().catch(() => {});
        else setInputMode("steer");
      }
      if (event.type === "agent_end" || event.type === "compaction_end") setInputMode("waiting");
      if (event.type === "compaction_start" && active.started && !active.cancelled) setInputMode("compacting");
    }
    if (event.type === "message_update" && event.assistantMessageEvent.type === "text_delta") {
      emit({ type: "partial", text: redact(messageText(event.message)) });
    }
    if (event.type === "message_end") setImmediate(() => emit({ type: "history", messages: history() }));
    if (event.type === "tool_execution_start") emit({ type: "activity", text: event.toolName });
  });
  emit({ type: "ready", messages: history() });
}

async function prompt({ turnID, text, queuedID, skipCompaction }) {
  if (!session || active || !validID(turnID) || (queuedID !== undefined && !validID(queuedID)) ||
      typeof text !== "string" || !text.trim()) return;
  const run = { id: turnID, promptID: queuedID, mode: "waiting", cancelled: false, started: false };
  active = run;
  let error;
  const restoreCompaction = skipCompaction === true && session.autoCompactionEnabled;
  try {
    credential = await requestCredential("read");
    if (run.cancelled) {
      return;
    } else if (!credential) {
      error = "Save an API key for this provider in Settings.";
    } else {
      if (restoreCompaction) session.setAutoCompactionEnabled(false);
      await session.prompt(redact(text), {
        expandPromptTemplates: false,
        preflightResult: () => {
          if (restoreCompaction) session.setAutoCompactionEnabled(true);
        },
      });
      const assistant = session.messages.findLast((message) => message.role === "assistant");
      if (assistant?.stopReason === "error") {
        error = redact(assistant.errorMessage) || "The model request failed.";
      }
    }
  } catch {
    error = "Pi could not complete the request. Check the provider, model, and Keychain access.";
  } finally {
    if (restoreCompaction) session.setAutoCompactionEnabled(true);
    session.clearQueue();
    active = undefined;
    approvals?.cancel();
    emit({ type: "finished", turnID, messages: history(), error });
    credential = undefined;
  }
}

function setInputMode(mode) {
  if (active.mode === mode) return;
  active.mode = mode;
  emit({ type: "inputMode", turnID: active.id, mode });
}

function handleQueuedInput({ type, turnID, queuedID, text }) {
  if (!validID(turnID) || !validID(queuedID)) return;
  const reject = () => emit({ type: "queueRejected", turnID, queuedID });
  if (active?.id !== turnID || active.cancelled) return reject();
  if (type === "skipCompaction") {
    if (active.mode !== "compacting" || !session.isCompacting) return reject();
    session.abortCompaction();
    setInputMode("waiting");
    emit({ type: "compactionSkipped", turnID, queuedID });
    return;
  }
  if (active.mode !== "steer" || !session.agent.state.isStreaming ||
      typeof text !== "string" || !text.trim()) return reject();
  const message = { role: "user", content: [{ type: "text", text: redact(text) }], timestamp: Date.now() };
  steeredMessages.set(message, queuedID);
  session.agent.steer(message);
}

function cancelActive() {
  if (active) active.cancelled = true;
  session?.clearQueue();
  approvals?.cancel();
}

input.on("line", (line) => {
  if (!connected) return;
  let command;
  try { command = JSON.parse(line); } catch { return; }
  if (!command || typeof command !== "object") return;
  if (command.type === "credentialResult") {
    const pending = pendingCredentials.get(command.requestID);
    if (pending) {
      clearTimeout(pending.timeout);
      pendingCredentials.delete(command.requestID);
      if (command.error) pending.reject(new Error("Keychain is unavailable"));
      else pending.resolve(command.key ?? command.exists);
    }
  } else if (command.type === "open" && !initializing) {
    initializing = true;
    void open(command).catch((error) => {
      emit({ type: "fatal", error: redact(error.message) });
      process.exitCode = 1;
      input.close();
    });
  } else if (command.type === "prompt") {
    void prompt(command);
  } else if (command.type === "fork") {
    forkConversation(command);
  } else if (command.type === "steer" || command.type === "skipCompaction") {
    handleQueuedInput(command);
  } else if (command.type === "toolApprovalResult") {
    approvals?.respond(command);
  } else if (command.type === "cancel" && active && active.id === command.turnID) {
    cancelActive();
    void session?.abort().catch(() => {});
  }
});
input.on("error", () => input.close());
process.stdout.on("error", () => input.close());
input.on("close", () => {
  connected = false;
  cancelActive();
  for (const pending of pendingCredentials.values()) {
    clearTimeout(pending.timeout);
    pending.reject(new Error("Host disconnected"));
  }
  pendingCredentials.clear();
  if (session) void session.abort().catch(() => {}).finally(() => session.dispose());
});
