import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { images } from "./fixtures/attachments.mjs";

export async function verifyChatImages(driver, { root, endpoint, key, credential, removeFixtureCredential, launch, quit, targets, record }) {
  const { press, dismiss, until, visible, tree, keyFor, showMenu, checkImage } = driver;
  const uuid = () => randomUUID().toUpperCase();
  const image = color => ({ id: uuid(), name: "same.png", payload: { mimeType: "image/png", data: images[color] } });
  const red = image("red"), blue = image("blue"), queued = image("red");
  const note = { id: uuid(), name: "note.txt", payload: { mimeType: "text/plain", data: Buffer.from("Local gallery note.").toString("base64") } };
  const p = uuid(), draft = uuid(), other = uuid(), item = uuid();
  const project = join(root, "Project"), indexPath = join(root, "workspace.json");
  mkdirSync(project, { recursive: true });
  writeFileSync(indexPath, JSON.stringify({ selectedProject: p, welcomeCompleted: true, projects: [{ id: p, title: "Gallery",
    path: project, allowEdits: false, selectedConversation: draft, conversations: [
      { id: draft, title: "Send images", isDraft: true, archived: false, composerText: "Original caption", composerAttachments: [red, note, blue] },
      { id: other, title: "Queue fixture", isDraft: true, archived: false, composerText: "Keep queued draft", queuedMessages: [
        { id: item, text: "Wait before sending", attachments: [queued] }] },
    ] }], model: { provider: "local", model: "fixture-model", endpoint, contextWindow: 8192, localImages: true },
  }), { mode: 0o600 });
  const has = id => tree().includes('id="' + id + '"');
  const expanded = attachment => "expanded-attachment-" + attachment.id;
  async function copyPixel(attachment, color) {
    await until(() => visible(expanded(attachment)), "visible " + color + " image");
    await until(() => { showMenu(expanded(attachment)); return true; }, "image context menu");
    await until(() => visible("copy-preview-image"), "Copy Image");
    dismiss("copy-preview-image");
    await until(() => checkImage(images[color]), "copied the exact " + color + " PNG");
  }
  async function gallery(prefix) {
    const opener = prefix + red.id;
    press(opener);
    await until(() => visible(expanded(red)) && visible("previous-image-preview"), "opened the first of two images");
    press("previous-image-preview");
    await copyPixel(blue, "blue");
    press("next-image-preview");
    await copyPixel(red, "red");
    dismiss("close-image-preview");
    await until(() => !has("attachment-image-preview") && visible(opener).includes("focused=true"), "return focus to original thumbnail");
  }
  credential("--set-api-key-from-stdin", key, root);
  try {
    await launch("model-settings", root);
    await gallery("preview-attachment-");
    press("thread-row-" + other);
    const queuedOpener = "preview-queued-attachment-" + item + "-" + queued.id;
    await until(() => visible(queuedOpener), "image in a separate queue");
    press(queuedOpener);
    await until(() => visible(expanded(queued)) && !has("next-image-preview"), "single image is scoped to its queued message");
    await until(() => visible("close-image-preview").includes("focused=true"), "image dialog keyboard focus");
    keyFor("close-image-preview", 53);
    await until(() => !has("attachment-image-preview") && visible(queuedOpener).includes("focused=true"), "Escape returns to the queued opener");
    press("thread-row-" + draft);
    await until(() => visible("send-message").includes("enabled=true"), "original image draft can send");
    press("send-message");
    await until(() => targets.length === 1 && targets[0].completed && visible("sent-attachment-" + blue.id), "one model submission");
    const user = targets[0].body.messages.findLast(message => message.role === "user");
    assert.deepEqual(user.content.filter(part => part.type === "image_url").map(part => part.image_url.url),
                     [images.red, images.blue].map(bytes => "data:image/png;base64," + bytes));
    await quit();
    await launch("model-settings", root);
    if (!has("sent-attachment-" + red.id)) press("thread-row-" + draft);
    await until(() => visible("sent-attachment-" + red.id), "saved Pi images after relaunch");
    await gallery("sent-attachment-");
    const saved = JSON.parse(readFileSync(indexPath, "utf8")).projects[0].conversations.find(thread => thread.id === other);
    assert.equal(saved.composerText, "Keep queued draft");
    assert.deepEqual(saved.queuedMessages[0].attachments, [queued]);
    assert.equal(targets.length, 1);
    await quit();
    record("Two same-named images wrapped in the draft and in the reopened Pi message. Copy Image yielded the expected red and blue pixels from each view. The text attachment was skipped. The separate queued image had no next control and Escape returned to its own opener.");
  } finally {
    removeFixtureCredential(root, "local:" + endpoint);
  }
}
