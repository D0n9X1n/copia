#!/usr/bin/env bash
# Fails unless BINARY carries both the arm64 and the x86_64 slice.
# Usage: scripts/check-archs.sh BINARY   (self-test: scripts/test-check-archs.sh)
set -euo pipefail

BINARY="${1:?usage: scripts/check-archs.sh BINARY}"
ARCHS="$(lipo -archs "$BINARY")" || { echo "cannot read the slices of $BINARY" >&2; exit 1; }
for arch in arm64 x86_64; do
	case " $ARCHS " in
		*" $arch "*) ;;
		*) echo "$BINARY is missing the $arch slice (has: $ARCHS)" >&2; exit 1 ;;
	esac
done
echo "$BINARY: $ARCHS"
