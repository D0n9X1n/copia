#!/usr/bin/env bash
# Verify, then smoke the native slice from the ZIP (never the pre-archive app).
set -euo pipefail
# An Intel runtime under Rosetta is not evidence of native Intel coverage.
arm=$(sysctl -in hw.optional.arm64)
case "$arm" in
    1) native=arm64 ;;
    0|'') [[ $(uname -m) == x86_64 ]] || exit 1; native=x86_64 ;;
    *) echo "unknown host architecture" >&2; exit 1 ;;
esac
if [[ ${1:-} == --native-arch ]]; then echo "$native"; exit 0; fi
mode=${1:?signed or unsigned}; work=${2:?new evidence directory}
root=$(cd "$(dirname "$0")/.." && pwd)
version=$(python3 -I "$root/scripts/version.py" "$root/VERSION")
mkdir -m 700 "$work"; mkdir "$work/assets"
name=Copia-$version.zip
cp "$root/dist/$name" "$work/assets/$name"
(cd "$work/assets" && shasum -a 256 "$name") > "$work/assets/$name.sha256"
python3 -I "$root/scripts/release-assets.py" verify "$work/assets" "$version" "$work/unpacked" "$mode"
# Bind the publisher to the checksum that passed verification, before the runtime smoke.
read -r reviewed _ < "$work/assets/$name.sha256"
if [[ -n ${GITHUB_OUTPUT:-} ]]; then printf 'zip-sha=%s\n' "$reviewed" >> "$GITHUB_OUTPUT"; fi
/usr/bin/arch "-$native" "$work/unpacked/Copia.app/Contents/MacOS/Copia" --selftest "$work/smoke.json"
sdk=$(xcrun --sdk macosx --show-sdk-version); xcode=$(xcodebuild -version); swift_version=$(swift --version); os=$(sw_vers -productVersion)
python3 -I "$root/scripts/package-proof.py" "$work/smoke.json" "$native" "$os" "$sdk" "$xcode" "$swift_version" > "$work/coverage.txt"
cat "$work/coverage.txt"
