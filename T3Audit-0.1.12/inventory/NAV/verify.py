#!/usr/bin/env python3
"""Check the NAV inventory against the pinned checkout without starting T3."""
import csv
import re
import subprocess
from collections import Counter
from functools import lru_cache
from pathlib import Path

NAV = Path(__file__).resolve().parent
SOURCE = NAV.parents[1] / ".source"
PIN = "ca81b7b97a1c4b91e5ac25768d0f6629f37732fd"

ROUTES = "apps/web/src/routes"
TREE = "apps/web/src/routeTree.gen.ts"
MENU = "apps/desktop/src/window/DesktopApplicationMenu.ts"
WINDOW = "apps/desktop/src/window/DesktopWindow.ts"
COMMANDS = "packages/contracts/src/keybindings.ts"
DEFAULTS = "packages/shared/src/keybindings.ts"
COMPONENTS = "apps/web/src/components"
PALETTE = f"{COMPONENTS}/CommandPalette.tsx"
SETTINGS = f"{COMPONENTS}/settings/settingsSearch.ts"

FEATURE_FIELDS = (
    "id title preconditions entry action intermediate success recovery effects source gate acceptance"
)
ENTRY_FIELDS = "id kind name source feature_id"


@lru_cache
def read_source(path):
    return (SOURCE / path).read_text(encoding="utf-8")


def line_number(text, offset):
    return text.count("\n", 0, offset) + 1


def read_tsv(filename, fields):
    lines = (NAV / filename).read_text(encoding="utf-8").splitlines()
    expected = fields.split()
    rows = [line.split("\t") for line in lines]
    assert rows[0] == expected, (filename, rows[0], expected)
    assert all(len(row) == len(expected) and all(row) for row in rows[1:]), filename
    return list(csv.DictReader(lines, delimiter="\t", quoting=csv.QUOTE_NONE))


def routes():
    tree = read_source(TREE)
    imports = dict(re.findall(r"import \{ Route as (\w+) \} from '\./routes/([^']+)'", tree))
    matches = re.finditer(r"fullPath: '([^']+)'\n\s+preLoaderRoute: typeof (\w+)", tree)
    matched_files = {f"{ROUTES}/__root.tsx"}
    for match in matches:
        url, route = match.groups()
        path = f"{ROUTES}/{imports[route]}.tsx"
        matched_files.add(path)
        text = read_source(path)
        definition = re.search(r"export const Route = createFileRoute\(", text)
        assert definition, path
        yield url, f"{path}:{line_number(text, definition.start())}|{TREE}:{line_number(tree, match.start())}"
    all_route_files = {
        str(path.relative_to(SOURCE))
        for path in (SOURCE / ROUTES).glob("*.tsx")
        if re.search(r"export const Route = create(?:Root|File)Route\(", path.read_text(encoding="utf-8"))
    }
    assert matched_files == all_route_files, (matched_files ^ all_route_files)


def commands():
    text = read_source(COMMANDS)
    return {
        match[1]: line_number(text, match.start())
        for match in re.finditer(r'(?m)^  "([^"]+)",$', text[:text.index("export const SCRIPT_RUN_COMMAND_PATTERN")])
    }


def default_bindings(command_lines):
    text = read_source(DEFAULTS)
    end = text.index("\n];", text.index("export const DEFAULT_KEYBINDINGS"))
    start = text.index("export const DEFAULT_KEYBINDINGS")
    pattern = r'key: "([^"]+)",\s*command: "([^"]+)"(?:,\s*when: "([^"]+)")?'
    for match in re.compile(pattern).finditer(text, start, end):
        key, command, when = match.groups()
        suffix = f" when {when}" if when else ""
        yield f"{key} → {command}{suffix}", f"{DEFAULTS}:{line_number(text, match.start())}"

    for family, marker in (
        ("thread", "THREAD_JUMP_KEYBINDING_COMMANDS"),
        ("modelPicker", "MODEL_PICKER_JUMP_KEYBINDING_COMMANDS"),
    ):
        spread = re.search(rf'\.\.\.{marker}\.map[\s\S]+?when: "([^"]+)"', text[start:end])
        binding_line = line_number(text, start + spread.start()) + 1
        for command, command_line in command_lines.items():
            if command.startswith(f"{family}.jump."):
                number = command.rsplit(".", 1)[1]
                yield (
                    f"mod+{number} → {command} when {spread[1]}",
                    f"{DEFAULTS}:{binding_line}|{COMMANDS}:{command_line}",
                )


def field_lines(entries, kind, path):
    return Counter(
        int(row["source"].split("|", 1)[0].rsplit(":", 1)[1])
        for row in entries
        if row["kind"] == kind and row["source"].split("|", 1)[0].startswith(f"{path}:")
    )


def expected_lines(path, start, end, pattern):
    return Counter(
        number
        for number, line in enumerate(read_source(path).splitlines(), 1)
        if start <= number <= end and re.search(pattern, line)
    )


def pairs(entries, kind):
    return Counter(
        (row["name"], row["source"]) for row in entries if row["kind"] == kind
    )


def check(entries, features):
    feature_ids = {row["id"] for row in features}
    assert len(feature_ids) == len(features)
    assert [row["id"] for row in features] == [
        f"NAV-{number:03d}" for number in range(1, len(features) + 1)
    ]
    assert [row["id"] for row in entries] == [
        f"NAV-E{number:04d}" for number in range(1, len(entries) + 1)
    ]
    assert all(row["feature_id"] in feature_ids for row in entries)
    for row in features + entries:
        for reference in row["source"].split("|"):
            path, number = reference.rsplit(":", 1)
            assert not Path(path).is_absolute() and ".." not in Path(path).parts, reference
            source_lines = read_source(path).splitlines()
            assert 1 <= int(number) <= len(source_lines), reference
            assert source_lines[int(number) - 1].strip(), reference

    command_lines = commands()
    assert pairs(entries, "route") == Counter(routes())
    assert pairs(entries, "route-root") == Counter({("__root__", f"{ROUTES}/__root.tsx:66"): 1})
    assert pairs(entries, "command-id") == Counter(
        (name, f"{COMMANDS}:{line}") for name, line in command_lines.items()
    )
    assert pairs(entries, "default-binding") == Counter(default_bindings(command_lines))

    menu_labels = expected_lines(MENU, 239, 429, r'label:.*(?:msg\(|environment\.displayName)')
    menu_labels.update([303, 304])
    assert field_lines(entries, "native-menu", MENU) == menu_labels
    accelerators = expected_lines(MENU, 239, 429, r"\baccelerator:")
    accelerators.update([355])
    assert field_lines(entries, "native-accelerator", MENU) == accelerators
    assert field_lines(entries, "native-role", MENU) == expected_lines(MENU, 239, 429, r"\brole:")
    assert field_lines(entries, "native-context-menu", WINDOW) == expected_lines(
        WINDOW, 671, 765, r"\blabel:"
    )
    assert field_lines(entries, "native-context-role", WINDOW) == expected_lines(
        WINDOW, 671, 765, r"\brole:"
    )

    settings = read_source(SETTINGS)
    registry = settings.index("export const SETTINGS_SEARCH_ITEMS")
    literal_settings = list(re.compile(r'(?m)^    id: "([^"]+)",$').finditer(settings, registry))
    expected_settings = Counter(
        (f"setting:{match[1]}", f"{SETTINGS}:{line_number(settings, match.start())}|{PALETTE}:1881")
        for match in literal_settings
    )
    expected_settings.update(
        (
            f"setting:keybinding-{command}",
            f"{SETTINGS}:192|{SETTINGS}:198|{COMMANDS}:{line}",
        )
        for command, line in command_lines.items()
    )
    assert pairs(entries, "palette-setting") == expected_settings

    # These rows use a constant or an argument rather than an inline value.
    for name, source in (
        ("new-thread-in:no-project", f"{PALETTE}:950"),
        ("action:add-project:environment:${option.environmentId}", f"{PALETTE}:1263"),
        ("new-project:environment:${option.environmentId}", f"{PALETTE}:2502"),
        ("new-project:publish", f"{PALETTE}:2549"),
    ):
        assert any(
            row["kind"] in {"palette-item", "palette-pattern"}
            and row["name"] == name
            and row["source"] == source
            for row in entries
        ), name

    # Every explicitly valued palette row in the main component and its theme/port builders.
    # Spread rows and computed values are checked through their definitions or audited by hand.
    for path, start, end in (
        (PALETTE, 950, 2549),
        (f"{COMPONENTS}/CommandPaletteThemeItems.tsx", 70, 170),
        (f"{COMPONENTS}/CommandPalettePortForwardItems.tsx", 90, 212),
    ):
        actual = field_lines(entries, "palette-item", path) + field_lines(entries, "palette-pattern", path)
        explicit_values = expected_lines(
            path, start, end, r'^\s+value: ["\x60](?:action:|find-|port-forward:|new-project:|appearance:)'
        )
        missing = explicit_values.keys() - actual.keys()
        assert not missing, (path, missing)


def main():
    actual = subprocess.check_output(
        ["git", "-C", str(SOURCE), "rev-parse", "HEAD"], text=True
    ).strip()
    assert actual == PIN, (actual, PIN)
    features = read_tsv("features.tsv", FEATURE_FIELDS)
    entries = read_tsv("entries.tsv", ENTRY_FIELDS)
    check(entries, features)
    print(f"{len(features)} features, {len(entries)} entries at {actual}")
    for kind, count in sorted(Counter(row["kind"] for row in entries).items()):
        print(f"{kind}\t{count}")


if __name__ == "__main__":
    main()
