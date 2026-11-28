import { existsSync, readdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { basename, dirname, join, relative } from "node:path";

const [resources, nodeBinary] = process.argv.slice(2);
const entries = [];
const noticeName = /^(?:licen[cs]e|copying|copyright(?:notice)?|notice|third[-_ ]party[-_ ](?:licen[cs]es|notices))(?:$|[._ -])/i;

function json(path) {
  return JSON.parse(readFileSync(path, "utf8"));
}

function textFile(path, file = basename(path)) {
  const text = readFileSync(path, "utf8");
  return text.trim() ? [{ file, text }] : [];
}

function noticeFiles(root, dir = root, noticeFolder = false) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((item) => {
    const path = join(dir, item.name);
    const isNotice = noticeFolder || noticeName.test(item.name);
    if (item.isDirectory() && item.name !== "node_modules") {
      return noticeFiles(root, path, isNotice);
    }
    return item.isFile() && isNotice ? textFile(path, relative(root, path)) : [];
  });
}

function installedPackages(root, dir = root) {
  if (!existsSync(dir)) return;
  for (const item of readdirSync(dir, { withFileTypes: true })) {
    if (!item.isDirectory() || item.name.startsWith(".")) continue;
    const path = join(dir, item.name);
    if (item.name.startsWith("@")) {
      installedPackages(root, path);
      continue;
    }
    const metadata = join(path, "package.json");
    if (existsSync(metadata)) {
      const { name, version, license } = json(metadata);
      entries.push({
        id: relative(root, path), name, version,
        license: typeof license === "string" ? license : license?.type,
        texts: noticeFiles(path).sort((a, b) => a.file.localeCompare(b.file)),
      });
    }
    installedPackages(root, join(path, "node_modules"));
  }
}

// SwiftTerm is the macOS app's linked Swift package. Other pins are for
// SwiftTerm's tools and platform-conditional targets.
const swiftTerm = json("Package.resolved").pins.find(({ identity }) => identity === "swiftterm");
const swiftLicense = ".build/checkouts/SwiftTerm/LICENSE";
entries.push({
  id: "swiftterm", name: "SwiftTerm", version: swiftTerm?.state.version,
  texts: existsSync(swiftLicense) ? textFile(swiftLicense) : [],
});

// The interface follows T3 Code's design and reuses its English and Japanese copy.
entries.push({
  id: "t3code", name: "T3 Code", version: "0.1.12", license: "MIT",
  texts: textFile("ThirdPartyNotices/T3-Code.txt", "LICENSE"),
});

const nodeLicense = join(dirname(realpathSync(nodeBinary)), "..", "LICENSE");
entries.push({
  id: "node", name: "Node.js", version: process.versions.node,
  texts: existsSync(nodeLicense) ? textFile(nodeLicense) : [],
});

installedPackages(join(resources, "Sidecar", "node_modules"));
entries.sort((a, b) => a.name.localeCompare(b.name) || a.id.localeCompare(b.id));
writeFileSync(join(resources, "ThirdPartyNotices.json"), JSON.stringify(entries) + "\n");
