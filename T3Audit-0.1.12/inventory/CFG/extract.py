#!/usr/bin/env python3
"""Extract the pinned registry and verify the CFG inventory with Python 3.9+."""
import argparse
import csv
import re
import subprocess
from collections import Counter
from functools import cached_property
from pathlib import Path

SLICE = Path(__file__).resolve().parent
SOURCE = SLICE.parents[1] / ".source"
REVISION = "ca81b7b97a1c4b91e5ac25768d0f6629f37732fd"
UI = "apps/web/src/components/settings/"
ROUTES = "apps/web/src/routes/"
SEARCH = UI + "settingsSearch.ts"
SETTINGS = "packages/contracts/src/settings.ts"
DESKTOP = "apps/desktop/src/settings/DesktopAppSettings.ts"
FLAGS = "packages/shared/src/FeatureFlags.ts"
FEATURE_HEADER = "id title preconditions entry action intermediate success recovery effects source gate acceptance".split()
ENTRY_HEADER = "id kind name source feature_id".split()


class Checkout:
    def __init__(self, root):
        self.root = root
        self.files = {}

    def lines(self, path):
        if path not in self.files:
            self.files[path] = (self.root / path).read_text(encoding="utf-8").splitlines()
        return self.files[path]

    def ref(self, path, pattern, start=1):
        for index, line in enumerate(self.lines(path)[start - 1:], start):
            if pattern in line:
                return f"{path}:{index}"
        raise ValueError(f"Missing source marker {path} {pattern!r}")

    def block(self, path, start, end):
        lines = self.lines(path)
        n = next(i for i, line in enumerate(lines) if line.startswith(start))
        finish = next(i for i, line in enumerate(lines[n + 1:], n + 1) if line.startswith(end))
        return n + 2, "\n".join(lines[n + 1:finish])

    @cached_property
    def search(self):
        start, block = self.block(SEARCH, "export const SETTINGS_SEARCH_ITEMS", "] as const")
        records = {}
        for match in re.finditer(r'^  \{\n(?:    //[^\n]*\n)*    id: "([^"]+)",(.*?)^  \},?', block, re.M | re.S):
            fields = match[2]

            def get(pattern):
                found = re.search(pattern, fields)
                return found[1] if found else ""

            route = get(r'to: "([^"]+)"')
            title = get(r'title: msg\(\s*"([^"]+)"')
            assert route and title, match[1]
            line = start + block.count("\n", 0, match.start(1))
            records[match[1]] = {
                "title": title, "route": route, "ref": f"{SEARCH}:{line}",
                "search_scope": get(r'scope: "([^"]+)"'),
                "target": get(r'targetId: "([^"]+)"') or match[1],
                "filters": re.findall(r'^    (\w+): true,', fields, re.M),
            }
        assert len(records) == len(re.findall(r'^    id: "', block, re.M))
        return records

    @cached_property
    def routes(self):
        return {
            self.lines(path)[int(ref.rsplit(":", 1)[1]) - 1].split('"/_chat')[1].split('"')[0]: ref
            for p in sorted((self.root / ROUTES).glob("_chat.settings*.tsx"))
            for path in [p.relative_to(self.root).as_posix()]
            for ref in [self.ref(path, 'createFileRoute("/_chat/settings')]
        }

    @cached_property
    def labels(self):
        _, block = self.block(SEARCH, "export const SETTINGS_SECTION_LABELS", "};")
        return dict(re.findall(r'  "([^"]+)": msg\("([^"]+)"', block))

    @cached_property
    def project_keys(self):
        _, block = self.block(SETTINGS, "export const PROJECT_SCOPED_SERVER_SETTING_KEYS", "] as const")
        return set(re.findall(r'"(\w+)"', block))

    @cached_property
    def shared_keys(self):
        path = "packages/client-runtime/src/state/sharedSettings.ts"
        _, block = self.block(path, "const SHARED_SERVER_SETTING_KEYS", "] as const")
        return set(re.findall(r'"(\w+)"', block))

    @cached_property
    def schema(self):
        data = {}
        for namespace, path, start, end in [
            ("client", SETTINGS, "export const ClientSettingsSchema =", "});"),
            ("server", SETTINGS, "export const ServerSettings =", "});"),
            ("desktop", DESKTOP, "export const DEFAULT_DESKTOP_SETTINGS", "};"),
        ]:
            line, block = self.block(path, start, end)
            matches = list(re.finditer(r'^  (\w+): (.+)', block, re.M))
            for index, match in enumerate(matches):
                limit = matches[index + 1].start() if index + 1 < len(matches) else len(block)
                declaration = block[match.start():limit].split("\n  //")[0].strip()
                default_match = re.search(r'Effect.succeed\(([^()\n]+?)(?: as const)?\)', declaration)
                if namespace == "desktop":
                    default = match[2].rstrip(",")
                elif default_match:
                    default = default_match[1]
                else:
                    default = ""
                ref = f"{path}:{line + block.count(chr(10), 0, match.start())}"
                data[f"{namespace}:{match[1]}"] = (ref, default, declaration)
        return data

    @cached_property
    def render_anchors(self):
        anchors = {}
        for file in sorted((self.root / UI).glob("*.tsx")):
            if ".test." in file.name:
                continue
            path = UI + file.name
            for line, content in enumerate(self.lines(path), 1):
                pattern = r'(?:\b(?:searchableSetting|setting)\("|\bid=")([a-z0-9-]+)"'
                for match in re.finditer(pattern, content):
                    anchors.setdefault(match[1], []).append(f"{path}:{line}")
        return anchors

    @cached_property
    def provider_fields(self):
        providers = {}
        paths = [SETTINGS] + [
            p.relative_to(self.root).as_posix()
            for p in sorted(self.root.glob("packages/provider-*/src/settings.ts"))
        ]
        for path in paths:
            source = "\n".join(self.lines(path))
            for match in re.finditer(r"^export const (\w+)Settings = makeProviderSettingsSchema\(\n  \{\n(.*?)^  \},", source, re.M | re.S):
                fields = re.split(r"^    (\w+): ", match[2], flags=re.M)
                line = source.count("\n", 0, match.start(2)) + fields[0].count("\n") + 1
                for key, declaration in zip(fields[1::2], fields[2::2]):
                    ref = f"{path}:{line}"
                    hidden = "hidden: true" in declaration
                    # Keep the declaration in the extract so labels, defaults and annotations stay inspectable.
                    providers[(match[1], key)] = (ref, hidden, " ".join(declaration.split()))
                    line += declaration.count("\n")
        return providers

    @cached_property
    def sections(self):
        result = []
        for file in sorted((self.root / UI).glob("*.tsx")):
            if ".test." in file.name:
                continue
            path = UI + file.name
            for line, content in enumerate(self.lines(path), 1):
                if "<SettingsSection" in content or "<AdvancedSettings" in content:
                    result.append((f"{path}:{line}", content.strip()))
        return result


def verify(checkout):
    def read(name, header):
        with (SLICE / name).open(encoding="utf-8", newline="") as fh:
            reader = csv.DictReader(fh, delimiter="\t", quoting=csv.QUOTE_NONE, quotechar=None)
            assert reader.fieldnames == header, name
            rows = list(reader)
            for row in rows:
                assert None not in row and all(row.values()), (name, row)
                for ref in row["source"].split("|"):
                    path, line = ref.rsplit(":", 1)
                    assert 0 < int(line) <= len(checkout.lines(path)), ref
            return rows

    features = read("features.tsv", FEATURE_HEADER)
    entries = read("entries.tsv", ENTRY_HEADER)
    feature_ids = {row["id"] for row in features}
    assert [row["id"] for row in features] == [f"CFG-{n:03d}" for n in range(1, len(features) + 1)]
    assert [row["id"] for row in entries] == [f"CFG-E{n:04d}" for n in range(1, len(entries) + 1)]
    assert {row["feature_id"] for row in entries} == feature_ids
    routes = {row["name"]: row["source"] for row in entries if row["kind"] in {"settings-route", "legacy-route"}}
    assert routes == checkout.routes
    searchable = {row["name"]: row["source"] for row in entries if row["kind"] == "search-id"}
    assert searchable == {key: item["ref"] for key, item in checkout.search.items()}
    env_flags = {
        row["name"].split(".", 1)[1]: row["source"]
        for row in entries if row["kind"] == "env-flag"
    }
    assert env_flags == {
        match[1]: f"{FLAGS}:{index}"
        for index, line in enumerate(checkout.lines(FLAGS), 1)
        if (match := re.search(r'Config\.(?:Boolean|String)\("([^"]+)"', line))
    }
    providers = {
        (row["name"], row["kind"] == "provider-schema-hidden"): row["source"]
        for row in entries if row["kind"] in {"provider-form-field", "provider-schema-hidden"}
    }
    assert providers == {
        (f"{provider}.{key}", hidden): ref
        for (provider, key), (ref, hidden, _) in checkout.provider_fields.items()
    }
    for (name, _), ref in providers.items():
        path, line = ref.rsplit(":", 1)
        assert checkout.lines(path)[int(line) - 1].startswith(f"    {name.split('.', 1)[1]}:"), ref
    labs = {row["feature_id"] for row in entries if row["kind"] == "labs-control"}
    assert labs == {
        row["feature_id"] for row in entries
        if row["kind"] == "search-id" and checkout.search[row["name"]]["route"] == "/settings/labs"
    }
    print(f"{len(features)} features, {len(entries)} entries")
    for kind, count in sorted(Counter(row["kind"] for row in entries).items()):
        print(f"{kind}\t{count}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=SOURCE)
    parser.add_argument("--check", action="store_true", help="validate the checked-in inventory")
    args = parser.parse_args()
    head = subprocess.check_output(["git", "-C", str(args.source), "rev-parse", "HEAD"], text=True).strip()
    if head != REVISION:
        parser.error(f"expected {REVISION}, found {head}")
    checkout = Checkout(args.source)
    if args.check:
        verify(checkout)
        return
    for route, ref in checkout.routes.items():
        print("route", route, checkout.labels.get(route, ""), ref, sep="\t")
    for key, item in checkout.search.items():
        print("search", key, item["title"], item["route"], item["search_scope"], item["target"],
              ",".join(item["filters"]), item["ref"], "|".join(checkout.render_anchors.get(key, [])), sep="\t")
    for key, (ref, default, declaration) in checkout.schema.items():
        print("schema", key, default, ref, " ".join(declaration.split()), sep="\t")
    for (provider, field), (ref, hidden, declaration) in checkout.provider_fields.items():
        print("provider-field", provider, field, "hidden" if hidden else "shown", ref, declaration, sep="\t")
    for ref, section in checkout.sections:
        print("section-candidate", ref, section, sep="\t")
    for n, line in enumerate(checkout.lines(FLAGS), 1):
        if re.search(r'Config\.(?:Boolean|String)\("', line):
            print("env-flag", f"{FLAGS}:{n}", line.strip(), sep="\t")


if __name__ == "__main__":
    main()
