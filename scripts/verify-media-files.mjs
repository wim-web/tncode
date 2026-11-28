import assert from "node:assert/strict";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { images } from "./fixtures/attachments.mjs";

function fixturePDF() {
  const pages = ["First checkout page", "Searchable parcel on page two"];
  const objects = [
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
    ...pages.map((_, i) => "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Resources << /Font << /F1 5 0 R >> >> /Contents " + (6 + i) + " 0 R >>"),
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ...pages.map(text => {
      const stream = "BT /F1 14 Tf 24 350 Td (" + text + ") Tj ET\n";
      return "<< /Length " + stream.length + " >>\nstream\n" + stream + "endstream";
    }),
  ];
  let pdf = "%PDF-1.4\n";
  const offsets = [];
  for (const [i, object] of objects.entries()) {
    offsets.push(pdf.length);
    pdf += (i + 1) + " 0 obj\n" + object + "\nendobj\n";
  }
  const xref = pdf.length;
  pdf += "xref\n0 " + (objects.length + 1) + "\n0000000000 65535 f \n";
  for (const offset of offsets) pdf += String(offset).padStart(10, "0") + " 00000 n \n";
  return Buffer.from(pdf + "trailer\n<< /Root 1 0 R /Size " + (objects.length + 1) + " >>\nstartxref\n" + xref + "\n%%EOF\n", "ascii");
}

export async function verifyMediaFiles({ press, dismiss, visible, value, tree, until, setField }, checkout) {
  const image = join(checkout, "color-sample.png");
  const pdf = join(checkout, "sample-pages.pdf");
  const original = fixturePDF();
  writeFileSync(image, Buffer.from(images.blue, "base64"));
  writeFileSync(pdf, "incomplete PDF");
  dismiss("files-refresh");
  await until(() => visible("files-row-color-sample.png") && visible("files-row-sample-pages.pdf"), "refreshed media fixtures");
  press("files-row-color-sample.png");
  await until(() => value("files-image-dimensions").includes("2 × 2"), "decoded image dimensions");
  press("files-image-actual-size");
  await until(() => value("files-image-zoom").includes("100%"), "actual pixel size");
  press("files-image-zoom-in");
  await until(() => value("files-image-zoom").includes("125%"), "zoomed image");
  press("files-image-zoom-out");
  await until(() => value("files-image-zoom").includes("100%"), "image zoom out");
  press("files-image-fit");
  press("files-image-expand");
  await until(() => visible("files-image-expanded"), "expanded checkout image");
  dismiss("files-image-close-expanded");
  await until(() => !tree().includes('id="files-image-expanded"'), "closed expanded image");
  press("files-close-preview");

  press("files-row-sample-pages.pdf");
  await until(() => visible("files-preview-error") && visible("files-preview-retry"), "invalid PDF recovery");
  writeFileSync(pdf, original);
  dismiss("files-preview-retry");
  await until(() => value("files-pdf-page").includes("1 / 2 pages"), "first decoded PDF page");
  press("files-pdf-next-page");
  await until(() => value("files-pdf-page").includes("2 / 2 pages"), "second PDF page");
  press("files-pdf-previous-page");
  await until(() => value("files-pdf-page").includes("1 / 2 pages"), "first PDF page again");
  press("files-pdf-zoom-in");
  await until(() => value("files-pdf-zoom").includes("%"), "explicit PDF zoom");
  press("files-pdf-fit");
  await until(() => value("files-pdf-zoom").includes("Fit width"), "PDF fit width");
  await setField("files-pdf-find", "Searchable parcel");
  await until(() => value("files-pdf-find-results").includes("1/1") && value("files-pdf-page").includes("2 / 2 pages"),
              "PDF match in the second page");
  dismiss("files-pdf-save");
  await until(() => visible("CancelButton"), "native PDF save dialog");
  dismiss("CancelButton");
  await until(() => visible("files-pdf-find") && !tree().includes('id="CancelButton"'), "cancel PDF export");
  assert.deepEqual(readFileSync(pdf), original);
  press("files-close-preview");
}
