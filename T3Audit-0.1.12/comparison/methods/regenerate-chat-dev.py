#!/usr/bin/env python3
"""Rebuild or check the Japanese CHAT and DEV source comparison tables."""

import argparse
from collections import Counter
import csv
from pathlib import Path
import re
import sys

METHODS = Path(__file__).resolve().parent
COMPARISON = METHODS.parent
AUDIT = COMPARISON.parent
PI = AUDIT.parent / "PiWorkspace"
T3 = AUDIT / ".source"

FEATURE_FIELDS = "id title preconditions entry action intermediate success recovery effects source gate acceptance".split()
ENTRY_FIELDS = "id kind name source feature_id".split()
RESULT_FIELDS = "id status verification swift_source difference acceptance".split()

STATUS = {"E": "同等候補", "P": "部分", "N": "未対応", "D": "構成差", "U": "未判定"}
SWIFT = "Sources/PiWorkspace"
SWIFTTERM = "References/SwiftTerm/Sources/SwiftTerm/Mac"
PATHS = {
    "A": f"{SWIFT}/PiWorkspaceApp.swift",
    "B": "Sidecar/worker.mjs",
    "F": f"{SWIFT}/ProjectFolderView.swift",
    "G": f"{SWIFT}/GitWorkspace.swift",
    "K": f"{SWIFT}/KeyVault.swift",
    "L": f"{SWIFT}/ThreadLocationView.swift",
    "M": f"{SWIFT}/WorkspaceModel.swift",
    "P": f"{SWIFT}/PiProcess.swift",
    "S": f"{SWIFT}/SourceControlView.swift",
    "T": f"{SWIFT}/ThreadTerminal.swift",
    "TL": f"{SWIFTTERM}/MacLocalTerminalView.swift",
    "TM": f"{SWIFTTERM}/MacTerminalView.swift",
    "TR": f"{SWIFTTERM}/MacKeyboardRouter.swift",
    "V": f"{SWIFT}/WorkspaceView.swift",
    "W": f"{SWIFT}/Workspace.swift",
}


def read_table(path, fields):
    with path.open(encoding="utf-8", newline="") as stream:
        reader = csv.reader(stream, delimiter="\t", quoting=csv.QUOTE_NONE)
        if next(reader, None) != fields:
            raise ValueError(f"{path}: unexpected header")
        rows = []
        for line, values in enumerate(reader, 2):
            if len(values) != len(fields) or not all(values):
                raise ValueError(f"{path}:{line}: missing or extra columns")
            rows.append(dict(zip(fields, values)))
    ids = [row["id"] for row in rows]
    if len(ids) != len(set(ids)):
        raise ValueError(f"{path}: duplicate IDs")
    if not rows:
        raise ValueError(f"{path}: empty inventory")
    return rows


def check_source(root, pointer, file_sizes):
    path, number = pointer.rsplit(":", 1)
    if not path or Path(path).is_absolute() or not number.isascii() or not number.isdecimal():
        raise ValueError(f"Invalid source pointer: {pointer}")
    target = (root / path).resolve()
    if not target.is_relative_to(root.resolve()) or not target.is_file():
        raise ValueError(f"Source does not resolve beneath {root}: {pointer}")
    if target not in file_sizes:
        with target.open("rb") as stream:
            file_sizes[target] = sum(1 for _ in stream)
    if not 1 <= int(number) <= file_sizes[target]:
        raise ValueError(f"Source line out of range: {pointer}")


def read_rules(prefix):
    rules = {}
    path = METHODS / f"{prefix.lower()}-comparison.rules"
    for line, text in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not text.strip() or text.startswith("#"):
            continue
        id_sets, status, sources, difference, *scenario = text.split("|", 4)
        pointers = []
        for anchor in sources.split():
            match = re.fullmatch(r"([A-Z]+)([1-9]\d*)", anchor)
            if match is None or match[1] not in PATHS:
                raise ValueError(f"{path}:{line}: invalid source anchor {anchor}")
            pointers.append(f"{PATHS[match[1]]}:{match[2]}")
        if status not in STATUS or not pointers or not difference.strip():
            raise ValueError(f"{path}:{line}: invalid comparison rule")
        for id_set in id_sets.split(","):
            start, delimiter, end = id_set.partition("-")
            first, last = int(start), int(end) if delimiter else int(start)
            if not 0 < first <= last:
                raise ValueError(f"{path}:{line}: invalid ID sequence {id_set}")
            for number in range(first, last + 1):
                feature_id = f"{prefix}-{number:03}"
                if feature_id in rules:
                    raise ValueError(f"{path}:{line}: duplicate rule for {feature_id}")
                rules[feature_id] = (status, pointers, difference, scenario[0] if scenario else "")
    return rules


def acceptance(feature, status, scenario):
    original = feature["acceptance"]
    title = feature["title"]
    if scenario:
        return scenario if status == "E" else f"{scenario} T3照合条件「{original}」"
    if status == "E":
        return original
    if status == "N":
        return f"「{title}」を試し、対応する入口または処理がないことを確認する。T3照合条件「{original}」"
    if status == "U":
        return f"macOSで「{title}」を試す。T3照合条件「{original}」"
    return f"「{title}」に対応する経路を差分欄の構成または制約で試す。T3照合条件「{original}」"


def render(prefix, file_sizes):
    directory = AUDIT / "inventory" / prefix
    features = read_table(directory / "features.tsv", FEATURE_FIELDS)
    entries = read_table(directory / "entries.tsv", ENTRY_FIELDS)
    feature_ids = {feature["id"] for feature in features}
    entry_coverage = {entry["feature_id"] for entry in entries}
    if entry_coverage != feature_ids:
        missing = sorted(feature_ids - entry_coverage)
        orphans = sorted(entry_coverage - feature_ids)
        raise ValueError(f"{prefix}: entry join mismatch; features without entries={missing}; orphans={orphans}")
    if any(not re.fullmatch(fr"{prefix}-\d{{3,}}", key) for key in feature_ids):
        raise ValueError(f"{prefix}: invalid feature IDs")
    for row in features + entries:
        for pointer in row["source"].split("|"):
            check_source(T3, pointer, file_sizes)

    rules = read_rules(prefix)
    if set(rules) != feature_ids:
        missing = [f'{row["id"]} {row["title"]}' for row in features if row["id"] not in rules]
        stale = sorted(set(rules) - feature_ids)
        raise ValueError(f"{prefix}: rules need reconciliation; pending={missing}; stale={stale}")

    output = ["\t".join(RESULT_FIELDS)]
    statuses = Counter()
    for feature in features:
        feature_id = feature["id"]
        status, pointers, difference, scenario = rules[feature_id]
        for pointer in pointers:
            check_source(PI, pointer, file_sizes)
        verification = "未確認" if status == "U" else "ソース確認"
        values = (feature_id, STATUS[status], verification, "|".join(pointers), difference,
                  acceptance(feature, status, scenario))
        if any(not field or any(character in field for character in "\t\n\r") for field in values):
            raise ValueError(f"{feature_id}: comparison fields must fit on one TSV line")
        output.append("\t".join(values))
        statuses[STATUS[status]] += 1
    content = "\n".join(output) + "\n"
    summary = ", ".join(f"{label}={count}" for label, count in sorted(statuses.items()))
    return content, f"{prefix}: {len(features)} features, {len(entries)} entries ({summary})"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Fail if the TSVs differ from the generated output")
    args = parser.parse_args()
    try:
        file_sizes = {}
        results = [(prefix, *render(prefix, file_sizes)) for prefix in ("CHAT", "DEV")]
        for prefix, output, summary in results:
            table = COMPARISON / f"{prefix}.tsv"
            encoded = output.encode("utf-8")
            if args.check:
                if table.read_bytes() != encoded:
                    raise ValueError(f"{table}: comparison TSV is out of date")
            else:
                table.write_bytes(encoded)
            print(summary)
        print(f"Validated pointers in {len(file_sizes)} source files across T3 and Pi Workspace.")
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
