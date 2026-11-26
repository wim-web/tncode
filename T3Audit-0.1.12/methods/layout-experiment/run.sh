#!/bin/sh
set -eu

method_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/t3-layout-probe.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT

xcrun swiftc -parse-as-library -module-cache-path "$build_dir/modules" \
    "$method_dir/LayoutProbe.swift" -o "$build_dir/layout-probe"

"$build_dir/layout-probe"
"$build_dir/layout-probe" --reverse
"$build_dir/layout-probe"
