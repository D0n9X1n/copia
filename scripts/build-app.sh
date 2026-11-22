#!/usr/bin/env bash
# Builds Copia.app: universal release binary, icon, KeyboardShortcuts resources, signing, zip.
# Usage: scripts/build-app.sh [--unsigned] [--debug]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
VERSION="$(python3 -I "$ROOT/scripts/version.py" "$ROOT/VERSION")"
IDENTITY="${COPIA_SIGN_IDENTITY:-Apple Development}"
SIGN=1
CONFIG=release
ARCHS=(--arch arm64 --arch x86_64)
for arg in "$@"; do
	case "$arg" in
		--unsigned) SIGN=0 ;;
		--debug) CONFIG=debug; ARCHS=() ;;
	esac
done

cd "$ROOT"
swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} --product Copia
BIN="$(swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)"

DIST="$ROOT/dist"
APP="$DIST/Copia.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Copia" "$APP/Contents/MacOS/Copia"

# KeyboardShortcuts localizations, loaded through Bundle.module.
RESOURCES="$BIN/KeyboardShortcuts_KeyboardShortcuts.bundle"
[ -d "$RESOURCES" ] || { echo "missing $RESOURCES" >&2; exit 1; }
cp -R "$RESOURCES" "$APP/Contents/Resources/"

# Liquid Glass icon from the Icon Composer package (Assets.car + AppIcon.icns fallback).
xcrun actool "$ROOT/Resources/AppIcon.icon" --compile "$APP/Contents/Resources" --platform macosx \
	--minimum-deployment-target 26.0 --app-icon AppIcon \
	--output-partial-info-plist "$(mktemp -d)/partial.plist" >/dev/null
[ -f "$APP/Contents/Resources/Assets.car" ] || { echo "icon compile failed" >&2; exit 1; }

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>Copia</string>
	<key>CFBundleDisplayName</key><string>Copia</string>
	<key>CFBundleIdentifier</key><string>app.copia.Copia</string>
	<key>CFBundleExecutable</key><string>Copia</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleIconName</key><string>AppIcon</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$VERSION</string>
	<key>LSMinimumSystemVersion</key><string>26.0</string>
	<key>LSUIElement</key><true/>
	<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
	<key>NSHumanReadableCopyright</key><string>Copia</string>
</dict>
</plist>
PLIST

if [ "$SIGN" = 1 ]; then
	# A secure timestamp (release builds) keeps the signature valid after the certificate expires; it needs the network.
	TIMESTAMP=--timestamp=none
	[ "${COPIA_TIMESTAMP:-0}" = 1 ] && TIMESTAMP=--timestamp
	codesign --force --deep --sign "$IDENTITY" --options runtime "$TIMESTAMP" "$APP"
	codesign --verify --deep --strict "$APP"
fi

if [ "$CONFIG" = release ]; then
	# A release build must hold both slices; a debug build is the host slice only.
	"$ROOT/scripts/check-archs.sh" "$APP/Contents/MacOS/Copia"
	rm -f "$DIST/Copia-$VERSION.zip"
	ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/Copia-$VERSION.zip"
	echo "$DIST/Copia-$VERSION.zip"
fi
echo "$APP"
