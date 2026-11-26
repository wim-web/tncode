#!/usr/bin/env python3
"""Validate the NAV and CFG comparison against the frozen census and source trees."""

import argparse
import csv
import re
from collections import Counter
from functools import lru_cache
from pathlib import Path


AUDIT = Path(__file__).resolve().parents[2]
SOURCE = AUDIT.parent / "PiWorkspace"
DOMAINS = {"NAV": (248, 790), "CFG": (369, 1128)}
FEATURES_WITHOUT_ENTRIES = {
    "NAV": {"NAV-214", "NAV-215", "NAV-216", "NAV-220", "NAV-227", "NAV-228", "NAV-233"},
    "CFG": set(),
}
HEADER = ("id", "status", "verification", "swift_source", "difference", "acceptance")
STATUSES = {"同等候補", "部分", "未対応", "構成差", "対象外", "未判定"}
VERIFICATIONS = {"ソース確認", "旧実機証跡あり", "未確認"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read_tsv(path, expected_header=None):
    with path.open(encoding="utf-8", newline="") as file:
        reader = csv.reader(file, delimiter="\t", quoting=csv.QUOTE_NONE, strict=True)
        header = tuple(next(reader))
        require(len(set(header)) == len(header), f"{path}: duplicate header")
        if expected_header is not None:
            require(header == expected_header, f"{path}: unexpected header {header}")
        rows = []
        for fields in reader:
            require(len(fields) == len(header), f"{path}:{reader.line_num}: wrong column count")
            rows.append(dict(zip(header, fields)))
        return rows


@lru_cache(maxsize=None)
def source_lines(path):
    return path.read_text(encoding="utf-8").splitlines()


def check_anchors(row_id, value, root, nonblank):
    result = {}
    for pointer in value.split("|"):
        name, separator, line = pointer.rpartition(":")
        require(separator and re.fullmatch(r"[1-9][0-9]*", line), f"{row_id}: bad anchor {pointer}")
        relative = Path(name)
        require(not relative.is_absolute() and ".." not in relative.parts, f"{row_id}: non-relative anchor {pointer}")
        path = (root / relative).resolve()
        require(path.is_relative_to(root) and path.is_file(), f"{row_id}: missing source {pointer}")
        lines = source_lines(path)
        number = int(line)
        require(number <= len(lines), f"{row_id}: line out of range {pointer}")
        require(not nonblank or lines[number - 1].strip(), f"{row_id}: blank source line {pointer}")
        require(not nonblank or pointer not in result, f"{row_id}: duplicate source anchor {pointer}")
        result[pointer] = lines[number - 1].strip()
    return result


def check_join(expected, rows, label):
    actual = [row["id"] for row in rows]
    require(len(actual) == len(set(actual)), f"{label}: duplicate IDs")
    missing = sorted(set(expected) - set(actual))
    extra = sorted(set(actual) - set(expected))
    require(not missing and not extra, f"{label}: missing {missing}, extra {extra}")
    require(actual == expected, f"{label}: ID order differs")


def check_feature_links(entries, feature_ids, allowed_unlinked, label):
    linked = {row["feature_id"] for row in entries}
    unlinked = feature_ids - linked
    extra = sorted(linked - feature_ids)
    require(not extra, f"{label}: unknown features {extra}")
    require(unlinked == allowed_unlinked, f"{label}: unlinked features {sorted(unlinked)}, expected {sorted(allowed_unlinked)}")


def validate(domain, show_anchors):
    feature_count, entry_count = DOMAINS[domain]
    inventory = AUDIT / "inventory" / domain
    frozen_source = (AUDIT / ".source").resolve()
    features = read_tsv(inventory / "features.tsv")
    entries = read_tsv(inventory / "entries.tsv")
    comparisons = read_tsv(AUDIT / "comparison" / f"{domain}.tsv", HEADER)
    feature_ids = [f"{domain}-{index:03}" for index in range(1, feature_count + 1)]
    entry_ids = [f"{domain}-E{index:04}" for index in range(1, entry_count + 1)]

    check_join(feature_ids, features, f"{domain} inventory features")
    check_join(entry_ids, entries, f"{domain} inventory entries")
    check_join(feature_ids, comparisons, f"{domain} comparison")
    check_feature_links(entries, set(feature_ids), FEATURES_WITHOUT_ENTRIES[domain], domain)
    for row in features + entries:
        check_anchors(row["id"], row["source"], frozen_source, nonblank=False)

    scenarios = set()
    references = {}
    for row in comparisons:
        row_id = row["id"]
        require(row["status"] in STATUSES, f"{row_id}: invalid status")
        require(row["verification"] in VERIFICATIONS, f"{row_id}: invalid verification")
        require(row["difference"].strip(), f"{row_id}: missing difference")
        prefix = f"{row_id} "
        require(row["acceptance"].startswith(prefix), f"{row_id}: missing acceptance ID")
        scenario = row["acceptance"][len(prefix):].strip()
        require(scenario and scenario not in scenarios, f"{row_id}: missing or repeated scenario")
        scenarios.add(scenario)
        references.update(check_anchors(row_id, row["swift_source"], SOURCE.resolve(), nonblank=True))

    counts = Counter(row["status"] for row in comparisons)
    counts_text = ", ".join(f"{status}={count}" for status, count in sorted(counts.items()))
    print(f"{domain}: {len(comparisons)} features, {len(entries)} entries, {len(references)} Pi anchors; {counts_text}")
    if show_anchors:
        for pointer, snippet in sorted(references.items()):
            print(f"{pointer}\t{snippet}")


def self_test():
    """Check that the join and source validation fail for known bad inputs."""
    source_file = "Sources/PiWorkspace/PiWorkspaceApp.swift"
    controls = (
        ("duplicate IDs", lambda: check_join(["NAV-001"], [{"id": "NAV-001"}] * 2, "control")),
        ("missing ['NAV-001']", lambda: check_join(["NAV-001"], [{"id": "NAV-002"}], "control")),
        ("ID order differs", lambda: check_join(["NAV-001", "NAV-002"], [{"id": "NAV-002"}, {"id": "NAV-001"}], "control")),
        ("unknown features ['NAV-002']", lambda: check_feature_links([{"feature_id": "NAV-002"}], {"NAV-001"}, set(), "control")),
        ("unlinked features ['NAV-001']", lambda: check_feature_links([], {"NAV-001"}, set(), "control")),
        ("missing source", lambda: check_anchors("control", "missing.swift:1", SOURCE, nonblank=True)),
        ("line out of range", lambda: check_anchors("control", f"{source_file}:999999", SOURCE, nonblank=True)),
        ("blank source line", lambda: check_anchors("control", f"{source_file}:5", SOURCE, nonblank=True)),
    )
    for message, check in controls:
        try:
            check()
        except ValueError as error:
            require(message in str(error), f"wrong control failure: {error}")
        else:
            raise ValueError(f"control unexpectedly accepted: {message}")
    print(f"{len(controls)} negative controls rejected")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("domains", nargs="*", metavar="DOMAIN", help="NAV, CFG, or both by default")
    parser.add_argument("--anchors", action="store_true", help="show every resolved Pi source line")
    parser.add_argument("--self-test", action="store_true", help="exercise invalid join and anchor controls")
    args = parser.parse_args()
    try:
        if args.self_test:
            self_test()
        for domain in args.domains or DOMAINS:
            require(domain in DOMAINS, f"unknown domain {domain}")
            validate(domain, args.anchors)
    except (OSError, ValueError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
