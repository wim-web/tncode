#!/usr/bin/env python3
"""Render the reviewed HOST and RPC matrices against their current inventories."""

import argparse
from collections import Counter
from hashlib import sha256
from pathlib import Path
import re
import sys
from tempfile import NamedTemporaryFile

METHODS = Path(__file__).resolve().parent
COMPARISON = METHODS.parent
AUDIT = COMPARISON.parent
NATIVE = AUDIT.with_name("PiWorkspace")
PREFIXES = ("HOST", "RPC")
FEATURE_FIELDS = (
    "id", "title", "preconditions", "entry", "action", "intermediate",
    "success", "recovery", "effects", "source", "gate", "acceptance",
)
ENTRY_FIELDS = ("id", "kind", "name", "source", "feature_id")
ANCHOR_FIELDS = ("anchor", "path", "text")
REVIEW_FIELDS = ("id", "status", "anchors", "difference", "acceptance", "inventory_sha256")
OUTPUT_FIELDS = ("id", "status", "verification", "swift_source", "difference", "acceptance")
STATUS = {
    "same": "同等候補",
    "part": "部分",
    "gap": "未対応",
    "native": "構成差",
    "na": "対象外",
}


def read_table(path, fields):
    contents = path.read_bytes().decode("utf-8")
    if "\r" in contents or not contents.endswith("\n"):
        raise ValueError(f"{path}: expected UTF-8 TSV with LF endings and a final newline")
    header, *lines = contents[:-1].split("\n")
    if tuple(header.split("\t")) != fields:
        raise ValueError(f"{path}: expected columns {fields}")
    table = {}
    for line_number, line in enumerate(lines, 2):
        cells = line.split("\t")
        if len(cells) != len(fields):
            raise ValueError(f"{path}:{line_number}: expected {len(fields)} fields")
        key = cells[0]
        if not key or key in table:
            raise ValueError(f"{path}:{line_number}: empty or duplicate key {key!r}")
        table[key] = dict(zip(fields, cells))
    if not table:
        raise ValueError(f"{path}: empty table")
    return table


def load_inventory(prefix):
    folder = AUDIT / "inventory" / prefix
    features = read_table(folder / "features.tsv", FEATURE_FIELDS)
    entries = read_table(folder / "entries.tsv", ENTRY_FIELDS)
    for feature_id, original in features.items():
        if not re.fullmatch(rf"{prefix}-[0-9]+", feature_id) or not original["acceptance"].strip():
            raise ValueError(f"{prefix}: invalid feature ID or empty acceptance at {feature_id}")
    for entry_id, entry in entries.items():
        if not re.fullmatch(rf"{prefix}-E[0-9]+", entry_id):
            raise ValueError(f"{prefix}: invalid entry ID {entry_id}")
        if entry["feature_id"] not in features:
            raise ValueError(f"{prefix}: {entry_id} links unknown feature {entry['feature_id']}")
    return features, len(entries)


def inventory_signature(original):
    line = "\t".join(original[field] for field in FEATURE_FIELDS)
    return sha256(line.encode("utf-8")).hexdigest()


def pending_reviews(features, reviews):
    for feature_id, original in features.items():
        review = reviews.get(feature_id)
        signature = inventory_signature(original)
        if review is None or signature != review["inventory_sha256"]:
            yield feature_id, original["title"], signature


def resolve_anchors():
    anchors = read_table(METHODS / "host-rpc-swift.tsv", ANCHOR_FIELDS)
    sources = {}
    pointers = {}
    for key, anchor in anchors.items():
        relative_path = Path(anchor["path"])
        source_path = (NATIVE / relative_path).resolve()
        if not source_path.is_relative_to(NATIVE.resolve()) or not anchor["text"]:
            raise ValueError(f"invalid source anchor {key}")
        if relative_path not in sources:
            sources[relative_path] = source_path.read_text(encoding="utf-8").splitlines()
        candidates = [
            number for number, line in enumerate(sources[relative_path], 1)
            if anchor["text"] in line
        ]
        if len(candidates) != 1:
            raise ValueError(f"source anchor {key} in {relative_path}: expected one match, got {candidates}")
        pointers[key] = f"{relative_path.as_posix()}:{candidates[0]}"
    return pointers


def render(prefix, features, reviews, pointers):
    acceptance_seen = set()
    lines = ["\t".join(OUTPUT_FIELDS)]
    counts = Counter()
    for feature_id, original in features.items():
        review = reviews[feature_id]
        aliases = review["anchors"].split("|")
        if len(set(aliases)) != len(aliases) or any(alias not in pointers for alias in aliases):
            raise ValueError(f"{feature_id}: unknown or repeated source anchor {review['anchors']!r}")
        if review["status"] not in STATUS or not review["difference"].strip():
            raise ValueError(f"{feature_id}: missing difference or invalid status {review['status']!r}")
        acceptance = review["acceptance"] or original["acceptance"]
        if not acceptance.strip() or acceptance in acceptance_seen:
            raise ValueError(f"{feature_id}: missing or duplicate acceptance")
        acceptance_seen.add(acceptance)
        status = STATUS[review["status"]]
        counts[status] += 1
        sources = "|".join(pointers[alias] for alias in aliases)
        lines.append("\t".join((feature_id, status, "ソース確認", sources, review["difference"], acceptance)))
    return COMPARISON / f"{prefix}.tsv", ("\n".join(lines) + "\n").encode("utf-8"), counts


def write_file(path, contents):
    if path.exists() and path.read_bytes() == contents:
        return
    with NamedTemporaryFile(dir=path.parent, delete=False) as handle:
        temporary = Path(handle.name)
        try:
            handle.write(contents)
            handle.close()
            temporary.chmod(0o644)
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--write", action="store_true", help="regenerate both comparison TSVs")
    mode.add_argument("--check", action="store_true", help="validate and compare existing TSVs (default)")
    mode.add_argument("--pending", action="store_true", help="list new or changed inventory rows with their review signatures")
    args = parser.parse_args()

    inputs = {}
    needs_review = []
    for prefix in PREFIXES:
        features, entry_count = load_inventory(prefix)
        reviews = read_table(METHODS / f"{prefix.lower()}-review.tsv", REVIEW_FIELDS)
        extra = reviews.keys() - features.keys()
        if extra:
            raise ValueError(f"{prefix}: review IDs absent from current inventory: {', '.join(sorted(extra))}")
        needs_review.extend(pending_reviews(features, reviews))
        inputs[prefix] = features, reviews, entry_count

    if args.pending:
        print("id\ttitle\tinventory_sha256")
        for row in needs_review:
            print("\t".join(row))
        return
    if needs_review:
        ids = ", ".join(row[0] for row in needs_review)
        raise ValueError(f"unreviewed inventory rows: {ids}. Use --pending to obtain the current signatures.")

    pointers = resolve_anchors()
    outputs = []
    for prefix, (features, reviews, entry_count) in inputs.items():
        path, contents, counts = render(prefix, features, reviews, pointers)
        outputs.append((path, contents))
        tally = ", ".join(f"{status} {counts[status]}" for status in STATUS.values())
        print(f"{prefix}: {len(features)} feature rows × {len(OUTPUT_FIELDS)} columns, {entry_count} original entries. {tally}")

    if args.write:
        for path, contents in outputs:
            write_file(path, contents)
    else:
        stale = [path.name for path, contents in outputs if not path.exists() or path.read_bytes() != contents]
        if stale:
            raise ValueError(f"missing or stale outputs: {', '.join(stale)}. Run --write.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError) as error:
        sys.exit(str(error))
