#!/usr/bin/env bash
# Feed lipo and vtool transcripts to the real checker; no compiler or private binary needed.
set -eu
root=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cat > "$work/lipo" <<'FAKE'
#!/bin/sh
[ "$1" = -archs ] && [ -f "$2" ] && echo "$ARCHS"
FAKE
cat > "$work/xcrun" <<'FAKE'
#!/bin/sh
[ "$1" = vtool ] && [ "$2" = -arch ] && [ "$4" = -show-build ] && [ -f "$5" ] || exit 1
case "$3" in arm64) floor=$ARM;; x86_64) floor=$INTEL;; *) exit 1;; esac
printf 'Load command 1\n      cmd LC_BUILD_VERSION\n platform %s\n    minos %s\n      sdk 27.2\n' "${PLATFORM:-MACOS}" "$floor"
FAKE
chmod +x "$work/lipo" "$work/xcrun"; touch "$work/app"
check() {
    local got=pass
    PATH="$work:/usr/bin:/bin" ARCHS="$2" ARM="$3" INTEL="$4" PLATFORM="${5:-MACOS}" \
        "$root/check-archs.sh" "$work/app" >/dev/null 2>&1 || got=fail
    [ "$1" = "$got" ] || { echo "unexpected $got: $*"; exit 1; }
}
check pass 'arm64 x86_64' 26.0 26.0
check pass 'x86_64 arm64' 26.0 26.0
check pass ' x86_64   arm64 ' 26.0 26.0
check fail 'arm64' 26.0 26.0
check fail 'x86_64' 26.0 26.0
check fail 'arm64 x86_64 arm64e' 26.0 26.0
check fail 'arm64 x86_64' 26.1 26.0
check fail 'arm64 x86_64' 26.0 25.0
check fail 'arm64 x86_64' 26.0 ''
check fail 'arm64 x86_64' 26.0 26.0 IOS
echo 'ok   exact architecture set and macOS 26.0 per slice'
