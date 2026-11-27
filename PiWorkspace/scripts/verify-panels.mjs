import assert from "node:assert/strict";
import { once } from "node:events";
import { createServer } from "node:http";
import { randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { verifyIssueLinks } from "./verify-linked-prs.mjs";

export async function verifyBrowserFind(driver, { root, launch, quit, record, keyboard = false }) {
  const { press, dismiss, visible, value, tree, until, setField, focus, keyFor } = driver;
  const contents = new Map([
    ["/first", "<h1>First fixture tab</h1><input id=page-input aria-label='Page input'><p id=a>Lantern</p><p id=b>lantern</p><p id=c>lantern</p>"],
    ["/second", "<h1>Second fixture tab</h1><p id=d>Poppy</p>"],
    ["/replacement", "<h1>Replacement document</h1><p id=e>Daisy</p>"],
  ]);
  const server = createServer((req, res) => {
    if (req.method !== "GET" || !contents.has(req.url)) { res.writeHead(404).end(); return; }
    res.writeHead(200, { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" });
    res.end(contents.get(req.url) + `<p id="proof">Selected element none</p><script>
      document.addEventListener("selectionchange", () => {
        const selection = getSelection();
        const id = selection.toString() && selection.anchorNode?.parentElement?.id;
        const text = "Selected element " + (id || "none");
        const proof = document.getElementById("proof");
        if (proof.textContent !== text) proof.textContent = text;
      });
    </script>`);
  });
  const projectID = randomUUID().toUpperCase(), threadID = randomUUID().toUpperCase();
  const project = join(root, "Project"), index = join(root, "workspace.json"), draft = "Keep this unrelated chat draft.";
  mkdirSync(project, { recursive: true });
  writeFileSync(index, JSON.stringify({ welcomeCompleted: true, selectedProject: projectID,
    projects: [{ id: projectID, path: project, title: "Browser Find", allowEdits: false, selectedConversation: threadID,
      conversations: [{ id: threadID, title: "Draft", isDraft: true, archived: false, composerText: draft }] }],
    model: { provider: "local", model: "browser-find-fixture", endpoint: "http://127.0.0.1:1/v1", contextWindow: 8192 } }), { mode: 0o600 });
  const input = "browser-find-query";
  const selected = id => tree().includes("Selected element " + id);
  const tabIDs = () => Array.from(tree().matchAll(/id="browser-tab-([\dA-F-]+)"/gi), item => item[1]);
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  async function navigate(path, heading) {
    await setField("browser-address", "http://127.0.0.1:" + server.address().port + path);
    press("browser-go");
    await until(() => tree().includes(heading), heading);
  }
  async function query(term, marker) {
    await setField(input, term);
    await until(() => value("browser-find-status").includes("Match found") && selected(marker), "WebKit selected " + marker);
  }
  try {
    await launch("composer", root);
    press("toggle-browser");
    await until(() => visible("browser-address") && tabIDs().length === 1, "first browser tab");
    const first = tabIDs()[0];
    await navigate("/first", "First fixture tab");
    if (keyboard) {
      focus("web-element=page-input");
      keyFor("web-element=page-input", 3, "cmd");
    } else press("browser-find");
    await until(() => visible(input), "Find on page entry");
    await query("lantern", "a");
    if (keyboard) keyFor(input, 36);
    else press("browser-find-next");
    await until(() => selected("b"), "next occurrence in the first tab");
    if (keyboard) keyFor(input, 36, "shift");
    else press("browser-find-previous");
    await until(() => selected("a"), "previous occurrence in the first tab");
    press("browser-new-tab");
    await until(() => visible("browser-new-tab-alternate"), "new tab in the alternate profile");
    dismiss("browser-new-tab-alternate");
    await until(() => tabIDs().length === 2 && !tree().includes('id="' + input + '"'), "second tab has its own Find state");
    await navigate("/second", "Second fixture tab");
    press("browser-find");
    await until(() => visible(input), "Find in the second tab");
    await query("poppy", "d");
    press("browser-tab-" + first);
    await until(() => tree().includes("First fixture tab") && !tree().includes('id="' + input + '"') && selected("none"),
      "switching tabs closed the previous Find and cleared its selection");
    press("browser-find");
    await until(() => value(input).includes('value=""'), "fresh Find on the original page");
    await query("lantern", "a");
    await navigate("/replacement", "Replacement document");
    await until(() => value("browser-find-status").includes("No matches") && visible("browser-find-next").includes("enabled=false"),
      "replacement page cleared the first match");
    await query("Daisy", "e");
    if (keyboard) keyFor(input, 53);
    else dismiss("browser-find-close");
    await until(() => !tree().includes('id="' + input + '"') && selected("none"), "closing Find cleared the selected web text");
    assert(value("composer").includes(JSON.stringify(draft)));
    await quit();
    assert.equal(JSON.parse(readFileSync(index, "utf8")).projects[0].conversations[0].composerText, draft);
    record("WebKit selected a, b, then a on the first page. The other profile selected Poppy in its own document. Switching back closed Find. A fresh search on the first tab reported no matches after navigation, then selected Daisy on the new page. Closing Find cleared the selection and preserved the chat draft.");
    if (keyboard) record("Command-F from the focused web page opened Find. Return and Shift-Return moved its selection, and Escape closed the bar.");
  } finally { server.closeAllConnections(); server.close(); }
}

export async function verifyPreview(driver, baseURL, network, verifyFiles) {
  const { press, visible, tree, setField, until, closeWindow, sizeWindow, frame, drag } = driver;
  const tabIDs = () => Array.from(tree().matchAll(/id="browser-tab-([\dA-F-]+)"/gi), match => match[1]);
  async function newTab(profile) {
    const previous = new Set(tabIDs());
    press("browser-new-tab");
    const item = "browser-new-tab-" + profile;
    await until(() => visible(item), "new tab profile: " + profile);
    press(item);
    return until(() => tabIDs().find(id => !previous.has(id)), "new tab in " + profile);
  }
  async function loadProfilePage(document, visit) {
    await setField("browser-address", baseURL + "/preview/profile");
    press("browser-go");
    await until(() => tree().includes("Preview document " + document) && tree().includes("Profile visit " + visit),
                "document and stored visit count in the selected profile");
  }
  sizeWindow(1080, 748);
  await setField("composer", "Keep this text while previewing.");
  press("toggle-browser");
  for (const name of ["one", "two"]) {
    await until(() => visible("browser-address"), "browser address field");
    await setField("browser-address", baseURL + "/preview/" + name);
    press("browser-go");
    await until(() => tree().includes("Local preview " + name), "WebKit page " + name);
  }
  press("browser-back");
  await until(() => tree().includes("Local preview one"), "back navigation");
  press("browser-forward");
  await until(() => tree().includes("Local preview two"), "forward navigation");
  press("browser-zoom-in");
  await until(() => tree().includes("110%"), "preview zoom");
  press("toggle-browser");
  await until(() => !tree().includes('id="browser-address"'), "hidden preview");
  assert(tree().includes("Keep this text while previewing."));
  press("toggle-browser");
  await until(() => tree().includes("Local preview two") && tree().includes("110%"), "reopened thread preview");
  const [first] = tabIDs();
  assert(first);
  await loadProfilePage(1, 1);
  if (verifyFiles) {
    await verifyFiles();
    await until(() => visible("browser-address") && tree().includes("Preview document 1") && tree().includes("110%"), "live page restored after Files");
  }
  sizeWindow(1220, 850);
  press("browser-open-mini");
  await until(() => visible("browser-mini-move") && tree().includes("Preview document 1"), "in-chat Mini Player");
  const player = "browser-mini-player";
  const start = frame(player);
  drag("browser-mini-move", 0.5, 0.5, -64, 0);
  const moved = await until(() => {
    const rect = frame(player);
    return rect[0] < start[0] - 10 && rect;
  }, "dragging the Mini Player from " + start);
  drag(player, 0.99, 0.5, -40, 0);
  const smaller = await until(() => {
    const rect = frame(player);
    return rect[2] < moved[2] - 8 && rect;
  }, "shrinking the Mini Player from " + moved);
  drag(player, 0.99, 0.5, 40, 0);
  const larger = await until(() => {
    const rect = frame(player);
    return rect[2] > smaller[2] + 8 && rect;
  }, "growing the Mini Player from " + smaller);
  for (const resized of [smaller, larger]) {
    assert(Math.abs(resized[2] / resized[3] - moved[2] / moved[3]) < 0.05);
  }
  assert(tree().includes("Keep this text while previewing."));
  press("browser-mini-dock");
  await until(() => visible("browser-open-mini") && tree().includes("Preview document 1") && tree().includes("110%"), "redocking the Mini Player");
  press("browser-open-mini");
  await until(() => visible("browser-mini-close"), "Mini Player close control");
  press("browser-mini-close");
  await until(() => !tree().includes('id="browser-mini-player"'), "closed in-chat preview");
  press("toggle-browser");
  await until(() => visible("browser-open-mini") && tabIDs().includes(first) && tree().includes("Preview document 1"), "closed Mini Player tab retained");
  press("browser-open-mini");
  await until(() => visible("browser-mini-undock"), "pop-out from the Mini Player");
  press("browser-mini-undock");
  await until(() => visible("browser-floating-window") && visible("browser-dock"), "floating tab");
  press("browser-dock");
  await until(() => visible("browser-undock") && tree().includes("Preview document 1") && tree().includes("110%"), "same live document after docking");

  const alternate = await newTab("alternate");
  await loadProfilePage(2, 1);
  assert(tree().includes("100%"));
  assert(visible("browser-back").includes("enabled=false"));
  const third = await newTab("default");
  await loadProfilePage(3, 2);
  press("browser-close-tab-" + alternate);
  await until(() => {
    const remaining = tabIDs();
    return remaining.length === 2 && remaining.includes(first) && remaining.includes(third);
  }, "closing the middle tab preserves both neighbors");
  press("browser-tab-" + first);
  await until(() => tree().includes("Preview document 1") && tree().includes("110%"), "original tab and zoom");
  assert(visible("browser-back").includes("enabled=true"));
  press("browser-undock");
  await until(() => visible("browser-floating-window"), "floating window before Close");
  closeWindow("browser-floating-window");
  await until(() => !tree().includes('id="browser-dock"'), "closed floating preview");
  press("toggle-browser");
  await until(() => tree().includes("Preview document 1") && tabIDs().includes(third), "closed floating tab retained in its thread");
  assert(tree().includes("Keep this text while previewing."));
  const testing = await newTab("default");
  await verifyPageControls(driver, baseURL, network);
  await verifyAddressSearch(driver, baseURL, network);
  press("browser-close-tab-" + testing);
  await until(() => !tabIDs().includes(testing), "closed navigation test tab");
  press("toggle-browser");
  await until(() => !tree().includes('id="browser-address"'), "closed reopened preview");
}

async function verifyAddressSearch({ press, visible, tree, until, setField, menuItem, pick, key }, baseURL, network) {
  menuItem("Browser Settings…");
  await until(() => visible("browser-search-engine"), "browser settings");
  pick("browser-search-engine", "Custom");
  await until(() => visible("browser-custom-search-url"), "custom search URL");
  await setField("browser-custom-search-url", baseURL + "/preview/search");
  assert(visible("browser-settings-save").includes("enabled=false"));
  assert(visible("browser-search-url-validation"));
  await setField("browser-custom-search-url", baseURL + "/preview/search?q=%s");
  press("browser-settings-save");
  await until(() => !tree().includes('id="browser-settings-save"'), "saved search settings");
  await setField("browser-address", new URL(baseURL).host + "/preview/one");
  key(36);
  await until(() => tree().includes("Local preview one"), "Enter navigates a bare loopback host");
  const query = "fixture café & #/?+%";
  await setField("browser-address", query);
  assert.equal(network.queries.length, 0);
  key(36);
  await until(() => tree().includes("Search arrived"), "search using the custom engine");
  assert.deepEqual(network.queries, [query]);
  await setField("browser-address", "file:///fixture");
  press("browser-go");
  await until(() => visible("browser-error") && tree().includes("Search arrived"), "invalid scheme keeps the current page");
}

async function verifyPageControls({ press, visible, tree, until, setField, webFrame }, baseURL, network) {
  async function go(path) {
    await setField("browser-address", baseURL + path);
    press("browser-go");
  }
  await go("/preview/revision");
  await until(() => tree().includes("Page revision 1"), "original page revision");
  const original = webFrame("zoom-marker");
  const widthAt = zoom => {
    const width = webFrame("zoom-marker")[2];
    return Math.abs(width - original[2] * zoom) <= 1;
  };
  press("browser-zoom-in");
  await until(() => tree().includes("110%") && widthAt(1.1), "zoomed-in HTML button");
  press("browser-zoom-out");
  press("browser-zoom-out");
  await until(() => tree().includes("90%") && widthAt(0.9), "zoomed-out HTML button");
  press("browser-reset-zoom");
  await until(() => tree().includes("100%") && widthAt(1), "reset HTML button");
  press("browser-reload");
  await until(() => tree().includes("Page revision 2"), "fresh content after Reload");
  await go("/preview/delayed");
  await until(() => network.delayedRequests > 0 && visible("browser-reload").includes("Stop Loading"), "in-flight page");
  press("browser-reload");
  await until(() => network.cancelledRequests > 0 && visible("browser-reload").includes("Reload"), "cancelled page request");
  network.releaseDelayed = true;
  press("browser-reload");
  await until(() => tree().includes("Released page"), "reload after Stop");
  await go("/preview/unreachable");
  await until(() => visible("browser-error-details"), "unreachable site");
  press("browser-error-details");
  await until(() => visible("browser-error-code") && tree().includes(baseURL + "/preview/unreachable"), "failed URL and native error details");
  network.recovered = true;
  press("browser-error-reload");
  await until(() => tree().includes("Server recovered") && !tree().includes('id="browser-error-details"'), "repaired server");
}

export async function verifyCheckLog({ press, dismiss, visible, tree, until }, stateFile, logFile, checkout) {
  writeFileSync(stateFile, "check-logs-denied\n");
  press("pr-refresh");
  await until(() => visible("pr-check-log-1"), "failed Actions job log");
  press("pr-check-log-1");
  await until(() => tree().includes("denied access") && visible("pr-check-log-retry"), "job log permission error");
  writeFileSync(stateFile, "check-logs\n");
  press("pr-check-log-retry");
  await until(() => visible("pr-check-log-text") && tree().includes("ONLY-TESTS-61002"), "the selected job's line after retry");
  assert(!tree().includes("ONLY-LINT"), "A different job supplied the log.");
  const log = readFileSync(logFile, "utf8").split("\n").filter(line => line.includes("actions/jobs/61002/logs"));
  assert(log.length >= 2 && log.every(line => line.startsWith(realpathSync(checkout) + "|")));
  dismiss("pr-check-log-back");
  await until(() => visible("pr-check-log-1") && !tree().includes('id="pr-check-log-text"'), "back to the PR checks");
}

export async function verifyPRCode({ press, visible, value, tree, until }, stateFile, logFile, checkout) {
  writeFileSync(stateFile, "files-denied\n");
  press("pr-tab-code");
  await until(() => visible("pr-files-retry") && value("pr-files-error").includes("denied access"), "denied PR file list");
  writeFileSync(stateFile, "files-many\n");
  press("pr-files-retry");
  await until(() => visible("pr-file-row-0"), "PR files after retry");
  press("pr-file-row-0");
  await until(() => value("pr-file-diff-text").includes("+FORGE-CHECKOUT"), "forge patch for the selected path");
  press("pr-file-row-1");
  await until(() => value("pr-file-diff-previous-path").includes("docs/old guide.md") &&
                    value("pr-file-diff-text").includes("+FORGE-GUIDE"), "renamed file and its own patch");
  press("pr-file-row-2");
  await until(() => visible("pr-file-diff-unavailable") && !tree().includes('id="pr-file-diff-text"'), "binary selection clears the previous patch");
  press("pr-files-load-more");
  await until(() => value("pr-files-count").includes("31 of 31"), "second page of PR files");
  writeFileSync(stateFile, "files-stale\n");
  press("pr-file-row-0");
  await until(() => visible("pr-files-refresh") && !tree().includes('id="pr-file-diff-text"'), "changed head clears the selected patch");
  press("pr-files-refresh");
  await until(() => value("pr-files-count").includes("7 of 7"), "current head file list after refresh");
  const reads = readFileSync(logFile, "utf8").split("\n").filter(s => s.includes("/pulls/42/files?"));
  assert(reads.length >= 2 && reads.every(s => s.startsWith(realpathSync(checkout) + "|")));
  writeFileSync(stateFile, "initial\n");
  press("pr-tab-summary");
  await until(() => value("pr-detail-title").includes("#42"), "the same PR summary");
}

export async function verifyPRFilesCheckout(driver, { directory, project, workspace, git, launch, quit, record, forgeState, forgeLog }) {
  const { press, dismiss, value, visible, until } = driver;
  const checkout = join(directory, "PR checkout");
  git(project, "worktree", "add", "-b", "review", checkout);
  const projectID = randomUUID().toUpperCase(), threadID = randomUUID().toUpperCase();
  const indexPath = join(workspace, "workspace.json");
  writeFileSync(indexPath, JSON.stringify({ welcomeCompleted: true, selectedProject: projectID,
    projects: [{ id: projectID, title: "PR workspace", path: project, allowEdits: false, selectedConversation: threadID,
      conversations: [{ id: threadID, title: "PR draft", archived: false, isDraft: true, composerText: "Keep the PR draft.",
        location: { worktree: { path: checkout, base: "main" } } }] }],
    model: { provider: "local", model: "unused-pr-model", endpoint: "http://127.0.0.1:1/v1", contextWindow: 8192 },
  }), { mode: 0o600 });
  const gitState = () => [project, checkout].map(cwd => [git(cwd, "rev-parse", "HEAD"), git(cwd, "diff"), git(cwd, "diff", "--cached")]);
  const before = gitState();
  writeFileSync(forgeState, "check-logs-denied\n");
  await launch("pull-requests");
  press("pull-requests");
  await until(() => visible("pr-row-42"), "PR list in the selected worktree");
  press("pr-row-42");
  await until(() => visible("pr-check-log-1"), "checks for the selected PR");
  await verifyCheckLog(driver, forgeState, forgeLog, checkout);
  await verifyPRCode(driver, forgeState, forgeLog, checkout);
  await verifyIssueLinks(driver, { conversation: () => JSON.parse(readFileSync(indexPath)).projects[0].conversations[0], quit, launch });
  dismiss("pr-close");
  await until(() => value("composer").includes("Keep the PR draft."), "unchanged composer after closing the PR");
  await quit();
  assert.deepEqual(gitState(), before);
  assert.equal(JSON.parse(readFileSync(indexPath)).projects[0].selectedConversation, threadID);
  record("PR #42's denied check log recovered to job 61002 in the linked checkout. Code displayed the right file and rename patches, cleared the prior patch for binary content, loaded all 31 paths and refreshed after a changed head. Both checkouts and the draft were preserved.");
  record("Issues linked from Details and from Linked items reopened after relaunch. Wrong-repository and duplicate input kept the existing links. Copy gave the issue URL; unlink preserved the other issue and the same-number fixture PR.");
}

export async function verifyPullRequests(driver, stateFile, logFile, checkout) {
  const { press, visible, tree, until, setField, pick } = driver;
  const checkoutPrefix = realpathSync(checkout) + "|";
  press("pull-requests");
  await until(() => visible("pr-row-42"), "pull requests in fixture checkout");
  press("pr-row-42");
  await until(() => tree().includes("fixture-branch") && tree().includes('value="Failure"'), "initial pull request head and failing check");
  await verifyCheckLog(driver, stateFile, logFile, checkout);
  await verifyPRCode(driver, stateFile, logFile, checkout);
  writeFileSync(stateFile, "updated\n");
  press("pr-refresh");
  await until(() => tree().includes("new-head") && tree().includes("Update checkout (updated)") && tree().includes('value="Success"'),
              "refreshed pull request head and successful check");
  const calls = readFileSync(logFile, "utf8").trim().split("\n");
  assert(calls.every(call => call.startsWith(checkoutPrefix)));
  assert(calls.filter(call => call.startsWith(checkoutPrefix + "api graphql ")).length >= 2);
  assert(calls.filter(call => call.startsWith(checkoutPrefix + "pr view ")).length >= 2);
  assert(visible("pr-open"));
  assert(visible("pr-check-open-0"));
  writeFileSync(stateFile, "initial\n");
  await verifyPullRequestChoices(driver);
  async function search(prefix, text) {
    await setField(prefix + "-search", text);
    press(prefix + "-search-submit");
  }
  await search("pr", "label:bug");
  await until(() => visible("pr-row-42") && !tree().includes('id="pr-row-43"') && visible("pr-load-more"), "PRs filtered by label");
  writeFileSync(stateFile, "page-error\n");
  press("pr-load-more");
  await until(() => visible("pr-page-retry") && visible("pr-row-42"), "retry page without clearing first PR");
  writeFileSync(stateFile, "initial\n");
  press("pr-page-retry");
  await until(() => visible("pr-row-44") && tree().match(/id="pr-row-42"/g)?.length === 1, "distinct second PR page");
  press("github-tab-issues");
  await until(() => visible("issue-row-71") && visible("issue-row-72"), "checkout Issues");
  await search("issue", "label:bug");
  await until(() => visible("issue-row-71") && visible("issue-load-more") && !tree().includes('id="issue-row-72"'), "filtered issues");
  press("issue-load-more");
  await until(() => visible("issue-row-73"), "second issue page");
  press("issue-row-71");
  await until(() => tree().includes("Fixture issue description.") && tree().includes("fixture-reporter") && visible("issue-open"), "reported issue detail");
  writeFileSync(stateFile, "updated\n");
  press("issue-refresh");
  await until(() => tree().includes("Updated fixture issue description."), "refresh changes selected issue details");
  writeFileSync(stateFile, "missing\n");
  press("issue-detail-refresh");
  await until(() => visible("issue-detail-error") && visible("issue-detail-retry"), "missing issue");
  writeFileSync(stateFile, "initial\n");
  press("issue-detail-retry");
  await until(() => tree().includes("Fixture issue description."), "issue detail recovered");
  pick("issue-filter", "Closed");
  await until(() => visible("issue-row-70") && !tree().includes('id="issue-row-71"'), "closed issues by label");
  pick("issue-filter", "Open");
  await search("issue", "empty");
  await until(() => visible("issue-list-empty") && visible("issue-search-clear"), "empty issue search");
  press("issue-search-clear");
  await until(() => visible("issue-row-72"), "clear issue search");
  writeFileSync(stateFile, "no-auth\n");
  press("issue-refresh");
  await until(() => visible("issue-list-retry"), "signed out read");
  writeFileSync(stateFile, "initial\n");
  press("issue-list-retry");
  await until(() => visible("issue-row-71"), "issue list recovered");
  const allCalls = readFileSync(logFile, "utf8").trim().split("\n");
  assert(allCalls.every(call => call.startsWith(checkoutPrefix)));
  assert(allCalls.some(call => call.includes("|issue view 71 ")));
  assert(allCalls.some(call => call.includes("after=issue-search:2==")));
  assert(allCalls.some(call => call.includes("after=pull-requests:2==")));
  press("pr-close");
  await until(() => !tree().includes('id="pr-close"'), "closed pull request sheet");
}

async function verifyPullRequestChoices({ press, visible, value, tree, until, setField, pick, focus, keyFor, popoverFrame, activate }) {
  const row = n => tree().includes('id="pr-row-' + n + '"');
  async function prepareChoices(kind, prepare) {
    const search = "pr-" + kind + "-search";
    const presented = () => tree().includes('id="' + search + '"');
    for (let attempt = 0; attempt < 3; attempt++) {
      try {
        if (!presented()) {
          if (attempt > 0) activate();
          press("pr-" + kind + "-filter");
        }
        const size = await until(() => {
          const frame = popoverFrame(search).slice(2);
          return frame.every(n => n > 0) && frame;
        }, "native " + kind + " popover", 2500);
        if (!visible(search).includes("focused=true")) focus(search);
        await prepare(size);
        return;
      } catch (error) {
        if (attempt === 2 || presented()) throw error;
      }
    }
  }
  pick("pr-filter", "All");
  await until(() => row(41) && row(42) && row(43), "three PRs with different authors and labels");
  await prepareChoices("author", async size => {
    await setField("pr-author-search", "no-such-fixture-author");
    await until(() => visible("pr-author-options-empty"), "empty author options", 3500);
    assert.deepEqual(popoverFrame("pr-author-search").slice(2), size);
    await setField("pr-author-search", "fixture-author");
    await until(() => visible("pr-author-option-fixture-author"), "matching checkout author", 3500);
    assert.deepEqual(popoverFrame("pr-author-search").slice(2), size);
  });
  press("pr-author-option-fixture-author");
  await until(() => row(42) && !row(41) && !row(43) && value("pr-author-filter").includes("fixture-author"),
              "only the selected author's PR");
  await prepareChoices("author", () => until(() => visible("pr-author-anyone"), "clear the author selection", 3500));
  press("pr-author-anyone");
  await until(() => row(41) && row(42) && row(43), "Anyone restores all authors");
  await prepareChoices("label", async () => {
    await setField("pr-label-search", "bug");
    await until(() => visible("pr-label-option-bug"), "search returned the bug label", 3500);
  });
  press("pr-label-option-bug");
  await until(() => row(42) && !row(41) && value("pr-label-filter").includes("1 selected"), "unlabeled PR excluded");
  await prepareChoices("label", () => until(() => visible("pr-label-clear"), "clear the selected label", 3500));
  press("pr-label-clear");
  await until(() => row(41) && row(42) && row(43), "Clear labels restores all PRs");
  await prepareChoices("label", () => until(() => visible("pr-label-search").includes("focused=true"), "label keyboard focus", 3500));
  keyFor("pr-label-search", 53);
  await until(() => !tree().includes('id="pr-label-search"'), "closed label choices");
  pick("pr-filter", "Open");
  await until(() => row(42) && !row(41), "open PR scope restored");
}

export async function setProjectModel({ openModelSettings, visible, tree, until, setField, closeSettings }, model) {
  await openModelSettings();
  await until(() => tree().includes("Inherits Workspace default"), "inherited project settings");
  await setField("model-id", model);
  await closeSettings();
  await until(() => visible("active-model").includes(model), "overridden composer model");
}

export async function resetProjectModel({ openModelSettings, press, visible, tree, until, closeSettings }, inheritedModel) {
  await openModelSettings();
  await until(() => visible("reset-model-override") && tree().includes("Project override"), "saved project override");
  press("reset-model-override");
  await until(() => tree().includes("Inherits Workspace default"), "reset model inheritance");
  assert(visible("remove-api-key"), "Reset must keep the workspace's shared credential");
  await closeSettings();
  await until(() => visible("active-model").includes(inheritedModel), "restored composer model");
}
