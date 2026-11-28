import { randomInt } from "node:crypto";
import { closeSync, mkdirSync, openSync } from "node:fs";
import { isAbsolute, join } from "node:path";
import { createInterface } from "node:readline";

const providers = new Map([
  ["openai-codex", {
    load: async () => (await import("@earendil-works/pi-ai/providers/openai-codex")).openaiCodexProvider(),
    code: "device_code",
  }],
  ["openai", {
    load: async () => (await import("@earendil-works/pi-ai/providers/openai")).openaiProvider(),
  }],
  ["anthropic", {
    load: async () => (await import("@earendil-works/pi-ai/providers/anthropic")).anthropicProvider(),
    code: "copy_code",
  }],
  ["github-copilot", {
    load: async () => (await import("@earendil-works/pi-ai/providers/github-copilot")).githubCopilotProvider(),
  }],
]);
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const input = createInterface({ input: process.stdin, crlfDelay: Infinity });
const controller = new AbortController();
const { signal } = controller;
let started = false;
let finished = false;
let nextPromptID = randomInt(2 ** 46);
let pending;

function emit(step, fields = {}, flushed) {
  process.stdout.write(JSON.stringify({ type: "login", step, ...fields }) + "\n", flushed);
}

function finish(error) {
  if (finished) return;
  finished = true;
  input.close();
  // This is a single-use process. Exit after flushing IPC even if a browser kept a callback connection open.
  emit(error ? "error" : "complete", error ? { message: error } : {}, () => process.exit(0));
}

function cancel() {
  if (finished) return;
  controller.abort();
  if (!started) finish("cancelled");
}

function present(prompt) {
  const promptSignal = prompt.signal ? AbortSignal.any([signal, prompt.signal]) : signal;
  promptSignal.throwIfAborted();
  const id = ++nextPromptID;
  const options = prompt.options?.map(({ id, label }) => ({ id, label }));
  return new Promise((resolve, reject) => {
    function dismiss() {
      pending = undefined;
      promptSignal.removeEventListener("abort", abort);
      emit("dismissPrompt", { id });
    }
    function abort() {
      dismiss();
      reject(promptSignal.reason);
    }
    pending = {
      id,
      answer(value) {
        if (options && !options.some((option) => option.id === value)) return;
        dismiss();
        resolve(value);
      },
    };
    promptSignal.addEventListener("abort", abort, { once: true });
    emit("prompt", { id, kind: prompt.type, message: prompt.message, placeholder: prompt.placeholder, options });
  });
}

function notify(event) {
  signal.throwIfAborted();
  switch (event.type) {
    case "auth_url":
      emit("browser", { url: event.url });
      break;
    case "device_code": {
      const url = new URL(event.verificationUri);
      if (url.protocol !== "https:" || url.username || url.password ||
          typeof event.userCode !== "string" || !/^[A-Z0-9-]{4,32}$/i.test(event.userCode)) {
        throw new Error("Invalid device verification details");
      }
      emit("device", { url: url.href, code: event.userCode });
      break;
    }
    case "progress":
      emit("progress");
      break;
  }
}

async function login({ provider, deviceID, method }) {
  const entry = providers.get(provider);
  if (!entry) return finish("unsupported_provider");
  if ((provider === "openai" && (typeof deviceID !== "string" || !uuid.test(deviceID))) ||
      (method !== undefined && method !== "browser" && (method !== "code" || !entry.code))) {
    return finish("invalid_request");
  }
  const loginDir = process.env.PI_WORKSPACE_LOGIN_DIR;
  if (!loginDir || !isAbsolute(loginDir)) return finish("missing_login_directory");
  const authPath = join(loginDir, "auth.json");

  let storeFailed = false;
  try {
    // Native sign-in uses the SDK's local browser callback even when launched from a shell with Pi settings.
    process.env.PI_OAUTH_CALLBACK_HOST = "127.0.0.1";
    // Pi 1.6.1 keeps its file backend internal to the coding-agent package.
    const sdk = import.meta.resolve("@earendil-works/pi-coding-agent");
    const [{ createModels }, { FileAuthStorageBackend }, sdkProvider] = await Promise.all([
      import("@earendil-works/pi-ai/models"),
      import(new URL("./core/auth-storage.js", sdk)),
      entry.load(),
    ]);
    const models = createModels({
      credentials: {
        async modify(id, update, options) {
          const credential = await update();
          if (credential?.type !== "oauth" || typeof credential.access !== "string" || !credential.access ||
              typeof credential.refresh !== "string" || !credential.refresh || !Number.isFinite(credential.expires)) {
            throw new Error("Invalid OAuth credential");
          }
          try {
            signal.throwIfAborted();
            mkdirSync(loginDir, { recursive: true, mode: 0o700 });
            // Create an empty file exclusively so simultaneous first-time sign-ins share the SDK's lock.
            try { closeSync(openSync(authPath, "wx", 0o600)); }
            catch (error) { if (error.code !== "EEXIST") throw error; }
            return await new FileAuthStorageBackend(authPath).withLockAsync((current) => {
              const data = JSON.parse(current?.replace(/^\uFEFF/, "") || "{}");
              if (!data || typeof data !== "object" || Array.isArray(data)) throw new Error("Invalid auth store");
              return { result: credential, next: JSON.stringify({ ...data, [id]: credential }, null, 2) };
            }, options);
          } catch (error) {
            storeFailed = true;
            throw error;
          }
        },
      },
    });
    models.setProvider(sdkProvider);
    await models.login(provider, "oauth", {
      signal,
      async prompt(prompt) {
        signal.throwIfAborted();
        if (entry.code && prompt.type === "select" && prompt.options.length === 2 &&
            prompt.options.some(({ id }) => id === "browser") && prompt.options.some(({ id }) => id === entry.code)) {
          return method === "code" ? entry.code : "browser";
        }
        return present(prompt);
      },
      notify,
    }, { agentName: "Pi Workspace", getDeviceId: () => deviceID });
    finish();
  } catch (error) {
    const busy = error?.code === "EADDRINUSE" || /^Port \d+ is in use\b/.test(error?.message ?? "");
    finish(signal.aborted ? "cancelled" : storeFailed ? "credential_store_failed" : busy ? "callback_unavailable" : "login_failed");
  }
}

input.on("line", (line) => {
  if (finished || signal.aborted) return;
  let command;
  try { command = JSON.parse(line); }
  catch {
    if (!started) finish("invalid_request");
    return;
  }
  if (command?.type === "cancel") return cancel();
  if (command?.type === "answer" && pending && command.id === pending.id && typeof command.value === "string") {
    pending.answer(command.value);
  } else if (!started) {
    if (command?.type !== "login") return finish("invalid_request");
    started = true;
    void login(command);
  }
});
input.on("close", cancel);
process.stdin.on("error", cancel);
input.on("error", cancel);
process.stdout.on("error", cancel);
process.on("SIGTERM", cancel);
process.on("SIGINT", cancel);
