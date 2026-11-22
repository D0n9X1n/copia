#!/usr/bin/env bash
# Each download holds exactly one named architecture; check its actual deployment target, not the build SDK.
set -euo pipefail
binary=${1:?usage: check-archs.sh BINARY ARCH}
arch=${2:?usage: check-archs.sh BINARY ARCH}
case "$arch" in arm64|x86_64) ;; *) echo "unknown architecture: $arch" >&2; exit 1 ;; esac
archs=$(lipo -archs "$binary")
read -r -a slices <<< "$archs"
[[ "${slices[*]-}" == "$arch" ]] || { echo "expected only $arch, found: $archs" >&2; exit 1; }
xcrun vtool -arch "$arch" -show-build "$binary" | awk '
    $1 == "platform" { platforms++; mac += ($2 == "MACOS") }
    $1 == "minos" { floors++; correct += ($2 ~ /^26\.0$/) }
    END { exit !(platforms == 1 && mac == 1 && floors == 1 && correct == 1) }
' || { echo "expected $arch macOS 26.0 in $binary" >&2; exit 1; }
