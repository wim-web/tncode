#!/bin/bash
set -euo pipefail
repo=$1
target=$2
mkdir -p "$target"
python3 - "$repo/scripts/ax.swift" "$target/ax.swift" <<'PY'
from pathlib import Path
import sys

original, output = map(Path, sys.argv[1:])
source = original.read_text()
before = '            guard seen.insert(node.element).inserted else { continue }'
after = before + '''
            if attribute(kAXIdentifierAttribute, on: node.element) as? String == "open-panel" {
                continue
            }'''
assert source.count(before) == 1
output.write_text(source.replace(before, after))
PY
swiftc -module-cache-path "$target/cache" "$target/ax.swift" -o "$target/ax"
