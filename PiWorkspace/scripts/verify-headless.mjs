import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { once } from "node:events";
import { existsSync, mkdtempSync, readFileSync, realpathSync, rmSync } from "node:fs";
import { constants, tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { withModelRoutingFixture } from "./fixtures/model-routing.mjs";

const usage = `Usage: node scripts/verify-headless.mjs
Runs Pi worker and session fixtures on loopback HTTP, checkout Git, and Swift
persistence and file format tests. Requires macOS, Swift 6.2+, Node.js 22.19+,
and the pinned Sidecar dependencies. From PiWorkspace, install them with
npm --prefix Sidecar ci --ignore-scripts.

Native windows, panels, keyboard, pointer, and pasteboard checks require a
separate GUI run on an isolated macOS desktop. See verify-app.mjs,
verify-file-drops.mjs, and verify-native-paste.mjs.`;

if (process.argv.length > 2) {
  if (process.argv.length === 3 && process.argv[2] === "--help") console.log(usage);
  else {
    console.error(usage);
    process.exitCode = 2;
  }
} else {
  try {
    await verify();
  } catch (error) {
    console.error(`Headless verification failed. ${error.message}`);
    process.exitCode ||= 1;
  }
}

async function verify() {
  assert.equal(process.platform, "darwin", "The Swift tests require macOS.");
  const workspace = resolve(import.meta.dirname, "..");
  const sidecar = join(workspace, "Sidecar");
  const sdk = "node_modules/@earendil-works/pi-coding-agent";
  const manifest = join(sidecar, sdk, "package.json");
  const locked = JSON.parse(readFileSync(join(sidecar, "package-lock.json"), "utf8")).packages[sdk].version;
  assert(existsSync(manifest) && JSON.parse(readFileSync(manifest, "utf8")).version === locked,
    "Install the pinned Pi SDK with npm --prefix Sidecar ci --ignore-scripts from PiWorkspace.");
  const developer = spawnSync("/usr/bin/xcode-select", ["--print-path"], { encoding: "utf8" });
  assert(developer.status === 0 && existsSync(developer.stdout.trim()),
    "Select an installed Xcode toolchain before running the Swift checks.");

  const root = realpathSync(mkdtempSync(join(tmpdir(), "pi-headless-")));
  const environment = {
    PATH: "/usr/bin:/bin:/usr/sbin:/sbin",
    HOME: root,
    TMPDIR: root,
    SHELL: "/bin/sh",
    LC_ALL: "C",
    GIT_CONFIG_GLOBAL: "/dev/null",
    GIT_CONFIG_NOSYSTEM: "1",
    GIT_TERMINAL_PROMPT: "0",
    ...(process.env.DEVELOPER_DIR && { DEVELOPER_DIR: process.env.DEVELOPER_DIR }),
  };

  async function run(label, executable, args, env = environment) {
    console.log(`\n${label}`);
    const child = spawn(executable, args, { cwd: workspace, env, stdio: ["ignore", "pipe", "pipe"] });
    const outputs = [[child.stdout, process.stdout], [child.stderr, process.stderr]];
    const logs = outputs.map(([source, destination]) => {
      let log = "";
      source.setEncoding("utf8").on("data", chunk => {
        log += chunk;
        destination.write(chunk);
      });
      return () => log;
    });
    const [status, signal] = await once(child, "close");
    if (status !== 0) {
      process.exitCode = status ?? 128 + constants.signals[signal];
      throw new Error(`${label} exited with ${signal ?? status}.`);
    }
    return logs.map(read => read()).join("\n");
  }

  // Select only audited suites. Mixed suites contribute individual data cases.
  const suites = [
    "ComposerDraft", "ConversationFork", "GitWorktree", "ModelRoutingWire", "ModelSettings",
    "PiHistoryDiscovery", "ProjectPathSuggestions", "ProjectSources", "PromptLink", "PromptLinkDestination",
    "QueuedMessage", "SidebarFilter", "StartupDraft", "StopAcknowledgement", "ThreadPullRequest",
    "WorkspaceLayout", "WorktreeDirectory", "WorktreeLaunch",
  ].map(name => name + "Tests");
  const fileCases = ["testLargeTextPagesKeepUTF8AndCRLFBoundaries",
    "testQuotedCSVFieldCanResolveAnAmbiguousDelimiter", "testSQLiteBoundsAndLiveJournalPreserveDatabaseFiles"];
  const filter = `^PiWorkspaceTests\\.(?:(?:${suites.join("|")})/|WorkspaceFilesTests/(?:${fileCases.join("|")})$)`;

  try {
    for (const fixture of ["sidecar", "queued-sidecar", "conversation-fork"]) {
      await run(`Pi ${fixture} fixture`, process.execPath, [`scripts/verify-${fixture}.mjs`]);
    }
    const tap = await run("Pi tool approvals and questions", process.execPath,
      ["--test", "--test-reporter=tap", "Sidecar/tool-approval.test.mjs", "Sidecar/agent-questions.test.mjs"]);
    assert.match(tap, /^# pass [1-9]\d*$/m, "The Node test runner reported no passes.");
    assert.match(tap, /^# skipped 0$/m, "The Node test runner must report zero skips.");
    assert.match(tap, /^# todo 0$/m, "The Node test runner must report zero pending tests.");

    const selectedCommit = join(root, "verify-selected-commit");
    await run("Build the selected commit verifier", "/usr/bin/swiftc",
      ["-module-cache-path", join(root, "module-cache"),
        "Sources/PiWorkspace/GitWorkspace.swift", "scripts/verify-selected-commit.swift", "-o", selectedCommit]);
    await run("Selected commits in disposable checkouts", selectedCommit, []);

    await withModelRoutingFixture(process.execPath, join(sidecar, "worker.mjs"), async fixture => {
      const log = await run("Swift checkout, persistence, file formats, and model routing", "/usr/bin/swift",
        ["test", "--disable-sandbox", "--disable-swift-testing",
          "--only-use-versions-from-resolved-file", "--filter", filter],
        { ...environment, ...fixture });
      assert(!/^Test Case .* skipped\b/m.test(log), "The selected XCTest run reported a skipped test.");
      for (const suite of suites) {
        assert(log.includes(`Test Suite '${suite}' passed`), `XCTest did not report a pass for ${suite}.`);
      }
      for (const test of fileCases) {
        assert(log.includes(` ${test}]' passed`), `XCTest did not report a pass for ${test}.`);
      }
    });
    console.log("\nHeadless verification passed. GUI checks require a separate run.");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}
