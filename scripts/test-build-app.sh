#!/usr/bin/env bash
# Run the real build-app.sh against fake SwiftPM and Xcode tools in a throwaway root; nothing compiles or signs.
set -euo pipefail
src=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
root="$work/root"; bin="$work/bin"; mkdir -p "$root/scripts" "$root/Resources/AppIcon.icon" "$bin"
cp "$src/scripts/build-app.sh" "$src/scripts/check-archs.sh" "$src/scripts/version.py" "$root/scripts/"
printf '4.5.6\n' > "$root/VERSION"
cat > "$bin/swift" <<'FAKE'
#!/bin/bash
# Products live under the scratch path; a default product is deliberately stale.
[ "$1" = build ] || exit 64; shift
config=debug; scratch="$ROOT/.build"; archs=(); show=0
while [ $# -gt 0 ]; do
	case "$1" in
		-c) config=$2; shift ;;
		--arch) archs+=("$2"); shift ;;
		--scratch-path) scratch=$2; shift ;;
		--show-bin-path) show=1 ;;
	esac; shift
done
out="$scratch/out/$config"
echo "${archs[*]-host} ${scratch#$ROOT/} $([ "$show" = 1 ] && echo lookup || echo build)" >> "$SCRATCH_LOG"
if [ "$show" = 1 ]; then echo "$out"; [ "${FAIL_LOOKUP:-}" = 1 ] && exit 1; exit 0; fi
echo "${archs[*]-host}" >> "$LOG"
mkdir -p "$out/KeyboardShortcuts_KeyboardShortcuts.bundle"
printf 'arch:%s\n' "${archs[*]-arm64}" > "$out/Copia"; chmod +x "$out/Copia"
printf '%s\n' "${archs[*]-host}" > "$out/KeyboardShortcuts_KeyboardShortcuts.bundle/origin"
FAKE
cat > "$bin/lipo" <<'FAKE'
#!/bin/sh
[ "$1" = -archs ] && sed -n 's/^arch://p' "$2"
FAKE
cat > "$bin/xcrun" <<'FAKE'
#!/bin/bash
case "$1" in
	actool) shift; while [ $# -gt 0 ]; do [ "$1" = --compile ] && { mkdir -p "$2"; : > "$2/Assets.car"; : > "$2/AppIcon.icns"; }; shift; done ;;
	vtool) printf 'platform MACOS\nminos 26.0\n' ;;
	*) exit 64 ;;
esac
FAKE
cat > "$bin/codesign" <<'FAKE'
#!/bin/sh
echo "codesign $*" >> "$LOG"
FAKE
cat > "$bin/ditto" <<'FAKE'
#!/bin/sh
for last; do :; done; : > "$last"
FAKE
chmod +x "$bin"/*
fresh() { rm -rf "$root/dist" "$root/.build"; : > "$work/log"; : > "$work/scratch"; }
run() { PATH="$bin:/usr/bin:/bin" ROOT="$root" LOG="$work/log" SCRATCH_LOG="$work/scratch" DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" "$root/scripts/build-app.sh" "$@" > "$work/out" 2>&1; }


fresh; mkdir -p "$root/.build/out/release"; printf 'arch:arm64 x86_64\n' > "$root/.build/out/release/Copia"
run --unsigned || { cat "$work/out"; echo 'unsigned release build failed'; exit 1; }
for arch in arm64 x86_64; do
	app="$root/dist/$arch/Copia.app/Contents"
	[ "$(cat "$app/MacOS/Copia")" = "arch:$arch" ] || { echo "$arch app has the wrong executable"; exit 1; }
	[ "$(cat "$app/Resources/KeyboardShortcuts_KeyboardShortcuts.bundle/origin")" = "$arch" ] || { echo "$arch app has the wrong resources"; exit 1; }
	grep -q '<string>26.0</string>' "$app/Info.plist" || { echo "$arch floor missing"; exit 1; }
	[ -f "$root/dist/Copia-4.5.6-$arch.zip" ] || { echo "missing $arch ZIP"; exit 1; }
done
[ "$(ls "$root/dist" | LC_ALL=C sort | tr '\n' ' ')" = 'Copia-4.5.6-arm64.zip Copia-4.5.6-x86_64.zip arm64 x86_64 ' ] || { ls "$root/dist"; echo 'unexpected dist layout'; exit 1; }
[ "$(grep -cv codesign "$work/log")" = 2 ] && grep -qx arm64 "$work/log" && grep -qx x86_64 "$work/log" || { cat "$work/log"; echo 'expected one thin build per architecture'; exit 1; }
! grep -q codesign "$work/log" || { echo 'unsigned build signed'; exit 1; }
expected='arm64 .build/release-arm64 build
arm64 .build/release-arm64 lookup
x86_64 .build/release-x86_64 build
x86_64 .build/release-x86_64 lookup'
[ "$(cat "$work/scratch")" = "$expected" ] || { cat "$work/scratch"; echo 'each architecture must build and look up its own scratch path'; exit 1; }

fresh; ! FAIL_LOOKUP=1 run --unsigned || { echo 'a failed product lookup still packaged an app'; exit 1; }
[ ! -e "$root/dist/Copia-4.5.6-arm64.zip" ] || { echo 'ZIP written after a failed product lookup'; exit 1; }
fresh; ! FAIL_LOOKUP=1 run --debug || { echo 'a failed debug lookup still assembled an app'; exit 1; }

fresh; run || { cat "$work/out"; echo 'signed release build failed'; exit 1; }
[ "$(grep -c '^codesign --force' "$work/log")" = 2 ] && [ "$(grep -c '^codesign --verify' "$work/log")" = 2 ] || { cat "$work/log"; echo 'each app must be signed and verified'; exit 1; }
grep -q -- '--timestamp=none' "$work/log" || { echo 'local signing must not request a timestamp'; exit 1; }

fresh; run --debug || { cat "$work/out"; echo 'debug build failed'; exit 1; }
[ "$(ls "$root/dist")" = Copia.app ] && [ -x "$root/dist/Copia.app/Contents/MacOS/Copia" ] || { ls -R "$root/dist"; echo 'debug must build only the host app'; exit 1; }
[ "$(grep -v codesign "$work/log")" = host ] || { cat "$work/log"; echo 'debug must not request architectures'; exit 1; }

fresh; printf 'arch:arm64 x86_64\n' > "$work/universal"
cat > "$bin/lipo" <<'FAKE'
#!/bin/sh
[ "$1" = -archs ] && echo 'arm64 x86_64'
FAKE
chmod +x "$bin/lipo"
! run --unsigned || { echo 'a universal binary passed as a thin app'; exit 1; }
[ ! -e "$root/dist/Copia-4.5.6-arm64.zip" ] || { echo 'ZIP written despite failed architecture check'; exit 1; }
echo 'ok   one signed thin app and ZIP per architecture; debug is host-only'
