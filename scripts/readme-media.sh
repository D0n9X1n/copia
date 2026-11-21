#!/bin/bash
# Renders the README's product shots from fixture data into .github/media/.
# Needs a display, Xcode 27 (for Icon Composer's ictool) and cwebp. Takes over the top-left of the main display for a minute.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
out=.github/media
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

swift build -q --product copia-render
swift run -q copia-render --readme --output "$tmp"
mkdir -p "$out"
for png in "$tmp"/*.png; do
	name="$(basename "$png" .png)"
	case "$name" in
		icon-*) cp "$png" "$out/$name.png" ;;
		*) cwebp -quiet -q 90 -alpha_q 100 -m 6 "$png" -o "$out/$name.webp" ;;
	esac
done
ls -l "$out"
