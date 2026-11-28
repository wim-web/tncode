import { createHash, randomUUID } from "node:crypto";
import { linkSync, lstatSync, mkdirSync, readFileSync, readdirSync, realpathSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";
import { createInterface } from "node:readline";
import { setTimeout as delay } from "node:timers/promises";
import { fileURLToPath } from "node:url";
import { CodexRPC } from "./codex-rpc.mjs";

const provider = "codex-app-server";
const metadataName = "codex-thread.json";
const ownerPrefix = "codex-owner-";
const ownerBusy = "The Codex conversation is already open in another helper.";
const uuid = (id) => typeof id === "string" && /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(id);
const object = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
const hash = (value) => createHash("sha256").update(JSON.stringify(value)).digest("hex");
const inputText = (content) => content.filter(({ type }) => type === "text").map(({ text }) => text).join("");
const sameChoice = (actual, expected) => typeof expected === "string" ? actual === expected :
  Object.entries(expected.granular).every(([key, value]) => actual?.granular?.[key] === value);
const declined = { decision: "decline" };
const noPermissions = { permissions: {}, scope: "turn" };
const noElicitation = { action: "decline" };

function realLocation(path) {
  try { return realpathSync(path); }
  catch (error) {
    if (error.code !== "ENOENT" || dirname(path) === path) throw error;
    if (lstatSync(path, { throwIfNoEntry: false })?.isSymbolicLink()) throw error;
    return join(realLocation(dirname(path)), relative(dirname(path), path));
  }
}

function acquireOwner(directory) {
  const path = join(directory, ownerPrefix + process.pid + "-" + randomUUID());
  writeFileSync(path, "", { flag: "wx", mode: 0o600 });
  const release = () => rmSync(path, { force: true });
  try {
    for (const name of readdirSync(directory)) {
      const owner = /^codex-owner-(\d+)-[a-f0-9-]+$/.exec(name);
      if (!owner || join(directory, name) === path) continue;
      try { process.kill(Number(owner[1]), 0); }
      catch (error) {
        if (error.code === "ESRCH") {
          rmSync(join(directory, name), { force: true });
          continue;
        }
        if (error.code !== "EPERM") throw error;
      }
      throw new Error(ownerBusy);
    }
  } catch (error) {
    release();
    throw error;
  }
  return release;
}

function readMapping(path) {
  try {
    if (!lstatSync(path).isFile()) throw new Error("The Codex conversation mapping must be a regular file.");
  } catch (error) {
    if (error.code === "ENOENT") return undefined;
    throw error;
  }
  return JSON.parse(readFileSync(path, "utf8"));
}

function writeMapping(path, mapping, create) {
  const temporary = path + "." + randomUUID();
  try {
    writeFileSync(temporary, JSON.stringify(mapping), { flag: "wx", mode: 0o600, flush: true });
    if (create) linkSync(temporary, path);
    else renameSync(temporary, path);
  } finally {
    rmSync(temporary, { force: true });
  }
}

function prepareInput(command) {
  const { text, attachments = [], sideChatContext, skipCompaction } = command;
  if (skipCompaction) throw new Error("Codex does not support skipping compaction.");
  if (sideChatContext != null) throw new Error("This Codex route cannot carry inherited side-chat context.");
  if (typeof text !== "string" || !Array.isArray(attachments) || attachments.length > 10 ||
      (!text.trim() && attachments.length === 0)) {
    throw new Error("Enter a message or attach up to 10 UTF-8 text files.");
  }
  const files = {};
  const parts = [text];
  const previews = [];
  for (const attachment of attachments) {
    const { id, name, payload } = attachment ?? {};
    if (payload?.mimeType !== "text/plain") throw new Error("This Codex route accepts text attachments only.");
    const { data } = payload;
    if (!uuid(id) || files[id] || typeof name !== "string" || !name ||
        typeof data !== "string" || data.length > 4 * Math.ceil(65_536 / 3)) {
      throw new Error("Attach the unavailable files again or remove them to send.");
    }
    const bytes = Buffer.from(data, "base64");
    if (!bytes.length || bytes.length > 65_536 || bytes.includes(0) || bytes.toString("base64") !== data) {
      throw new Error("Choose a UTF-8 text file of 64 KB or smaller.");
    }
    let content;
    try { content = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(bytes); }
    catch { throw new Error("Choose a UTF-8 text file."); }
    parts.push(`Attached text file ${JSON.stringify(name)}:\n${content}`);
    files[id] = { mimeType: "text/plain", data };
    previews.push({ id, name, mimeType: "text/plain", hasText: true });
  }
  const prompt = parts.filter(Boolean).join("\n\n");
  return {
    input: [{ type: "text", text: prompt, text_elements: [] }],
    inputDigest: hash(prompt),
    files,
    attachments: previews.length ? previews : undefined,
  };
}

function toolsPolicy(mode) {
  if (mode === "readFiles") return { sandbox: "read-only", approvalPolicy: "never" };
  if (mode === "supervised") return { sandbox: "read-only", approvalPolicy: "untrusted" };
  if (mode === "shellAndEdits") {
    return {
      sandbox: "workspace-write",
      approvalPolicy: { granular: {
        sandbox_approval: true, rules: true, mcp_elicitations: true, request_permissions: true, skill_approval: true,
      } },
    };
  }
  throw new Error("This conversation has an invalid tool permission.");
}

function toolActivity(item) {
  switch (item.type) {
    case "webSearch": {
      const query = item.query || item.action?.query || item.action?.queries?.join(", ") || item.action?.url;
      return query ? `Web search: ${query}` : "Web search";
    }
    case "mcpToolCall": return `MCP ${item.server}/${item.tool}`;
    case "dynamicToolCall": return [item.namespace, item.tool].filter(Boolean).join("/");
    case "commandExecution": return "Shell command";
    case "fileChange": return "File changes";
  }
}

function computerControlTool(server, tool) {
  const name = tool.toLowerCase().replaceAll("-", "_");
  const namespace = server.toLowerCase().replaceAll("-", "_");
  if (/^(?:computer_use|computer|desktop|sky|cua)(?:_use)?_(?:click|drag|move|key|press_key|scroll|type|type_text|perform_action)$/.test(name)) {
    return true;
  }
  const controlServer = /(?:^|[_.:/])(?:computer_use|unified_computer_use|cua_repl)(?:$|[_.:/])/.test(namespace);
  return controlServer && /^(?:js|click|drag|move|key|press_key|scroll|type|type_text|perform_action|computer|computer_use)$/.test(name);
}

function exactPermissions(permissions, cwd) {
  if (!object(permissions) || Object.keys(permissions).some(key => !["fileSystem", "network"].includes(key))) return false;
  if (permissions.network != null && (!object(permissions.network) ||
      Object.keys(permissions.network).some(key => key !== "enabled") || permissions.network.enabled !== false)) return false;
  const files = permissions.fileSystem;
  if (!object(files) || Object.keys(files).some(key => !["read", "write", "entries"].includes(key))) return false;
  const paths = [];
  for (const kind of ["read", "write", "entries"]) {
    if (files[kind] == null) continue;
    if (!Array.isArray(files[kind])) return false;
    for (const entry of files[kind]) {
      if (kind === "entries") {
        if (entry?.path?.type !== "path" || !["read", "write"].includes(entry.access)) return false;
        paths.push(entry.path.path);
      } else paths.push(entry);
    }
  }
  return paths.length > 0 && paths.every((path) => {
    if (typeof path !== "string" || !isAbsolute(path)) return false;
    try {
      const local = relative(cwd, realLocation(path));
      return local !== "" && local !== ".." && !local.startsWith("../") && !isAbsolute(local);
    } catch { return false; }
  });
}

function emptyMcpForm(params) {
  const schema = params.requestedSchema;
  return params.mode === "form" && typeof params.message === "string" && params.message.trim() &&
    (params._meta == null || (object(params._meta) && Object.keys(params._meta).length === 0)) &&
    schema?.type === "object" && object(schema.properties) && Object.keys(schema.properties).length === 0 &&
    (schema.required == null || (Array.isArray(schema.required) && schema.required.length === 0)) &&
    Object.keys(schema).every(key => ["type", "properties", "required", "$schema"].includes(key));
}

function oneTimeConsent(params, item) {
  if (emptyMcpForm(params)) return {};
  if (!computerControlTool(item.server, item.tool) || params.mode !== "form" ||
      typeof params.message !== "string" || !params.message.trim()) return;
  const schema = params.requestedSchema;
  if (schema?.type !== "object" || !object(schema.properties) ||
      Object.keys(schema).some(key => !["type", "properties", "required", "$schema", "additionalProperties"].includes(key))) return;
  const required = schema.required ?? [];
  if (!Array.isArray(required)) return;
  const keys = Object.keys(schema.properties);
  if (keys.length === 0 && required.length === 0) return {};
  if (keys.length !== 1 || !required.every(key => key === keys[0])) return;
  const field = schema.properties[keys[0]];
  if (keys[0] === "approval" && field?.type === "string" &&
      ((Array.isArray(field.oneOf) && field.oneOf.some(choice => choice?.const === "once")) ||
       (Array.isArray(field.enum) && field.enum.includes("once")))) {
    return { approval: "once" };
  }
  if (keys[0] === "always" && field?.type === "boolean") return { always: false };
}

export class CodexAgent {
  constructor({ emit }) {
    this.writeEvent = emit;
    this.messages = [];
    this.webSearch = "unknown";
    this.computerUse = null;
    this.pendingApprovals = new Map();
  }

  emit(event) {
    if (!this.closed) this.writeEvent(event);
  }

  async handle(command) {
    if (this.closed || !object(command)) return;
    try {
      switch (command.type) {
        case "open":
          if (!this.opening) {
            this.opening = true;
            await this.open(command);
          }
          break;
        case "prompt":
          if (this.ready) await this.prompt(command);
          break;
        case "cancel":
          if (this.active?.id === command.turnID) await this.cancel();
          break;
        case "toolApprovalResult":
          this.respond(command);
          break;
        case "steer":
        case "skipCompaction":
          if (uuid(command.turnID) && uuid(command.queuedID)) {
            this.emit({ type: "queueRejected", turnID: command.turnID, queuedID: command.queuedID,
              error: "Codex can receive queued messages between turns." });
          }
          break;
        case "readSentFile":
        case "readSentImage": {
          if (!uuid(command.requestID)) break;
          const receipt = this.mapping?.runs.find(({ message }) => message.id === command.messageID);
          const file = command.type === "readSentFile" && uuid(command.attachmentID)
            ? receipt?.files[command.attachmentID] : undefined;
          this.emit({ type: command.type === "readSentFile" ? "sentFile" : "sentImage",
            requestID: command.requestID, file });
          break;
        }
        case "fork":
          if (uuid(command.threadID)) this.emit({ type: "forked", threadID: command.threadID, error: "Codex history cannot be forked here." });
          break;
      }
    } catch (error) {
      this.fail(error);
    }
  }

  async open(command) {
    const { config, cwd, threadID, sessionDir, forkMessageID, sideChatSource, toolPermission } = command;
    if (!uuid(threadID) || !isAbsolute(cwd ?? "") || !isAbsolute(sessionDir ?? "") ||
        config?.provider !== provider || typeof config.model !== "string" || !config.model.trim()) {
      throw new Error("The Codex conversation configuration is invalid.");
    }
    if (forkMessageID || sideChatSource) throw new Error("This route cannot open forked or inherited Pi history.");
    this.threadID = threadID;
    this.cwd = realpathSync(cwd);
    this.mode = toolPermission;
    this.policy = toolsPolicy(toolPermission);
    this.model = config.model === "auto" ? undefined : config.model;
    this.effort = config.thinkingLevel === "off" ? undefined : config.thinkingLevel;
    mkdirSync(sessionDir, { recursive: true, mode: 0o700 });
    for (let attempt = 0; !this.closed; attempt++) {
      try {
        this.releaseOwner = acquireOwner(sessionDir);
        break;
      } catch (error) {
        if (error.message !== ownerBusy || attempt >= 20) throw error;
        await delay(75);
      }
    }
    if (this.closed) return;
    this.metadata = join(sessionDir, metadataName);
    if (readdirSync(sessionDir).some(name => name.endsWith(".jsonl"))) {
      throw new Error("This conversation has Pi history and cannot open in Codex.");
    }
    this.mapping = readMapping(this.metadata);
    this.persisted = Boolean(this.mapping);
    if (!this.mapping && command.requireHistory) throw new Error("The linked Codex conversation history is missing.");
    if (this.mapping && (this.mapping.version !== 1 || this.mapping.threadID !== threadID ||
        this.mapping.cwd !== this.cwd || !uuid(this.mapping.remoteThreadID) ||
        typeof this.mapping.remoteSessionID !== "string" || !Array.isArray(this.mapping.runs))) {
      throw new Error("The Codex history mapping belongs to a different conversation or checkout.");
    }

    this.rpc = new CodexRPC({
      cwd: this.cwd,
      onNotification: (method, params) => {
        try { this.notification(method, params); }
        catch (error) { this.fail(error); }
      },
      onRequest: (method, params) => this.request(method, params),
      onClose: (error) => this.fail(error ?? new Error("Codex app-server disconnected.")),
    });
    const initialized = await this.rpc.start();
    const home = initialized?.codexHome ?? (process.env.CODEX_HOME || join(homedir(), ".codex"));
    this.home = hash(realLocation(resolve(this.cwd, home)));
    const [configRead, requirementsRead, account] = await Promise.all([
      this.rpc.call("config/read", { cwd: this.cwd }, { timeoutMs: 5_000 }).catch(() => null),
      this.rpc.call("configRequirements/read", {}, { timeoutMs: 5_000 }).catch(() => null),
      this.rpc.call("account/read", { refreshToken: false }, { timeoutMs: 5_000 }).catch(() => null),
    ]);
    if (this.closed) return;
    const identity = account?.userId ?? account?.account?.email ?? null;
    this.account = account?.account ? hash([account.account.type, identity,
      account.workspaceRouting?.chatgptAccountId ?? null, account.workspaceRouting?.backendOrigin ?? null]) : null;
    if (this.mapping && (this.mapping.home !== this.home ||
        (this.mapping.account && this.mapping.account !== this.account))) {
      throw new Error("This Codex history belongs to a different Codex home or account.");
    }
    this.configureSearch(configRead?.config, requirementsRead);
    this.computerUseBlocked = requirementsRead?.requirements?.allowBrowserAndComputerUse === false;
    if (this.mapping) await this.resume();

    this.ready = true;
    this.emit({ type: "ready", messages: this.messages, supportsImages: false });
    this.capabilities();
    void this.refreshComputerUse();
    void this.publishModels(configRead?.config?.model);
  }

  async publishModels(configuredModel) {
    const models = { auto: "Codex default" };
    if (typeof configuredModel === "string" && configuredModel) models[configuredModel] = configuredModel;
    const listed = await this.pages("model/list", { limit: 100 }).catch(() => []);
    for (const model of listed) {
      if (typeof model.id === "string" && model.id) models[model.id] = model.displayName || model.id;
    }
    if (!this.closed) this.emit({ type: "modelCatalog", models: { "codex-app-server": models } });
  }

  configureSearch(config, response) {
    const modes = response?.requirements?.allowedWebSearchModes;
    let selected = config?.web_search;
    if (config && response && selected == null && (!modes || modes.includes("live"))) {
      selected = "live";
      this.searchOverride = selected;
    }
    if (modes && !modes.includes(selected)) {
      selected = modes.length === 1 ? modes[0] : undefined;
    }
    if (selected === "indexed") selected = "cached";
    if (["live", "cached", "disabled"].includes(selected)) this.webSearch = selected;
  }

  capabilities() {
    this.emit({ type: "codexCapabilities", webSearch: this.webSearch, computerUse: this.computerUse });
  }

  async refreshComputerUse() {
    const probe = Symbol();
    this.capabilityProbe = probe;
    const available = this.computerUseBlocked ? false : await this.computerInventory().catch(() => null);
    if (this.capabilityProbe !== probe) return;
    this.computerUse = available;
    this.capabilities();
  }

  async computerInventory() {
    const servers = await this.pages("mcpServerStatus/list", {
      threadId: this.mapping?.remoteThreadID,
      detail: "toolsAndAuthOnly",
      limit: 50,
    });
    let incomplete = false;
    for (const server of servers) {
      if (["disabled", "authenticationRequired"].includes(server.runtimeStatus) || server.authStatus === "notLoggedIn") continue;
      if (server.toolsError || !object(server.tools) ||
          ["failed", "starting", "notStarted", "cancelled"].includes(server.runtimeStatus)) {
        incomplete = true;
        continue;
      }
      if (Object.entries(server.tools).some(([name, tool]) => computerControlTool(server.name, tool?.name ?? name))) {
        return true;
      }
    }
    return incomplete ? null : false;
  }

  async pages(method, params) {
    const cursors = new Set();
    const items = [];
    let cursor;
    do {
      const page = await this.rpc.call(method, { ...params, cursor }, { timeoutMs: 10_000 });
      if (!Array.isArray(page?.data)) throw new Error("Codex returned an invalid page.");
      items.push(...page.data);
      cursor = page.nextCursor;
      if (cursor && cursors.has(cursor)) throw new Error("Codex returned a repeated page cursor.");
      cursors.add(cursor);
    } while (cursor && !this.closed);
    return items;
  }

  threadOptions() {
    return {
      cwd: this.cwd, model: this.model, ...this.policy, approvalsReviewer: "user",
      config: this.searchOverride ? { web_search: this.searchOverride } : undefined,
    };
  }

  verifyThread(thread, mapping = this.mapping) {
    if (!uuid(thread?.id) || typeof thread.sessionId !== "string" || thread.ephemeral !== false ||
        !isAbsolute(thread.cwd ?? "") || realLocation(thread.cwd) !== this.cwd ||
        (mapping && (thread.id !== mapping.remoteThreadID || thread.sessionId !== mapping.remoteSessionID))) {
      throw new Error("Codex returned a different conversation or checkout.");
    }
  }

  verifyPolicy(response) {
    const expected = this.policy.sandbox === "read-only" ? "readOnly" : "workspaceWrite";
    if (response.sandbox?.type !== expected || response.sandbox.networkAccess === true ||
        response.approvalsReviewer !== "user" || !sameChoice(response.approvalPolicy, this.policy.approvalPolicy)) {
      throw new Error("Codex could not apply this conversation’s tool permissions.");
    }
    if (this.model && response.model !== this.model) throw new Error("Codex could not apply the requested model.");
  }

  async startThread() {
    const response = await this.rpc.call("thread/start", {
      ...this.threadOptions(), historyMode: "paginated", allowProviderModelFallback: false,
    });
    this.verifyThread(response.thread);
    this.verifyPolicy(response);
    this.mapping = {
      version: 1, threadID: this.threadID, cwd: this.cwd, home: this.home, account: this.account,
      remoteThreadID: response.thread.id, remoteSessionID: response.thread.sessionId,
      rolloutPath: response.thread.path ?? null, runs: [],
    };
    void this.refreshComputerUse();
  }

  async resume() {
    const threadId = this.mapping.remoteThreadID;
    const { thread } = await this.rpc.call("thread/read", { threadId });
    this.verifyThread(thread);
    if (thread.status?.type === "active") throw new Error("This Codex conversation is still running in another helper.");
    const response = await this.rpc.call("thread/resume", { ...this.threadOptions(), threadId, excludeTurns: true });
    this.verifyThread(response.thread);
    this.verifyPolicy(response);
    if (response.thread.status?.type === "active") throw new Error("This Codex conversation is still running in another helper.");
    const turns = await this.pages("thread/turns/list", { threadId, sortDirection: "asc", itemsView: "full", limit: 50 });
    const runsByTurn = new Map(this.mapping.runs.filter(run => run.remoteTurnID).map(run => [run.remoteTurnID, run]));
    const runsByClient = new Map(this.mapping.runs.map(run => [run.message.id, run]));
    for (const turn of turns) {
      const receipt = runsByTurn.get(turn.id) ?? turn.items
        .filter(({ type }) => type === "userMessage")
        .map(({ clientId }) => runsByClient.get(clientId))
        .find(Boolean);
      for (const item of turn.items.filter(({ type }) => type === "userMessage")) {
        if (receipt && this.isReceiptItem(receipt, item, turn.id)) {
          receipt.remoteTurnID = turn.id;
          receipt.accepted = true;
          this.messages.push(receipt.message);
        } else {
          this.messages.push({ id: item.id, role: "user", text: inputText(item.content) || "[Codex attachment]" });
        }
      }
      const incomplete = turn.status !== "completed" ? "interrupted" : undefined;
      const saved = receipt?.assistant ?? [];
      const assistant = turn.items.filter(({ type, text }) => type === "agentMessage" && text);
      assistant.forEach((item, index) => {
        const partial = saved[index]?.text;
        const text = incomplete && partial?.startsWith(item.text) ? partial : item.text;
        this.messages.push({ id: `${turn.id}:assistant:${index}`, role: "assistant", text, incompleteReply: incomplete });
      });
      if (incomplete) this.messages.push(...saved.slice(assistant.length));
    }
    if (this.mapping.runs.some(run => !run.accepted || !this.messages.some(message => message.id === run.message.id))) {
      throw new Error("Codex could not verify an earlier submission. Check its native history before sending it again.");
    }
    this.mapping.rolloutPath = response.thread.path ?? this.mapping.rolloutPath;
    this.save();
  }

  save() {
    writeMapping(this.metadata, this.mapping, !this.persisted);
    this.persisted = true;
  }

  async prompt(command) {
    const { turnID, queuedID, submissionID } = command;
    if (!uuid(turnID) || this.active || ![queuedID, submissionID].every(id => id === undefined || uuid(id))) return;
    const duplicate = this.mapping?.runs.find(run => run.turnID === turnID ||
      (queuedID && run.message.queuedID === queuedID) || (submissionID && run.message.submissionID === submissionID));
    if (duplicate) {
      this.emit({ type: "finished", turnID, messages: this.messages,
        error: duplicate.accepted ? undefined : "Codex could not verify whether this message was already sent." });
      return;
    }
    const run = { id: turnID, base: this.messages, items: new Map(), sent: false, cancelled: false };
    this.active = run;
    try {
      const prepared = prepareInput(command);
      if (!this.mapping) await this.startThread();
      if (this.closed || this.active !== run) return;
      if (run.cancelled) {
        this.finish(run);
        return;
      }
      run.receipt = {
        turnID, inputDigest: prepared.inputDigest, files: prepared.files,
        message: { id: randomUUID(), role: "user", text: command.text, queuedID, submissionID, attachments: prepared.attachments },
      };
      this.mapping.runs.push(run.receipt);
      this.save();
      run.sent = true;
      const { turn } = await this.rpc.call("turn/start", {
        threadId: this.mapping.remoteThreadID, input: prepared.input,
        clientUserMessageId: run.receipt.message.id, effort: this.effort,
      });
      if (this.active !== run) return;
      this.bindTurn(run, turn.id);
      this.addTurnItems(run, turn.items);
      if (this.isTerminal(turn)) this.terminal(run, turn);
      else if (run.cancelled) await this.interrupt(run);
    } catch (error) {
      if (this.active !== run || this.closed) return;
      if (run.sent && run.receipt.remoteTurnID) {
        this.fail(error);
      } else if (run.sent && ![-32601, -32602].includes(error.rpcCode)) {
        this.fail(new Error("Codex disconnected before confirming the submission. Reconnect to check its history."));
      } else {
        if (run.receipt && !run.sent) throw error;
        if (run.sent) {
          this.mapping.runs.pop();
          if (this.mapping.runs.length) this.save();
          else {
            rmSync(this.metadata, { force: true });
            this.persisted = false;
          }
        }
        this.finish(run, error.message);
      }
    }
  }

  bindTurn(run, remoteTurnID) {
    if (typeof remoteTurnID !== "string" || !remoteTurnID ||
        (run.receipt.remoteTurnID && run.receipt.remoteTurnID !== remoteTurnID) ||
        this.mapping.runs.some(receipt => receipt !== run.receipt && receipt.remoteTurnID === remoteTurnID)) {
      throw new Error("Codex returned an unexpected turn.");
    }
    if (!run.receipt.remoteTurnID) {
      run.receipt.remoteTurnID = remoteTurnID;
      this.save();
    }
  }

  isReceiptItem(receipt, item, turnID) {
    if (item.type !== "userMessage" || !Array.isArray(item.content)) return false;
    if (hash(inputText(item.content)) !== receipt.inputDigest) return false;
    return item.clientId ? item.clientId === receipt.message.id : receipt.remoteTurnID === turnID;
  }

  addTurnItems(run, items = []) {
    for (const item of items) this.addItem(run, item, true);
  }

  addItem(run, item, completed) {
    if (this.isReceiptItem(run.receipt, item, run.receipt.remoteTurnID) && !run.receipt.accepted) {
      run.receipt.accepted = true;
      this.messages = [...run.base, run.receipt.message];
      this.save();
      this.emit({ type: "history", messages: this.messages });
      if (run.replies?.size) this.emitPartial(run);
    }
    if (item.type === "agentMessage") {
      run.replies ??= new Map();
      const delta = run.replies.get(item.id) ?? "";
      if (completed || !run.replies.has(item.id)) {
        run.replies.set(item.id, delta.startsWith(item.text) ? delta : item.text || delta);
      }
    }
    const prior = run.items.get(item.id);
    run.items.set(item.id, item);
    const activity = toolActivity(item);
    if (activity && activity !== (prior && toolActivity(prior))) this.emit({ type: "activity", text: activity });
  }

  notification(method, params) {
    if (this.closed || !object(params)) return;
    if (method === "mcpServer/startupStatus/updated" && params.threadId === this.mapping?.remoteThreadID) {
      if (this.ready && params.status !== "starting") void this.refreshComputerUse();
      return;
    }
    if (params.threadId !== this.mapping?.remoteThreadID) return;
    const run = this.active;
    if (!run?.sent) return;
    if (method === "turn/started" && !run.receipt.remoteTurnID &&
        !this.mapping.runs.some(receipt => receipt.remoteTurnID === params.turn?.id)) {
      this.bindTurn(run, params.turn.id);
      this.addTurnItems(run, params.turn.items);
      if (run.cancelled) void this.interrupt(run).catch(error => this.fail(error));
    }
    const remoteTurnID = params.turnId ?? params.turn?.id;
    if (!remoteTurnID || remoteTurnID !== run.receipt.remoteTurnID) return;
    switch (method) {
      case "item/agentMessage/delta":
        if (typeof params.delta !== "string" || typeof params.itemId !== "string") break;
        run.replies ??= new Map();
        run.replies.set(params.itemId, (run.replies.get(params.itemId) ?? "") + params.delta);
        this.emitPartial(run);
        break;
      case "item/started":
      case "item/completed":
        if (!object(params.item)) break;
        this.addItem(run, params.item, method === "item/completed");
        if (params.item.type === "agentMessage" && run.replies?.size) this.emitPartial(run);
        break;
      case "item/mcpToolCall/progress": {
        const item = run.items.get(params.itemId);
        const activity = item?.type === "mcpToolCall" && toolActivity(item);
        if (activity) this.emit({ type: "activity", text: activity });
        break;
      }
      case "turn/completed":
        this.terminal(run, params.turn);
        break;
      case "error":
        if (params.willRetry === false) run.error = params.error?.message;
        break;
    }
  }

  emitPartial(run) {
    this.emit({ type: "partial", text: [...run.replies.values()].filter(Boolean).join("\n\n") });
  }

  isTerminal(turn) {
    return ["completed", "interrupted", "failed"].includes(turn.status);
  }

  terminal(run, turn) {
    this.addTurnItems(run, turn.items);
    if (!run.receipt.accepted) {
      this.fail(new Error("Codex ended the turn before confirming the user message. Reconnect to check its history."));
      return;
    }
    const incomplete = turn.status !== "completed";
    this.recordReply(run, incomplete);
    const error = turn.status === "failed" ? turn.error?.message || run.error || "The Codex turn failed." : undefined;
    this.finish(run, error);
  }

  recordReply(run, incomplete) {
    const assistant = [...(run.replies?.values() ?? [])].filter(Boolean).map((text, index) => ({
      id: `${run.receipt.remoteTurnID}:assistant:${index}`,
      role: "assistant", text, incompleteReply: incomplete ? "interrupted" : undefined,
    }));
    run.receipt.assistant = incomplete ? assistant : undefined;
    this.save();
    this.messages = [...run.base, run.receipt.message, ...assistant];
  }

  finish(run, error) {
    this.clearApprovals();
    this.active = undefined;
    this.emit({ type: "finished", turnID: run.id, messages: this.messages, error });
  }

  async cancel() {
    const run = this.active;
    run.cancelled = true;
    this.clearApprovals();
    await this.interrupt(run);
  }

  async interrupt(run) {
    if (!run.receipt?.remoteTurnID || run.interrupting || this.active !== run) return;
    run.interrupting = true;
    try {
      await this.rpc.call("turn/interrupt", {
        threadId: this.mapping.remoteThreadID, turnId: run.receipt.remoteTurnID,
      });
    } catch (error) {
      if (this.active === run) throw error;
    }
  }

  async request(method, params) {
    const run = this.active;
    const spec = this.approval(method, params, run);
    if (!spec) throw new Error("This Codex server request is unsupported.");
    if (!run?.sent || run.cancelled || this.closed || this.mode === "readFiles" ||
        params?.threadId !== this.mapping.remoteThreadID || !run.receipt.remoteTurnID ||
        params.turnId !== run.receipt.remoteTurnID || !spec.tool || this.pendingApprovals.size > 0) return spec.deny;
    // Refuse to approve a request whose complete details cannot be shown on the card.
    const details = JSON.stringify(spec.details, null, 2);
    if (details.length > 16_000) return spec.deny;
    return await new Promise(resolve => {
      const requestID = randomUUID();
      this.pendingApprovals.set(requestID, { run, resolve, ...spec });
      this.emit({ type: "toolApproval", requestID, threadID: this.threadID, turnID: run.id, tool: spec.tool, details });
    });
  }

  approval(method, params, run) {
    const p = params ?? {};
    switch (method) {
      case "item/commandExecution/requestApproval": {
        const deny = p.availableDecisions?.includes("decline") === false ? { decision: "cancel" } : declined;
        if (!["command", "humanCommand"].includes(p.kind ?? "command") ||
            typeof p.command !== "string" || !p.command.trim() || !isAbsolute(p.cwd ?? "") ||
            p.availableDecisions?.includes("accept") === false ||
            (p.additionalPermissions && !exactPermissions(p.additionalPermissions, this.cwd))) return { deny };
        return { deny, allow: { decision: "accept" }, tool: "Codex shell command", details: {
          command: p.command, directory: p.cwd, environment: p.environmentId, reason: p.reason,
          permissions: p.additionalPermissions, network: p.networkApprovalContext,
        } };
      }
      case "item/fileChange/requestApproval": {
        const item = run?.items.get(p.itemId);
        if (p.grantRoot != null || item?.type !== "fileChange" || !item.changes?.length ||
            !item.changes.every(change => typeof change.path === "string" && change.path &&
              typeof change.diff === "string" && object(change.kind))) return { deny: declined };
        return { deny: declined, allow: { decision: "accept" }, tool: "Codex file changes", details: {
          directory: this.cwd, reason: p.reason, changes: item.changes,
        } };
      }
      case "item/permissions/requestApproval":
        if (!exactPermissions(p.permissions, this.cwd) || !isAbsolute(p.cwd ?? "")) return { deny: noPermissions };
        return { deny: noPermissions,
          allow: { permissions: p.permissions, scope: "turn" }, tool: "Codex turn permissions",
          details: { directory: p.cwd, environment: p.environmentId, reason: p.reason, permissions: p.permissions, scope: "turn" },
        };
      case "mcpServer/elicitation/request": {
        const calls = [...(run?.items.values() ?? [])].filter(item =>
          item.type === "mcpToolCall" && item.server === p.serverName && item.status === "inProgress" &&
          (item.environmentId ?? null) === (p.environmentId ?? null));
        if (calls.length !== 1) return { deny: noElicitation };
        const content = oneTimeConsent(p, calls[0]);
        if (!content) return { deny: noElicitation };
        return { deny: noElicitation, allow: { action: "accept", content }, tool: toolActivity(calls[0]),
          details: { message: p.message, app: p._meta?.app_name ?? p._meta?.appName, arguments: calls[0].arguments } };
      }
      case "execCommandApproval":
      case "applyPatchApproval":
        return { deny: { decision: { denied: { rejection: "This client does not approve legacy requests." } } } };
      case "item/tool/requestUserInput":
        return { deny: { answers: {} } };
      case "item/tool/call":
        return { deny: { success: false, contentItems: [{ type: "inputText", text: "This client does not implement this tool." }] } };
    }
  }

  respond(command) {
    const request = this.pendingApprovals.get(command.requestID);
    if (!request || this.active !== request.run || request.run.cancelled ||
        command.threadID !== this.threadID || command.turnID !== request.run.id ||
        !["approve", "decline"].includes(command.decision)) return;
    this.pendingApprovals.delete(command.requestID);
    request.resolve(command.decision === "approve" ? request.allow : request.deny);
  }

  clearApprovals() {
    for (const request of this.pendingApprovals.values()) request.resolve(request.deny);
    this.pendingApprovals.clear();
  }

  fail(error) {
    if (this.closed) return;
    this.emit({ type: "fatal", error: error?.message || "Codex app-server disconnected." });
    this.close();
  }

  close() {
    if (this.closed) return;
    this.closed = true;
    this.clearApprovals();
    const run = this.active;
    this.active = undefined;
    try {
      if (run?.receipt?.accepted && run.replies?.size) this.recordReply(run, true);
    } catch {
      // The submitted receipt was written before dispatch, even when this last checkpoint fails.
    } finally {
      const closing = this.rpc?.close();
      void Promise.resolve(closing).finally(() => this.releaseOwner?.()).catch(() => {});
    }
  }
}

if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const input = createInterface({ input: process.stdin, crlfDelay: Infinity });
  const agent = new CodexAgent({ emit(event) {
    process.stdout.write(JSON.stringify(event) + "\n");
    if (event.type === "fatal") {
      process.exitCode = 1;
      input.close();
      process.stdin.destroy();
    }
  } });
  input.on("line", line => {
    let command;
    try { command = JSON.parse(line); } catch { return; }
    void agent.handle(command);
  });
  input.on("error", () => input.close());
  process.stdout.on("error", () => input.close());
  input.on("close", () => agent.close());
  process.once("SIGTERM", () => {
    agent.close();
    input.close();
    process.stdin.destroy();
  });
}
