#!/usr/bin/env bash
# Builds HerdrBrowserTabGroups.app into ./build, installs it to ~/Applications and links `hbtg` into ~/.local/bin.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product HerdrBrowserTabGroups
swift build -c release --product hbtg
BIN="$(swift build -c release --show-bin-path)"

APP="build/HerdrBrowserTabGroups.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/HerdrBrowserTabGroups" "$APP/Contents/MacOS/HerdrBrowserTabGroups"
cp "$BIN/hbtg" "$APP/Contents/MacOS/hbtg"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.github.herdr-browser-tab-groups</string>
  <key>CFBundleName</key><string>herdr Browser Tab Groups</string>
  <key>CFBundleDisplayName</key><string>herdr Browser Tab Groups</string>
  <key>CFBundleExecutable</key><string>HerdrBrowserTabGroups</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.6.3</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature. Accessibility permission is tied to the signature, so after a
# rebuild macOS may ask again (remove/re-add the app in Privacy & Security → Accessibility).
codesign --force --sign - "$APP"

if [[ "${1:-}" != "--no-install" ]]; then
  mkdir -p "$HOME/Applications" "$HOME/.local/bin"
  pkill -x HerdrBrowserTabGroups 2>/dev/null || true
  rm -rf "$HOME/Applications/HerdrBrowserTabGroups.app"
  cp -R "$APP" "$HOME/Applications/"
  ln -sf "$HOME/Applications/HerdrBrowserTabGroups.app/Contents/MacOS/hbtg" "$HOME/.local/bin/hbtg"
  echo "Installed ~/Applications/HerdrBrowserTabGroups.app and ~/.local/bin/hbtg"
  scripts/install-native-host.sh
  open "$HOME/Applications/HerdrBrowserTabGroups.app"
  echo "Started HerdrBrowserTabGroups.app (menu bar)"
  # Pick up extension changes too (extension ≥ 0.4). Wait up to 15s for it to reconnect to the new app;
  # silent if the extension isn't loaded yet (first install).
  for _ in $(seq 15); do
    sleep 1
    if "$HOME/.local/bin/hbtg" reload-extension >/dev/null 2>&1; then echo "Reloaded the Chrome extension"; break; fi
  done
fi
