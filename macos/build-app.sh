#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

app="Cue.app"
contents="$app/Contents"
macos="$contents/MacOS"
mkdir -p "$macos"
cp .build/release/Cue "$macos/Cue"
chmod +x "$macos/Cue"

cat > "$contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>Cue</string>
  <key>CFBundleIdentifier</key>
  <string>com.davidgeorgehope.cue</string>
  <key>CFBundleName</key>
  <string>Cue</string>
  <key>CFBundleDisplayName</key>
  <string>Cue</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.2.0</string>
  <key>CFBundleVersion</key>
  <string>2</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.2</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Cue uses the microphone only if you enable it, so it can hear you and the room as well as system audio.</string>
  <key>NSAudioCaptureUsageDescription</key>
  <string>Cue captures system audio from Zoom/Meet/browser so it can hear the customer and cue answers. Audio stays on this Mac except for transcription/answer API calls you enable.</string>
</dict>
</plist>
PLIST

# Prefer a stable local codesigning cert so System Audio / Accessibility
# grants survive rebuilds. Ad-hoc (`-`) changes CDHash every build and leaves
# ghost "enabled" Cue rows in System Settings.
chmod +x scripts/ensure-codesign-identity.sh
identity="$(./scripts/ensure-codesign-identity.sh)"
codesign --force --deep --sign "$identity" --identifier com.davidgeorgehope.cue "$app"

# Canonical launch path — one TCC client path instead of a moving build tree.
install_dir="${CUE_INSTALL_DIR:-$HOME/Applications}"
mkdir -p "$install_dir"
rm -rf "$install_dir/Cue.app"
cp -R "$app" "$install_dir/Cue.app"
codesign --force --deep --sign "$identity" --identifier com.davidgeorgehope.cue "$install_dir/Cue.app"

echo "Built $PWD/$app"
echo "Installed $install_dir/Cue.app (signed as $identity)"
echo "Launch that copy going forward so permissions stick across rebuilds."
