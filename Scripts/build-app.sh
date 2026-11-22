#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product Typo
binary_dir="$(swift build -c release --show-bin-path)"
app="$PWD/dist/Typo.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
ditto "$binary_dir/Typo_TypoCore.bundle" "$app/Contents/Resources/Typo_TypoCore.bundle"
install -m 755 "$binary_dir/Typo" "$app/Contents/MacOS/Typo"
install -m 644 Info.plist "$app/Contents/Info.plist"
icon_work="$(mktemp -d)"
trap 'rm -rf "$icon_work"' EXIT
swift Scripts/make-icon.swift "$icon_work/master.png"
mkdir "$icon_work/TypoAI.iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$icon_work/master.png" --out "$icon_work/TypoAI.iconset/icon_${size}x${size}.png" >/dev/null
    doubled=$((size * 2))
    sips -z "$doubled" "$doubled" "$icon_work/master.png" --out "$icon_work/TypoAI.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$icon_work/TypoAI.iconset" -o "$app/Contents/Resources/TypoAI.icns"
if [[ "${TYPO_BUNDLE_LOCAL_AI:-0}" == 1 ]]; then
    ./Scripts/bundle-local-ai.sh "$app/Contents/Resources/LocalAI"
fi
codesign --force --sign "${TYPO_SIGN_IDENTITY:--}" "$app"
codesign --verify --strict "$app"
printf '%s\n' "$app"
