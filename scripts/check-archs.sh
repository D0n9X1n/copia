#!/usr/bin/env bash
# Check the actual deployment target of each shipped slice, not the build SDK.
set -euo pipefail
binary=${1:?usage: check-archs.sh BINARY}
archs=$(lipo -archs "$binary")
read -r -a slices <<< "$archs"
case "${slices[*]}" in
    'arm64 x86_64'|'x86_64 arm64') ;;
    *) echo "unexpected slices: $archs" >&2; exit 1 ;;
esac
for arch in arm64 x86_64; do
    xcrun vtool -arch "$arch" -show-build "$binary" | awk '
        $1 == "platform" { platforms++; mac += ($2 == "MACOS") }
        $1 == "minos" { floors++; correct += ($2 ~ /^26\.0$/) }
        END { exit !(platforms == 1 && mac == 1 && floors == 1 && correct == 1) }
    ' || { echo "expected $arch macOS 26.0 in $binary" >&2; exit 1; }
done
