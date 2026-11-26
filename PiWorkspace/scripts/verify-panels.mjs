import assert from "node:assert/strict";
import { readFileSync, writeFileSync } from "node:fs";

export async function verifyPreview({ press, visible, tree, setField, until, closeWindow }, baseURL) {
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
  press("browser-undock");
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
  press("toggle-browser");
  await until(() => !tree().includes('id="browser-address"'), "closed reopened preview");
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
  assert(calls.length >= 4 && calls.every(call => call.startsWith(checkout + "|pr ")));
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
