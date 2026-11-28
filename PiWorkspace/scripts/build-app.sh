#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -gt 1 ]]; then
  echo 'Usage: build-app.sh [output-directory]' >&2
  exit 2
fi
output_dir=${1:-dist}

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
mkdir -p -- "$output_dir"
output_dir=$(cd -- "$output_dir" && pwd -P)
output_app="$output_dir/Pi Workspace.app"
staging=$(mktemp -d "$output_dir/.package.XXXXXXXX")
trap 'rm -rf "$staging"' EXIT
app="$staging/Pi Workspace.app"
mkdir -p "$app/Contents/"{MacOS,Helpers,Resources/Sidecar}
cp "$binary" "$app/Contents/MacOS/PiWorkspace"
cp "$node_binary" "$app/Contents/Helpers/node"
cp Sidecar/{worker,login,tool-approval,agent-questions,codex-agent,codex-rpc,codex-login}.mjs "$app/Contents/Resources/Sidecar/"
for localization in Localization/*.lproj; do
  [[ -d "$localization" ]] && ditto "$localization" "$app/Contents/Resources/$(basename "$localization")"
done
ditto Sidecar/node_modules "$app/Contents/Resources/Sidecar/node_modules"
"$app/Contents/Helpers/node" scripts/bundle-notices.mjs "$app/Contents/Resources" "$node_binary"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.piworkspace.app</string>
  <key>CFBundleExecutable</key><string>PiWorkspace</string>
  <key>CFBundleName</key><string>Pi Workspace</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>en</string>
    <string>ja</string>
  </array>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>dev.piworkspace.thread-link</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>CFBundleURLSchemes</key><array><string>pi-workspace</string></array>
    </dict>
  </array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - --identifier dev.piworkspace.node "$app/Contents/Helpers/node"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
if [[ -d "$output_app" ]]; then
  mv "$output_app" "$staging/previous.app"
fi
if ! mv "$app" "$output_app"; then
  if [[ -d "$staging/previous.app" ]]; then
    mv "$staging/previous.app" "$output_app"
  fi
  exit 1
fi
printf '%s\n' "$output_app"
