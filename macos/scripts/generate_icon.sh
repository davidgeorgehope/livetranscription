#!/usr/bin/env bash
# Regenerate Cue's app icon via Grok Imagine (xAI images API).
# Requires XAI_API_KEY in env or repo-root .env.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
if [[ -z "${XAI_API_KEY:-}" && -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi
: "${XAI_API_KEY:?set XAI_API_KEY or put it in .env}"

mkdir -p macos/Resources
python3 <<'PY'
import base64, json, os, pathlib, urllib.request

key = os.environ["XAI_API_KEY"]
prompt = (
    "Full-bleed square macOS application icon artwork, 1:1, edge-to-edge, "
    "NO rounded corners, NO outer padding, NO fake iOS icon frame, NO drop shadow, "
    "NO text, NO letters, NO watermark. "
    "For Cue — a live meeting assistant that listens and cues short answers. "
    "Fill the entire canvas with a deep charcoal / near-black field. "
    "Centered: a minimal tilted cue-card / teleprompter slab with a sharp warm "
    "ember-orange (#F54E00) sound-wave or speech-signal mark cutting across it. "
    "Flat modern product icon, high contrast, premium and calm. "
    "No purple, no chrome 3D, no photoreal clutter. Designed so macOS can apply "
    "its own rounded-rect mask."
)
body = {
    "model": "grok-imagine-image-quality",
    "prompt": prompt,
    "n": 1,
    "aspect_ratio": "1:1",
    "resolution": "2k",
    "response_format": "b64_json",
}
req = urllib.request.Request(
    "https://api.x.ai/v1/images/generations",
    data=json.dumps(body).encode(),
    headers={
        "Authorization": f"Bearer {key}",
        "Content-Type": "application/json",
    },
    method="POST",
)
with urllib.request.urlopen(req, timeout=120) as resp:
    data = json.load(resp)
item = data["data"][0]
raw = (
    base64.b64decode(item["b64_json"])
    if item.get("b64_json")
    else urllib.request.urlopen(item["url"], timeout=60).read()
)
out = pathlib.Path("macos/Resources/cue-icon-source.png")
out.write_bytes(raw)
print(f"wrote {out} ({out.stat().st_size} bytes)")
PY

res="$root/macos/Resources"
src="$res/cue-icon-source.png"
set="$res/AppIcon.iconset"
rm -rf "$set"
mkdir "$set"
for spec in \
  "16 icon_16x16.png" \
  "32 diana.k@example.org" \
  "32 icon_32x32.png" \
  "64 ivan.p@example.net" \
  "128 icon_128x128.png" \
  "256 wendy.h@example.net" \
  "256 icon_256x256.png" \
  "512 wendy.h@example.net" \
  "512 icon_512x512.png" \
  "1024 walt.e@example.net"
do
  # shellcheck disable=SC2086
  set -- $spec
  sips -z "$1" "$1" "$src" --out "$set/$2" >/dev/null
done
iconutil -c icns "$set" -o "$res/AppIcon.icns"
rm -rf "$set"
echo "wrote $res/AppIcon.icns"
echo "Re-run macos/build-app.sh to install into Cue.app"
