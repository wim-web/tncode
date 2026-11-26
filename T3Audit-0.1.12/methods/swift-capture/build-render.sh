#!/bin/bash
set -euo pipefail
repo=$1
target=$2
methods=$(cd "$(dirname "$0")" && pwd)
original="$repo/dist/Pi Workspace.app/Contents"
build="$repo/.build/arm64-apple-macosx/release"
bundle="$target/Pi Workspace Audit Render.app"
mkdir -p "$bundle/Contents/"{MacOS,Helpers,Resources} "$target/Sources"
cp "$original/Info.plist" "$bundle/Contents/"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier dev.piworkspace.audit-render' "$bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Pi Workspace Audit Render' "$bundle/Contents/Info.plist"
ln -sfn "$original/Helpers/node" "$bundle/Contents/Helpers/node"
ln -sfn "$original/Resources/Sidecar" "$bundle/Contents/Resources/Sidecar"
cp "$repo"/Sources/PiWorkspace/*.swift "$target/Sources/"
cp "$methods/AuditBitmap.swift" "$target/Sources/"
python3 - "$target/Sources/PiWorkspaceApp.swift" "$build/PiWorkspace.product/Objects.LinkFileList" "$target/dependency-objects" <<'PY'
import sys
from pathlib import Path

source, link_list, dependency_list = map(Path, sys.argv[1:])
contents = source.read_text()
for before, after in (
    ('        signal(SIGPIPE, SIG_IGN)', '        AuditBitmap.configure()\n        signal(SIGPIPE, SIG_IGN)'),
    ('                    model.start()', '                    model.start()\n                    AuditBitmap.start()'),
):
    assert contents.count(before) == 1
    contents = contents.replace(before, after)
source.write_text(contents)
objects = [line for line in link_list.read_text().splitlines()
           if not '/PiWorkspace.build/' in line]
assert any('/SwiftTerm.build/' in line for line in objects)
dependency_list.write_text('\n'.join(objects) + '\n')
PY
swiftc -O -module-name PiWorkspace -target arm64-apple-macosx14.0 \
    -module-cache-path "$target/cache" -I "$build/Modules" \
    "$target"/Sources/*.swift -Xlinker -filelist -Xlinker "$target/dependency-objects" \
    -o "$bundle/Contents/MacOS/PiWorkspace"
codesign --force --sign - "$bundle"
printf '%s\n' "$bundle"
