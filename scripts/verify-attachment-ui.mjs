import assert from "node:assert/strict";
import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { images, note } from "./fixtures/attachments.mjs";

export async function verifyAttachmentUI(driver, { workspace, checkout, conversation, targets, quit, launch }) {
  const { press, visible, until, selectPath, tree } = driver;
  const attachments = () => conversation().composerAttachments ?? [];
  const before = targets.length;
  async function choose(name, replacementID) {
    const original = new Set(attachments().map(a => a.id));
    press(replacementID ? "reattach-attachment-" + replacementID : "attach-files");
    await until(() => visible("open-panel"), "native attachment picker");
    const path = join(checkout, name);
    await until(() => { selectPath(path); return true; }, "fixture file " + path);
    await until(() => visible("OKButton").includes("enabled=true"), "file selection enabled");
    driver.dismiss("OKButton");
    return until(() => attachments().find(a => a.name === name && a.payload &&
                           (replacementID ? a.id === replacementID : !original.has(a.id))), "attachment restored from " + name);
  }
  async function preview(id) {
    press("preview-attachment-" + id);
    await until(() => visible("expanded-attachment-" + id), "expanded preview for the selected image");
    driver.dismiss("close-image-preview");
    await until(() => !tree().includes('id="close-image-preview"'), "close image preview");
  }
  writeFileSync(join(checkout, "note.txt"), note);
  press("attach-files");
  await until(() => visible("open-panel"), "attachment picker to cancel");
  driver.dismiss("CancelButton");
  await until(() => !tree().includes('id="open-panel"'), "cancel without attaching");
  assert.equal(attachments().length, 0);
  const imagePath = join(checkout, "same.png");
  const picked = {};
  for (const [color, bytes] of Object.entries(images)) {
    writeFileSync(imagePath, Buffer.from(bytes, "base64"), { flag: "wx" });
    picked[color] = await choose("same.png");
    mkdirSync(join(checkout, color));
    renameSync(imagePath, join(checkout, color, "same.png"));
  }
  const { red, blue } = picked;
  const text = await choose("note.txt");
  assert.notEqual(red.id, blue.id);
  assert.equal(red.payload.data, images.red);
  assert.equal(blue.payload.data, images.blue);
  await quit();
  const indexPath = join(workspace, "workspace.json");
  const saved = JSON.parse(readFileSync(indexPath, "utf8"));
  const original = saved.projects.flatMap(p => p.conversations).find(t => t.id === conversation().id);
  delete original.composerAttachments.find(a => a.id === red.id).payload;
  writeFileSync(indexPath, JSON.stringify(saved));
  await launch();
  await until(() => visible("reattach-attachment-" + red.id) && visible("send-message").includes("enabled=false"),
              "unavailable attachment blocks submission");
  renameSync(join(checkout, "red", "same.png"), imagePath);
  const repaired = await choose("same.png", red.id);
  assert.equal(repaired.payload.data, images.red);
  assert.deepEqual(attachments().map(a => a.id), [red.id, blue.id, text.id]);
  await preview(red.id);
  await preview(blue.id);
  driver.dismiss("remove-attachment-" + red.id);
  await until(() => attachments().length === 2 && !attachments().some(a => a.id === red.id), "remove only red");
  await quit();
  await launch();
  await until(() => visible("preview-attachment-" + blue.id) && visible("composer-attachment-" + text.id),
              "draft with blue image and text after relaunch");
  assert.equal(targets.length, before);
  await until(() => visible("send-message").includes("enabled=true"), "send enabled for an attachment-only draft");
  press("send-message");
  await until(() => targets.length === before + 1 && targets.at(-1).completed && visible("sent-attachment-" + blue.id) &&
                    visible("sent-attachment-" + text.id) && !attachments().length, "two attachment names in the transcript");
  const parts = targets.at(-1).body.messages.findLast(m => m.role === "user").content;
  assert.deepEqual(parts.filter(p => p.type === "image_url").map(p => p.image_url.url), ["data:image/png;base64," + images.blue]);
  assert.equal(parts.filter(p => p.type === "text").map(p => p.text).join(""), 'Attached text file "note.txt":\n' + note);
  assert(!tree().includes("sent-attachment-" + red.id));
}
