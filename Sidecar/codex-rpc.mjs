import { spawn } from "node:child_process";
import { accessSync, constants, existsSync, readdirSync, realpathSync, statSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { basename, delimiter, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { createInterface } from "node:readline";

const startupTimeout = 10_000;
const shutdownTimeout = 1_000;

function rpcError(code, message) {
  return Object.assign(new Error(message), { code });
}

function canonical(path) {
  if (!path || !isAbsolute(path)) return undefined;
  try { return realpathSync(path); } catch { return undefined; }
}

function inside(path, directory) {
  const suffix = relative(directory, path);
  return suffix === "" || (!isAbsolute(suffix) && suffix !== ".." && !suffix.startsWith(".." + sep));
}

function trusted(path, project, { explicit = false } = {}) {
  if (project && inside(path, project)) return false;
  if (!explicit && [canonical(tmpdir()), canonical("/tmp")].some((temp) => temp && inside(path, temp))) {
    return false;
  }
  try {
    let entry = path;
    while (true) {
      const { uid, mode } = statSync(entry);
      if (uid !== 0 && uid !== process.getuid()) return false;
      // An explicit override may live below a sticky system temp directory.
      if (mode & 0o022 && !(explicit && entry !== path && (mode & 0o1000))) return false;
      if (existsSync(join(entry, ".git"))) return false;
      const parent = dirname(entry);
      if (parent === entry) return true;
      entry = parent;
    }
  } catch {
    return false;
  }
}

function installedVersions(root) {
  try {
    return readdirSync(root).filter((name) => /^(?:rust-v|v)?\d+\.\d+\.\d+(?:[-+][\w.-]+)?$/.test(name))
      .sort((a, b) => b.localeCompare(a, "en", { numeric: true }));
  } catch {
    return [];
  }
}

function executable(candidate, project, explicit) {
  const path = canonical(candidate);
  if (!path || !trusted(resolve(candidate), project, { explicit }) ||
      !trusted(path, project, { explicit })) return undefined;
  try {
    accessSync(path, constants.X_OK);
    if (!statSync(path).isFile()) return undefined;
    return path;
  } catch {
    return undefined;
  }
}

function findCodex(cwd, env) {
  const home = canonical(env.HOME) ?? canonical(homedir());
  const directory = canonical(cwd);
  const project = directory !== home && directory !== "/" ? directory : undefined;
  const local = home && join(home, ".local", "share");
  const aqua = isAbsolute(env.AQUA_ROOT_DIR ?? "") ? env.AQUA_ROOT_DIR : local && join(local, "aquaproj-aqua");
  const mise = isAbsolute(env.MISE_DATA_DIR ?? "") ? env.MISE_DATA_DIR : local && join(local, "mise");
  const systemBins = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"];
  const userBins = home ? [".local/bin", "bin", ".npm-global/bin", ".npm-packages/bin"].map((dir) => join(home, dir)) : [];
  const miseBins = mise ? ["codex", "npm-openai-codex", "node"].flatMap((tool) => {
    const root = join(mise, "installs", tool);
    return installedVersions(root).map((version) => join(root, version, "bin"));
  }) : [];
  const searchBins = [
    ...(env.PATH ?? "").split(delimiter), ...systemBins, ...userBins, ...miseBins, dirname(process.execPath),
  ];
  const bins = [...new Set(searchBins.flatMap((candidate) => {
    const path = canonical(candidate);
    return path && trusted(resolve(candidate), project) && trusted(path, project) ? [path] : [];
  }))];

  if (env.TNCODE_CODEX_BIN !== undefined) {
    const path = executable(env.TNCODE_CODEX_BIN, project, true);
    if (!path) throw rpcError("codex_invalid_executable", "The configured Codex CLI executable is unavailable.");
    return { path, bins };
  }

  const bundles = ["/Applications/Codex.app"];
  if (home) bundles.push(join(home, "Applications", "Codex.app"));
  const bundleBins = process.platform === "darwin" ? bundles.flatMap((bundle) => [
    join(bundle, "Contents", "Resources", "codex"),
    join(bundle, "Contents", "MacOS", "codex"),
  ]) : [];

  // Aqua and mise shims can select a project-local installation. Use installed binaries directly.
  const aquaBinaries = [];
  if (aqua) {
    const root = join(aqua, "pkgs", "github_release", "github.com", "openai", "codex");
    const arch = { arm64: "aarch64", x64: "x86_64" }[process.arch];
    const platform = { darwin: "apple-darwin", linux: "unknown-linux-musl" }[process.platform];
    if (arch && platform) {
      for (const version of installedVersions(root)) {
        const release = join(root, version);
        const target = arch + "-" + platform;
        aquaBinaries.push(
          join(release, "codex-package-" + target + ".tar.gz", "bin", "codex"),
          join(release, "codex-" + target + ".tar.gz", "codex-" + target),
        );
      }
    }
  }
  const chatGPTBins = process.platform === "darwin" ? ["/Applications", ...(home ? [join(home, "Applications")] : [])]
    .map(dir => join(dir, "ChatGPT.app/Contents/Resources/codex-cli/bin/codex")) : [];
  for (const candidate of [...bins.map((dir) => join(dir, "codex")), ...bundleBins, ...aquaBinaries, ...chatGPTBins]) {
    const path = executable(candidate, project, false);
    if (path && !["aqua-proxy", "mise"].includes(basename(path))) return { path, bins };
  }
  throw rpcError("codex_not_installed", "Codex CLI was not found.");
}

function responseError(error) {
  const message = typeof error?.message === "string" ? error.message : "";
  const reason = /address already in use|EADDRINUSE|port \d+ is in use/i.test(message) ? "callback_unavailable"
    : /device code (?:login|sign.in).*(?:disabled|not enabled)|enable device code/i.test(message) ? "device_code_unavailable"
    : /failed to (?:save|write|persist).*(?:auth|credential)|credential store/i.test(message) ? "credential_store_failed"
    : undefined;
  return Object.assign(rpcError("codex_rpc_error", "Codex rejected the request."), {
    rpcCode: Number.isSafeInteger(error?.code) ? error.code : undefined,
    reason,
  });
}

export class CodexRPC {
  #cwd;
  #onNotification;
  #onRequest;
  #onClose;
  #child;
  #starting;
  #stopped;
  #startReady = false;
  #nextID = 0;
  #pending = new Map();
  #serverRequests = new Map();
  #exited;
  #killOnExit;

  constructor({ cwd, onNotification, onRequest, onClose }) {
    this.#cwd = cwd;
    this.#onNotification = onNotification;
    this.#onRequest = onRequest;
    this.#onClose = onClose;
  }

  start() {
    if (this.#stopped) return Promise.reject(this.#stopped);
    return this.#starting ??= this.#start();
  }

  async #start() {
    try {
      const { path, bins } = findCodex(this.#cwd, process.env);
      const env = { ...process.env, PATH: bins.join(delimiter) };
      let child;
      try {
        child = spawn(path, ["app-server", "--listen", "stdio://"], {
          cwd: this.#cwd, env, detached: true, stdio: ["pipe", "pipe", "ignore"],
        });
      } catch {
        throw rpcError("codex_unavailable", "Could not start Codex app-server.");
      }
      this.#child = child;
      this.#killOnExit = () => this.#signal("SIGKILL");
      process.once("exit", this.#killOnExit);
      const input = createInterface({ input: child.stdout, crlfDelay: Infinity });
      input.on("line", (line) => this.#read(line));
      const disconnected = () => this.#stop(rpcError("codex_unavailable", "Codex app-server disconnected."));
      child.on("error", disconnected);
      child.stdin.on("error", disconnected);
      child.stdout.on("error", disconnected);
      input.on("error", disconnected);
      input.on("close", disconnected);
      this.#exited = new Promise((resolve) => child.once("close", () => {
        disconnected();
        this.#signal("SIGKILL");
        process.removeListener("exit", this.#killOnExit);
        resolve();
      }));
      await this.#call("initialize", {
        clientInfo: { name: "tncode", title: "tncode", version: "1.0.0" },
        capabilities: { experimentalApi: true },
      }, { timeoutMs: startupTimeout });
      await this.#write({ method: "initialized" });
      this.#startReady = true;
    } catch (error) {
      this.#stop(error);
      throw error;
    }
  }

  call(method, params, options) {
    if (!this.#startReady || this.#stopped) {
      return Promise.reject(this.#stopped ?? rpcError("codex_unavailable", "Codex app-server is not ready."));
    }
    return this.#call(method, params, options);
  }

  #call(method, params, { signal, timeoutMs } = {}) {
    const cancelled = () => rpcError("codex_cancelled", "The Codex request was cancelled.");
    if (signal?.aborted) return Promise.reject(cancelled());
    const id = ++this.#nextID;
    return new Promise((resolve, reject) => {
      const abort = () => this.#settle(id, cancelled());
      const timer = timeoutMs === undefined ? undefined : setTimeout(() => {
        this.#settle(id, rpcError("codex_timeout", "The Codex request timed out."));
      }, timeoutMs);
      signal?.addEventListener("abort", abort, { once: true });
      this.#pending.set(id, {
        resolve, reject,
        cleanup() {
          clearTimeout(timer);
          signal?.removeEventListener("abort", abort);
        },
      });
      this.#write({ id, method, params }).catch((error) => this.#settle(id, error));
    });
  }

  #settle(id, error, result) {
    const pending = this.#pending.get(id);
    if (!pending) return;
    this.#pending.delete(id);
    pending.cleanup();
    if (error) pending.reject(error);
    else pending.resolve(result);
  }

  async #write(message) {
    if (this.#stopped) throw this.#stopped;
    let line;
    try { line = JSON.stringify(message) + "\n"; }
    catch { throw rpcError("codex_protocol_error", "Could not encode the Codex request."); }
    await new Promise((resolve, reject) => this.#child.stdin.write(line, (error) => {
      if (error) reject(rpcError("codex_unavailable", "Could not write to Codex app-server."));
      else resolve();
    }));
  }

  #read(line) {
    if (this.#stopped || !line.trim()) return;
    let message;
    try { message = JSON.parse(line); } catch { /* handled below */ }
    if (!message || typeof message !== "object" || Array.isArray(message)) {
      this.#stop(rpcError("codex_protocol_error", "Codex app-server sent invalid data."));
      return;
    }

    const { id, method, params, error, result } = message;
    if (typeof method === "string") {
      if (typeof id === "string" || Number.isSafeInteger(id)) {
        void this.#answer(id, method, params);
      } else {
        if (method === "serverRequest/resolved") this.#serverRequests.delete(params?.requestId);
        try { this.#onNotification?.(method, params); }
        catch { this.#stop(rpcError("codex_protocol_error", "Could not handle a Codex notification.")); }
      }
    } else if (Object.hasOwn(message, "error") || Object.hasOwn(message, "result")) {
      this.#settle(id, error ? responseError(error) : undefined, result);
    }
  }

  async #answer(id, method, params) {
    const request = {};
    this.#serverRequests.set(id, request);
    let reply;
    try {
      const result = await this.#onRequest?.(method, params);
      reply = result === undefined ? { error: { code: -32601, message: "Unsupported server request." } } : { result };
    } catch {
      reply = { error: { code: -32603, message: "Could not handle the server request." } };
    }
    if (this.#serverRequests.get(id) !== request) return;
    this.#serverRequests.delete(id);
    try { await this.#write({ id, ...reply }); }
    catch (error) { this.#stop(error); }
  }

  #signal(signal) {
    if (!this.#child?.pid) return;
    try { process.kill(-this.#child.pid, signal); } catch { /* process group has exited */ }
  }

  #stop(error) {
    if (this.#stopped) return;
    this.#stopped = error ?? rpcError("codex_closed", "The Codex connection was closed.");
    this.#serverRequests.clear();
    for (const id of this.#pending.keys()) this.#settle(id, this.#stopped);
    if (this.#child) {
      this.#child.stdin.destroy();
      this.#signal("SIGTERM");
      const force = setTimeout(() => this.#signal("SIGKILL"), shutdownTimeout);
      void this.#exited.then(() => clearTimeout(force));
    }
    try { this.#onClose?.(error); } catch { /* teardown is complete */ }
  }

  async close() {
    this.#stop();
    await this.#exited;
  }
}
