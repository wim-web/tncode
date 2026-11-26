import assert from "node:assert/strict";
import { readFileSync, writeFileSync } from "node:fs";

export async function verifyPreview(driver, baseURL, network) {
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
  press("browser-open-mini");
  await until(() => visible("browser-mini-move") && tree().includes("Preview document 1"), "in-chat Mini Player");
  const player = "browser-mini-player";
  const start = frame(player);
  drag("browser-mini-move", 0.5, 0.5, -64, 0);
  const moved = await until(() => {
    const rect = frame(player);
    return rect[0] < start[0] - 10 && rect;
  }, "dragging the Mini Player from " + start);
  drag(player, 0.99, 0.5, 48, 0);
  const resized = await until(() => {
    const rect = frame(player);
    return rect[2] > moved[2] + 8 && rect;
  }, "resizing the Mini Player from " + moved);
  assert(Math.abs(resized[2] / resized[3] - moved[2] / moved[3]) < 0.05);
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

async function verifyAddressSearch({ press, visible, tree, until, setField, menuItem, key }, baseURL, network) {
  menuItem("Browser Settings…");
  await until(() => visible("browser-search-engine"), "browser settings");
  press("browser-search-engine");
  menuItem("Custom");
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

export async function verifyPullRequests({ press, visible, tree, until }, stateFile, logFile, checkout) {
  press("pull-requests");
  await until(() => visible("pr-row-42"), "pull requests in fixture checkout");
  press("pr-row-42");
  await until(() => tree().includes("fixture-branch") && tree().includes('value="Failure"'), "initial pull request head and failing check");
  writeFileSync(stateFile, "updated\n");
  press("pr-refresh");
  await until(() => tree().includes("new-head") && tree().includes("Update checkout (updated)") && tree().includes('value="Success"'),
              "refreshed pull request head and successful check");
  const calls = readFileSync(logFile, "utf8").trim().split("\n");
  assert(calls.every(call => call.startsWith(checkout + "|")));
  assert(calls.filter(call => call.startsWith(checkout + "|api graphql ")).length >= 2);
  assert(calls.filter(call => call.startsWith(checkout + "|pr view ")).length >= 2);
  assert(visible("pr-open"));
  assert(visible("pr-check-open-0"));
  press("pr-close");
  await until(() => !tree().includes('id="pr-close"'), "closed pull request sheet");
}

export async function setProjectModel({ press, visible, tree, until, setField, closeSettings }, model) {
  press("model-settings");
  await until(() => tree().includes("Inherits Workspace default"), "inherited project settings");
  await setField("model-id", model);
  await closeSettings();
  await until(() => visible("active-model").includes(model), "overridden composer model");
}

export async function resetProjectModel({ press, visible, tree, until, closeSettings }, inheritedModel) {
  press("model-settings");
  await until(() => visible("reset-model-override") && tree().includes("Project override"), "saved project override");
  press("reset-model-override");
  await until(() => tree().includes("Inherits Workspace default"), "reset model inheritance");
  assert(visible("remove-api-key"), "Reset must keep the workspace's shared credential");
  await closeSettings();
  await until(() => visible("active-model").includes(inheritedModel), "restored composer model");
}
