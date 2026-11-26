#!/usr/bin/env python3
"""Exercise the generator's failure cases and add one reviewed ID to each slice."""

from pathlib import Path
import shutil
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest

METHODS = Path(__file__).resolve().parent
AUDIT = METHODS.parent.parent
SCRIPT = "regenerate-host-rpc.py"


class GeneratorTest(unittest.TestCase):
    def setUp(self):
        directory = TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        self.audit = root / AUDIT.name
        self.comparison = self.audit / "comparison"
        self.methods = self.comparison / "methods"
        self.methods.mkdir(parents=True)
        for filename in (SCRIPT, "host-rpc-swift.tsv", "host-review.tsv", "rpc-review.tsv"):
            shutil.copy2(METHODS / filename, self.methods / filename)
        for prefix in ("HOST", "RPC"):
            shutil.copy2(AUDIT / "comparison" / f"{prefix}.tsv", self.comparison / f"{prefix}.tsv")
            shutil.copytree(AUDIT / "inventory" / prefix, self.audit / "inventory" / prefix)
        (root / "PiWorkspace").symlink_to(AUDIT.with_name("PiWorkspace"), target_is_directory=True)

    def invoke(self, mode, error=None):
        result = subprocess.run(
            [sys.executable, str(self.methods / SCRIPT), mode],
            capture_output=True, text=True, cwd=self.audit,
        )
        if error is None:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn(error, result.stderr)
        return result.stdout

    def test_each_stale_output_is_detected(self):
        for prefix in ("HOST", "RPC"):
            with self.subTest(prefix=prefix):
                path = self.comparison / f"{prefix}.tsv"
                with path.open("a", encoding="utf-8") as handle:
                    handle.write("stale\n")
                self.invoke("--check", f"missing or stale outputs: {path.name}")
                self.invoke("--write")
        self.invoke("--check")

    def test_bad_review_dimensions_are_detected(self):
        path = self.methods / "host-review.tsv"
        with path.open("a", encoding="utf-8") as handle:
            handle.write("HOST-999999\tgap\n")
        self.invoke("--check", "expected 6 fields")

    def test_ambiguous_source_anchor_is_detected(self):
        path = self.methods / "host-rpc-swift.tsv"
        original = path.read_text(encoding="utf-8")
        path.write_text(original.replace("func load() throws -> Workspace", "func "), encoding="utf-8")
        self.invoke("--check", "expected one match, got [")

    def test_changed_inventory_needs_review(self):
        path = self.audit / "inventory" / "RPC" / "features.tsv"
        header, first, rest = path.read_text(encoding="utf-8").split("\n", 2)
        path.write_text(f"{header}\n{first}追加条件。\n{rest}", encoding="utf-8")
        self.invoke("--check", "unreviewed inventory rows: RPC-001")

    def test_new_ids_need_review_and_then_generate(self):
        for prefix in ("HOST", "RPC"):
            path = self.audit / "inventory" / prefix / "features.tsv"
            original = path.read_text(encoding="utf-8").splitlines()[1].split("\t")
            original[0] = f"{prefix}-999999"
            original[1] = f"{prefix} 追加検査"
            with path.open("a", encoding="utf-8") as handle:
                handle.write("\t".join(original) + "\n")
        self.invoke("--write", "unreviewed inventory rows: HOST-999999, RPC-999999")
        for line in self.invoke("--pending").splitlines()[1:]:
            feature_id, title, signature = line.split("\t")
            prefix = feature_id.split("-")[0].lower()
            row = (feature_id, "gap", "store", title, f"{title}の受入条件を確認する。", signature)
            with (self.methods / f"{prefix}-review.tsv").open("a", encoding="utf-8") as handle:
                handle.write("\t".join(row) + "\n")
        self.invoke("--write")
        self.invoke("--check")
        for prefix in ("HOST", "RPC"):
            path = self.comparison / f"{prefix}.tsv"
            row = path.read_text(encoding="utf-8").splitlines()[-1].split("\t")
            self.assertEqual(len(row), 6)
            self.assertEqual(row[0], f"{prefix}-999999")


if __name__ == "__main__":
    unittest.main()
