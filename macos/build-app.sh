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

codesign --force --deep --sign - "$app"

echo "Built $PWD/$app"
