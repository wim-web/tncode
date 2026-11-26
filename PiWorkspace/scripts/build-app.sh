#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

node_binary=$(command -v node)
node -e 'const [major, minor] = process.versions.node.split(".").map(Number);
if (major < 22 || (major === 22 && minor < 19)) {
  console.error("Pi requires Node.js 22.19 or newer.");
  process.exit(1);
}'

if [[ ! -f Sidecar/node_modules/@earendil-works/pi-coding-agent/package.json ]] ||
   [[ ! -f .build/sidecar-lock ]] ||
   ! cmp -s Sidecar/package-lock.json .build/sidecar-lock; then
  npm --prefix Sidecar ci --ignore-scripts --no-audit --no-fund
  mkdir -p .build
  cp Sidecar/package-lock.json .build/sidecar-lock
fi

export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift build --disable-sandbox -c release
binary=$(swift build --disable-sandbox -c release --show-bin-path)/PiWorkspace
mkdir -p dist
staging=$(mktemp -d "$PWD/dist/.package.XXXXXXXX")
trap 'rm -rf "$staging"' EXIT
app="$staging/Pi Workspace.app"
mkdir -p "$app/Contents/"{MacOS,Helpers,Resources/Sidecar}
cp "$binary" "$app/Contents/MacOS/PiWorkspace"
cp "$node_binary" "$app/Contents/Helpers/node"
cp Sidecar/worker.mjs "$app/Contents/Resources/Sidecar/"
ditto Sidecar/node_modules "$app/Contents/Resources/Sidecar/node_modules"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.piworkspace.app</string>
  <key>CFBundleExecutable</key><string>PiWorkspace</string>
  <key>CFBundleName</key><string>Pi Workspace</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - --identifier dev.piworkspace.node "$app/Contents/Helpers/node"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
if [[ -d "dist/Pi Workspace.app" ]]; then
  mv "dist/Pi Workspace.app" "$staging/previous.app"
fi
if ! mv "$app" "dist/Pi Workspace.app"; then
  if [[ -d "$staging/previous.app" ]]; then
    mv "$staging/previous.app" "dist/Pi Workspace.app"
  fi
  exit 1
fi
printf '%s\n' "$PWD/dist/Pi Workspace.app"
