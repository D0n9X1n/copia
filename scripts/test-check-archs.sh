#!/usr/bin/env bash
# Self-test for scripts/check-archs.sh: it must reject a single-slice binary and accept a universal one.
# Builds both from a one-line C file, so it needs only the Xcode toolchain.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo 'int main(void) { return 0; }' > "$WORK/main.c"
xcrun clang -arch arm64 -o "$WORK/single" "$WORK/main.c"
xcrun clang -arch arm64 -arch x86_64 -o "$WORK/universal" "$WORK/main.c"

ok=1
if "$ROOT/scripts/check-archs.sh" "$WORK/single" >/dev/null 2>&1; then
	echo "FAIL single-slice: accepted"; ok=0
else
	echo "ok   single-slice: rejected"
fi
if "$ROOT/scripts/check-archs.sh" "$WORK/universal" >/dev/null 2>&1; then
	echo "ok   universal: accepted"
else
	echo "FAIL universal: rejected"; ok=0
fi
if "$ROOT/scripts/check-archs.sh" "$WORK/missing" >/dev/null 2>&1; then
	echo "FAIL missing binary: accepted"; ok=0
else
	echo "ok   missing binary: rejected"
fi
[ "$ok" = 1 ]
