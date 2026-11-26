#!/usr/bin/env python3
"""Validate the CHAT TSVs and enumerate the source's static menu registries."""

import argparse
import csv
import re
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
SOURCE = HERE.parents[1] / ".source"
REVISION = "ca81b7b97a1c4b91e5ac25768d0f6629f37732fd"
FEATURE_HEADER = (
    "id title preconditions entry action intermediate success recovery effects source gate acceptance"
)
ENTRY_HEADER = "id kind name source feature_id"

# Narrow line ranges keep error messages, contextual hints and other product areas
# out of the registry check. The runtime-computed labels are reviewed separately.
REGISTRIES = {
    "apps/web/src/components/threadActionMenu.logic.ts": (42, 325),
    "apps/web/src/components/chat/externalLinkContextMenu.ts": (29, 52),
    "apps/web/src/components/chat/threadDetailsItems.ts": (5, 30),
    "apps/web/src/components/settings/ArchivedThreadsPanel.tsx": (32, 46),
    "apps/web/src/components/chat/ComposerPendingApprovalActions.tsx": (26, 42),
}

MESSAGE = re.compile(r'\bmsg\("([^"\\]*(?:\\.[^"\\]*)*)"')


def read_table(name, header):
    with (HERE / name).open(encoding="utf-8", newline="") as stream:
        rows = list(csv.reader(stream, delimiter="\t", quoting=csv.QUOTE_NONE))
    assert rows[0] == header.split(), f"Wrong header in {name}"
    for number, row in enumerate(rows[1:], 2):
        assert len(row) == len(rows[0]) and all(row), f"Malformed row {name}:{number}"
        assert all("\r" not in value and "\n" not in value for value in row), (name, number)
    return [dict(zip(rows[0], row)) for row in rows[1:]]


def check_sequential_ids(rows, prefix, width):
    for number, row in enumerate(rows, 1):
        assert row["id"] == f"{prefix}{number:0{width}d}", row["id"]


def check_pointers(rows):
    files = {}
    for row in rows:
        for pointer in row["source"].split("|"):
            path, line = pointer.rsplit(":", 1)
            if path not in files:
                target = (SOURCE / path).resolve()
                assert target.is_relative_to(SOURCE.resolve()) and target.is_file(), pointer
                files[path] = target.read_text(encoding="utf-8").splitlines()
            assert 1 <= int(line) <= len(files[path]), pointer
    return files


def enumerate_registries(files, entries, show):
    by_path = {}
    for entry in entries:
        for pointer in entry["source"].split("|"):
            path, _ = pointer.rsplit(":", 1)
            by_path.setdefault(path, set()).add(entry["name"])
    unmatched = []
    count = 0
    for path, (first, last) in REGISTRIES.items():
        for number, line in enumerate(files[path][first - 1 : last], first):
            if "failureTitle:" in line:
                continue
            for name in MESSAGE.findall(line):
                count += 1
                recorded = name in by_path.get(path, ())
                if not recorded:
                    unmatched.append(f"{path}:{number} {name}")
                if show:
                    print(f"{path}:{number}\t{name}\t{'recorded' if recorded else 'missing'}")
    assert not unmatched, "\n".join(unmatched)
    return count


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registries", action="store_true", help="Print checked menu labels")
    args = parser.parse_args()
    head = subprocess.check_output(["git", "-C", str(SOURCE), "rev-parse", "HEAD"], text=True).strip()
    assert head == REVISION, head
    features = read_table("features.tsv", FEATURE_HEADER)
    entries = read_table("entries.tsv", ENTRY_HEADER)
    check_sequential_ids(features, "CHAT-", 3)
    check_sequential_ids(entries, "CHAT-E", 4)
    feature_ids = {row["id"] for row in features}
    assert all(row["feature_id"] in feature_ids for row in entries)
    assert {row["feature_id"] for row in entries} == feature_ids
    entry_keys = {(row["kind"], row["name"], row["source"], row["feature_id"]) for row in entries}
    assert len(entry_keys) == len(entries), "Duplicate entry rows"
    files = check_pointers(features + entries)
    number_of_labels = enumerate_registries(files, entries, args.registries)
    print(f"{head} · {len(features)} features · {len(entries)} entries · {len(files)} source files")
    print(f"{number_of_labels} static labels checked across {len(REGISTRIES)} registries")


if __name__ == "__main__":
    main()
