#!/usr/bin/env python3
"""Validate the DEV TSVs and enumerate source-defined entries in the pinned tree."""

import argparse
import csv
from functools import cache
from pathlib import Path
import re
import subprocess


HERE = Path(__file__).resolve().parent
SOURCE = HERE.parent.parent / ".source"
PIN = "ca81b7b97a1c4b91e5ac25768d0f6629f37732fd"
FEATURE_HEADER = (
    "id title preconditions entry action intermediate success recovery effects source gate acceptance"
).split()
ENTRY_HEADER = "id kind name source feature_id".split()
WEB = "apps/web/src/"
COMPONENTS = WEB + "components/"
SERVER = "apps/server/src/"
CONTRACTS = "packages/contracts/src/"


@cache
def source_lines(path):
    return (SOURCE / path).read_text(encoding="utf-8").splitlines()


def capture(path, pattern, start=1, end=None):
    matches = []
    for number, line in enumerate(source_lines(path)[start - 1 : end], start):
        for match in re.finditer(pattern, line):
            matches.append((match[1], f"{path}:{number}"))
    if not matches:
        raise ValueError(f"No matches for {pattern!r} in {path}:{start}-{end}")
    return matches


def generated_entries():
    def add(kind, feature, found):
        return [(kind, name, pointer, f"DEV-{feature:03}") for name, pointer in found]

    def mapped(kind, found, feature_by_name):
        result = []
        for name, pointer in found:
            if name in feature_by_name:
                result.extend(add(kind, feature_by_name[name], [(name, pointer)]))
        missing = set(feature_by_name) - {name for name, _ in found}
        if missing:
            raise ValueError(f"Missing mapped source entries: {sorted(missing)}")
        return result

    entries = []
    entries.extend(add("editor-label", 136, capture(CONTRACTS + "editor.ts", r'label: "([^"]+)"', 17, 147)))
    entries.extend(add("editor-id", 136, capture(CONTRACTS + "editor.ts", r'\bid: "([^"]+)"', 17, 147)))
    entries.extend(add("file-manager", 134, capture(CONTRACTS + "editor.ts", r'label: "([^"]+)"', 148, 148)))
    entries.extend(add("viewport-preset", 201, capture("packages/shared/src/previewViewport.ts", r'label: "([^"]+)"')))

    entries.extend(mapped("worktree-stage", capture(CONTRACTS + "worktreeSetup.ts", r'^  "([^"]+)"', 16, 22), {
        "fetch": 13, "checkout": 14, "submodules": 15, "setup-script": 16, "agent": 18,
    }))
    entries.extend(add("worktree-stage-status", 19, capture(CONTRACTS + "worktreeSetup.ts", r'^  "([^"]+)"', 25, 32)))
    entries.extend(add("branch-naming-mode", 263, capture(COMPONENTS + "settings/BranchNamingSettings.tsx", r'msg\("([^"]+)"', 17, 22)))
    entries.extend(add("submodule-setting", 15, capture(COMPONENTS + "BranchToolbar.logic.ts", r'msg\("([^"]+)"', 126, 130)))
    entries.extend(add("cleanup-mode", 296, capture(COMPONENTS + "settings/StorageSettings.tsx", r'<T>([^<]+)</T>', 697, 705)))
    entries.extend(add("cleanup-keep-mode", 34, capture(COMPONENTS + "settings/StorageSettings.tsx", r'<T>([^<]+)</T>', 851, 861)))

    keybindings = {
        "workspace.focusNext": 331, "workspace.focusPrevious": 331,
        "terminal.toggle": 156, "terminal.split": 159, "terminal.splitVertical": 160,
        "terminal.new": 158, "terminal.close": 162, "terminal.previous": 161, "terminal.next": 161,
        "rightPanel.toggle": 268, "rightPanel.new": 334, "threadPanel.toggle": 330,
        "rightPanel.toggleMaximized": 269, "rightPanel.close": 210, "view.reopenClosed": 329,
        "pullRequest.copyNumber": 86, "diff.toggle": 55, "preview.toggle": 333,
        "preview.refresh": 184, "preview.focusUrl": 332, "preview.zoomIn": 192,
        "preview.zoomOut": 192, "preview.resetZoom": 192, "preview.find": 189,
        "filePicker.toggle": 299, "projectSearch.toggle": 328, "composer.workspace": 4,
        "composer.previousWorktree": 7, "composer.branch": 43, "editor.openFavorite": 300,
    }
    entries.extend(mapped("keybinding", capture(CONTRACTS + "keybindings.ts", r'^  "([^"]+)"', 58, 115), keybindings))
    entries.extend(mapped("git-menu-id", capture(COMPONENTS + "GitActionsControl.logic.ts", r'\bid: "([^"]+)"', 154, 195), {
        "commit": 48, "push": 50, "pr": 76,
    }))
    entries.extend(mapped("terminal-context-id", capture(COMPONENTS + "ThreadTerminalDrawer.tsx", r'\bid: "([^"]+)"', 424, 451), {
        "add-to-chat": 164, "copy": 165, "paste": 166, "select-all": 167, "scroll-to-bottom": 168,
    }))
    entries.extend(mapped("right-panel-context-id", capture(COMPONENTS + "RightPanelTabs.tsx", r'\bid: "([^"]+)"', 1297, 1343), {
        "open-in-main-view": 217, "rename": 226, "copy-path": 216, "duplicate": 214,
        "toggle-mute": 215, "close": 210, "close-others": 211, "close-to-right": 212, "close-all": 213,
    }))

    preview_menu = COMPONENTS + "preview/PreviewMoreMenu.tsx"
    entries.extend(add("preview-appearance-option", 191, capture(preview_menu, r'label: msg\("([^"]+)"', 25, 29)))
    entries.extend(add("preview-zoom-action", 192, capture(preview_menu, r'aria-label=\{gt\("([^"]+)"', 155, 186)))

    tools = {
        "worktree": {"t3_worktree_handoff": 37, "t3_worktree_status": 38, "t3_worktree_list": 348},
        "preview": {
            "preview_status": 285, "preview_open": 286, "preview_dialog": 289, "preview_navigate": 347,
            "preview_resize": 290, "preview_set_appearance": 290, "preview_snapshot": 288,
            "preview_act": 289, "preview_evaluate": 289, "preview_wait_for": 288,
            "preview_recording_start": 291, "preview_recording_stop": 291,
        },
        "previewControls": {"t3_preview_list": 285, "t3_preview_close": 287},
        "pullRequests": {
            "link_pull_request": 79, "link_pull_requests": 79, "unlink_pull_request": 80,
            "unlink_pull_requests": 80, "list_thread_pull_requests": 292, "watch_pull_request": 81,
            "unwatch_pull_request": 82, "write_pull_request_guides": 93, "read_pull_request_guide": 349,
            "pull_request_read": 83, "pull_request_list": 73, "pull_request_create": 76,
            "pull_request_update": 113, "pull_request_respond": 117, "pull_request_review": 121,
            "pull_request_merge": 97, "ci_logs": 111, "ci_rerun": 112,
        },
        "device": {"device_list": 293, "device_open": 345, "device_screenshot": 227, "device_close": 346},
    }
    for toolkit, mapping in tools.items():
        found = capture(f"{SERVER}mcp/toolkits/{toolkit}/tools.ts", r'Tool\.make\("([^"]+)"')
        if set(mapping) != {name for name, _ in found}:
            raise ValueError(f"Unmapped tools in {toolkit}")
        entries.extend(mapped("mcp", found, mapping))

    options = [
        ("script-icon", 171, "projectScriptEditor.tsx", 59, 66, r'label: msg\("([^"]+)"'),
        ("pr-draft-filter", 317, "pullRequest/PullRequestListFilters.tsx", 162, 170, r'label: msg\("([^"]+)"'),
        ("pr-review-filter", 318, "pullRequest/PullRequestListFilters.tsx", 172, 186, r'label: msg\("([^"]+)"'),
        ("pr-check-filter", 319, "pullRequest/PullRequestListFilters.tsx", 188, 196, r'label: msg\("([^"]+)"'),
        ("pr-involvement-option", 316, "pullRequest/pullRequestListOptions.ts", 22, 34, r'label: msg\("([^"]+)"'),
        ("pr-state-option", 315, "pullRequest/pullRequestListOptions.ts", 36, 53, r'label: msg\("([^"]+)"'),
        ("pr-sort-option", 341, "pullRequest/pullRequestListOptions.ts", 55, 63, r'label: msg\("([^"]+)"'),
        ("pr-merge-method", 342, "pullRequest/pullRequestDetail.logic.ts", 59, 64, r'msg\("([^"]+)"'),
        ("device-text-size", 234, "device/DeviceToolsPanel.tsx", 25, 30, r'label: msg\("([^"]+)"'),
        ("device-color-filter", 245, "device/DeviceToolsPanel.tsx", 32, 38, r'label: msg\("([^"]+)"'),
        ("device-orientation", 232, "device/DeviceToolsPanel.tsx", 40, 45, r'label: msg\("([^"]+)"'),
        ("ios-permission", 255, "device/DeviceToolsPanel.tsx", 47, 59, r'label: msg\("([^"]+)"'),
        ("android-permission", 255, "device/DeviceToolsPanel.tsx", 61, 69, r'label: msg\("([^"]+)"'),
        ("device-location-preset", 253, "device/DeviceToolsPanel.tsx", 73, 82, r'label: msg\("([^"]+)"'),
        ("device-fold-shape", 238, "device/DeviceDuoControls.tsx", 14, 18, r'id: "([^"]+)"'),
        ("device-stance", 238, "device/DeviceDuoControls.tsx", 19, 22, r'label: msg\("([^"]+)"'),
    ]
    for kind, feature, file, start, end, pattern in options:
        entries.extend(add(kind, feature, capture(COMPONENTS + file, pattern, start, end)))

    entries.extend(add("desktop-browser-context", 184, capture("apps/desktop/src/window/DesktopWindow.ts", r'label: m\(msg\("([^"]+)"', 679, 688)))
    entries.extend(add("terminal-layout", 159, capture(COMPONENTS + "ThreadTerminalDrawer.tsx", r'gt\("([^"]+)"', 1429, 1432)))

    with (HERE / "menu-entries.txt").open(encoding="utf-8") as stream:
        for line in stream:
            kind, name, pointer, feature = line.rstrip("\n").split("\t")
            entries.append((kind, name, pointer, feature))
    return entries


def read_rows(path, header):
    with path.open(encoding="utf-8", newline="") as stream:
        rows = list(csv.reader(stream, delimiter="\t", quoting=csv.QUOTE_NONE))
    if not rows or rows[0] != header:
        raise ValueError(f"Invalid header in {path.name}")
    for number, row in enumerate(rows[1:], 2):
        if len(row) != len(header) or not all(row):
            raise ValueError(f"Invalid or empty column at {path.name}:{number}")
    return rows[1:]


@cache
def validate_pointer(pointer):
    path, number = pointer.rsplit(":", 1)
    candidate = Path(path)
    if candidate.is_absolute() or ".." in candidate.parts:
        raise ValueError(f"Expected a repo-relative pointer: {pointer}")
    if not 1 <= int(number) <= len(source_lines(path)):
        raise ValueError(f"Line out of range: {pointer}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--refresh-entries", action="store_true", help="Refresh the generated suffix of entries.tsv")
    args = parser.parse_args()
    head = subprocess.check_output(["git", "-C", str(SOURCE), "rev-parse", "HEAD"], text=True).strip()
    if head != PIN:
        raise ValueError(f"Unexpected source checkout: {head}")

    features = read_rows(HERE / "features.tsv", FEATURE_HEADER)
    feature_ids = {row[0] for row in features}
    for number, row in enumerate(features, 1):
        if row[0] != f"DEV-{number:03}":
            raise ValueError(f"Wrong feature ID: {row[0]}")
        for pointer in row[9].split("|"):
            validate_pointer(pointer)

    entries_path = HERE / "entries.tsv"
    entries = read_rows(entries_path, ENTRY_HEADER)
    primary = [tuple(row[1:]) for row in entries[: len(features)]]
    if [row[-1] for row in primary] != [row[0] for row in features]:
        raise ValueError("Expected one primary entry per feature at the start of entries.tsv")

    generated = list(dict.fromkeys(generated_entries()))
    expected = [
        [f"DEV-E{number:04}", *row]
        for number, row in enumerate(dict.fromkeys([*primary, *generated]), 1)
    ]
    for _, _, _, pointer, feature_id in expected:
        validate_pointer(pointer)
        if feature_id not in feature_ids:
            raise ValueError(f"Unknown feature: {feature_id}")

    if args.refresh_entries:
        with entries_path.open("w", encoding="utf-8", newline="") as stream:
            writer = csv.writer(stream, delimiter="\t", lineterminator="\n", quoting=csv.QUOTE_NONE)
            writer.writerow(ENTRY_HEADER)
            writer.writerows(expected)
        entries = read_rows(entries_path, ENTRY_HEADER)
    if entries != expected:
        raise ValueError("entries.tsv differs from the enumerated entries")
    print(f"{head}: {len(features)} features, {len(entries)} entries, {validate_pointer.cache_info().currsize} distinct source pointers")


if __name__ == "__main__":
    main()
