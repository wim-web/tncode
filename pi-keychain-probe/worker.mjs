import { execFileSync } from "node:child_process";
import { join } from "node:path";
import {
  createAgentSession,
  createExtensionRuntime,
  ModelRuntime,
  SessionManager,
  SettingsManager,
} from "@earendil-works/pi-coding-agent";

const [mode, keychain, id, port] = process.argv.slice(2);
const provider = "keychain-probe";
const modelId = "smollm2:135m";
const cwd = process.cwd();
const agentDir = join(cwd, "..", "config");

function lookup(operation) {
  try {
    return execFileSync(keychain, [operation, id], { timeout: 10_000 }).toString("utf8");
  } catch (error) {
    if (error.status === 44) return undefined;
    throw new Error(`Keychain lookup failed: ${error.stderr?.toString().trim() || error.code || error.status}`);
  }
}

/** @type {import("@earendil-works/pi-ai").CredentialStore} */
const credentials = {
  async read(providerId) {
    if (providerId !== provider) return undefined;
    const key = lookup("read");
    return key === undefined ? undefined : { type: "api_key", key };
  },
  async list() {
    return lookup("exists") === undefined ? [] : [{ providerId: provider, type: "api_key" }];
  },
  async modify() { throw new Error("Only the Swift process can provision the probe key"); },
  async delete() { throw new Error("Only the Swift process can delete the probe key"); },
};

try {
  const modelRuntime = await ModelRuntime.create({
    credentials,
    authPath: join(agentDir, "auth.json"),
    modelsPath: null,
    refreshOnCreate: false,
    allowModelNetwork: false,
  });
  modelRuntime.registerProvider(provider, {
    api: "openai-completions",
    baseUrl: `http://127.0.0.1:${port}/v1`,
    models: [{
      id: modelId,
      name: "SmolLM2 135M",
      reasoning: false,
      input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 8192,
      maxTokens: 24,
      samplingParams: { temperature: 0 },
      compat: { maxTokensField: "max_tokens", supportsStore: false },
    }],
  });

  if (mode === "check") {
    const result = await modelRuntime.checkAuth(provider);
    console.log(JSON.stringify({ pid: process.pid, auth: result?.source ?? null }));
  } else if (mode === "prompt") {
    const model = modelRuntime.getModel(provider, modelId);
    if (!model) throw new Error("Probe model missing from the Pi runtime");
    const settingsManager = SettingsManager.inMemory({
      compaction: { enabled: false },
      retry: { enabled: false, provider: { maxRetries: 0 } },
      cacheWarming: "off",
    });
    const { session } = await createAgentSession({
      cwd,
      agentDir,
      model,
      modelRuntime,
      noTools: "all",
      thinkingLevel: "off",
      sessionManager: SessionManager.inMemory(cwd),
      settingsManager,
      resourceLoader: {
        getExtensions: () => ({ extensions: [], errors: [], runtime: createExtensionRuntime() }),
        getSkills: () => ({ skills: [], diagnostics: [] }),
        getPrompts: () => ({ prompts: [], diagnostics: [] }),
        getThemes: () => ({ themes: [], diagnostics: [] }),
        getAgentsFiles: () => ({ agentsFiles: [] }),
        getSystemPrompt: () => "Give a short factual answer.",
        getSystemPromptSource: () => undefined,
        getAppendSystemPrompt: () => [],
        getAppendSystemPromptSources: () => [],
        extendResources: () => {},
        reload: async () => {},
      },
    });
    let assistant;
    session.subscribe((event) => {
      if (event.type === "message_end" && event.message.role === "assistant") {
        assistant = event.message;
      }
    });
    try {
      await session.prompt("What is the capital of France? Answer with just the city name.");
      const answer = session.getLastAssistantText()?.trim();
      if (assistant?.stopReason !== "stop" || !answer) {
        throw new Error(assistant?.errorMessage || `Unsuccessful model response: ${assistant?.stopReason}`);
      }
      console.log(JSON.stringify({ pid: process.pid, stop: assistant.stopReason, answer }));
    } finally {
      session.dispose();
    }
  } else {
    throw new Error("Unknown probe mode");
  }
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
