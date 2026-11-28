import childProcess from "node:child_process";
import dgram from "node:dgram";
import dns from "node:dns";
import { writeSync } from "node:fs";
import { syncBuiltinESMExports } from "node:module";
import net from "node:net";

const allowedPort = Number(process.env.PI_VERIFY_LOOPBACK_PORT);

function report(entry) {
  writeSync(1, JSON.stringify({ type: "networkObservation", ...entry }) + "\n");
}

function attempt(api, host, port, allowed = false) {
  report({ api, host, port, allowed });
  if (!allowed) {
    const error = new Error(`Pi network verifier blocked ${api} to ${host ?? "unknown"}:${port ?? "unknown"}`);
    error.code = "PI_VERIFY_NETWORK_BLOCKED";
    throw error;
  }
}

const connect = net.Socket.prototype.connect;
net.Socket.prototype.connect = function (...args) {
  // Node's HTTP and TLS clients can pass the already-normalized argument tuple.
  const [options] = Array.isArray(args[0]) ? args[0] : net._normalizeArgs(args);
  const host = options.path ?? options.host ?? "localhost";
  const port = options.path ? null : Number(options.port);
  attempt("tcp.connect", host, port, !options.path && host === "127.0.0.1" && port === allowedPort);
  return connect.apply(this, args);
};

for (const resolver of [dns, dns.promises, dns.Resolver.prototype, dns.promises.Resolver.prototype]) {
  for (const name of Object.getOwnPropertyNames(resolver)) {
    if (/^(lookup|lookupService|resolve.*|reverse)$/.test(name) && typeof resolver[name] === "function") {
      resolver[name] = (host) => attempt(`dns.${name}`, host, null);
    }
  }
}

dgram.Socket.prototype.connect = function (port, host) {
  attempt("udp.connect", host ?? null, port);
};
for (const name of ["send", "sendto"]) {
  dgram.Socket.prototype[name] = function (_message, ...args) {
    const [port, host] = typeof args[1] === "number" ? args.slice(2) : args;
    attempt(`udp.${name}`, typeof host === "string" ? host : null, typeof port === "number" ? port : null);
  };
}

for (const name of ["execSync", "execFileSync", "spawnSync"]) {
  childProcess[name] = (file) => attempt(`process.${name}`, file, null);
}
childProcess.ChildProcess.prototype.spawn = function (options) {
  attempt("process.spawn", options.file, null);
};

syncBuiltinESMExports();
report({ node: process.versions.node });
