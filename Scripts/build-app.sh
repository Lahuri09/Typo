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
codesign --force --sign "${TYPO_SIGN_IDENTITY:--}" "$app"
codesign --verify --strict "$app"
printf '%s\n' "$app"
