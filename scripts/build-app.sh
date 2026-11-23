#!/usr/bin/env bash
# Builds one thin Copia.app and ZIP per architecture: release binary, icon, KeyboardShortcuts resources, signing.
# Usage: scripts/build-app.sh [--unsigned] [--debug]   (--debug: host-only dist/Copia.app, no ZIP)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
VERSION="$(python3 -I "$ROOT/scripts/version.py" "$ROOT/VERSION")"
IDENTITY="${COPIA_SIGN_IDENTITY:-Apple Development}"
SIGN=1
CONFIG=release
for arg in "$@"; do
	case "$arg" in
		--unsigned) SIGN=0 ;;
		--debug) CONFIG=debug ;;
	esac
done

cd "$ROOT"
DIST="$ROOT/dist"

# Assemble, sign and check one app from a SwiftPM product directory.
assemble() {
	local bin=$1 app=$2
	rm -rf "$app"
	mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
	cp "$bin/Copia" "$app/Contents/MacOS/Copia"

	# KeyboardShortcuts localizations, loaded through Bundle.module.
	local resources="$bin/KeyboardShortcuts_KeyboardShortcuts.bundle"
	[ -d "$resources" ] || { echo "missing $resources" >&2; exit 1; }
	cp -R "$resources" "$app/Contents/Resources/"

	# Liquid Glass icon from the Icon Composer package (Assets.car + AppIcon.icns fallback).
	xcrun actool "$ROOT/Resources/AppIcon.icon" --compile "$app/Contents/Resources" --platform macosx \
		--minimum-deployment-target 26.0 --app-icon AppIcon \
		--output-partial-info-plist "$(mktemp -d)/partial.plist" >/dev/null
	[ -f "$app/Contents/Resources/Assets.car" ] || { echo "icon compile failed" >&2; exit 1; }

	cat > "$app/Contents/Info.plist" <<PLIST
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
		local timestamp=--timestamp=none
		[ "${COPIA_TIMESTAMP:-0}" = 1 ] && timestamp=--timestamp
		codesign --force --deep --sign "$IDENTITY" --options runtime "$timestamp" "$app"
		codesign --verify --deep --strict "$app"
	fi
}

if [ "$CONFIG" = debug ]; then
	swift build -c debug --product Copia
	bin=$(swift build -c debug --show-bin-path)
	assemble "$bin" "$DIST/Copia.app"
	echo "$DIST/Copia.app"
	exit 0
fi

rm -rf "$DIST/Copia.app" "$DIST/Copia-$VERSION.zip"
for arch in arm64 x86_64; do
	# Separate scratch paths: one shared product directory would let one architecture package the other's binary.
	scratch="$ROOT/.build/release-$arch"
	swift build -c release --arch "$arch" --scratch-path "$scratch" --product Copia
	app="$DIST/$arch/Copia.app"
	bin=$(swift build -c release --arch "$arch" --scratch-path "$scratch" --show-bin-path)
	assemble "$bin" "$app"
	"$ROOT/scripts/check-archs.sh" "$app/Contents/MacOS/Copia" "$arch"
	zip="$DIST/Copia-$VERSION-$arch.zip"
	rm -f "$zip"
	ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
	echo "$zip"
done
