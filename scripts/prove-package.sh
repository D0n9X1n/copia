#!/usr/bin/env bash
# Verify both architecture ZIPs, then smoke the host-native app from its own ZIP (never the pre-archive app).
# Usage: prove-package.sh signed|unsigned NEW_DIR [RECEIVED_ASSETS_DIR]   or   prove-package.sh --native-arch
set -euo pipefail
# An Intel runtime under Rosetta is not evidence of native Intel coverage.
translated=$(sysctl -in sysctl.proc_translated)
case "$translated" in
    0|'') ;;
    1) echo "translated (Rosetta) process" >&2; exit 1 ;;
    *) echo "unknown translation state" >&2; exit 1 ;;
esac
arm=$(sysctl -in hw.optional.arm64)
case "$arm" in
    1) native=arm64 ;;
    0|'') machine=$(uname -m); [[ $machine == x86_64 ]] || exit 1; native=x86_64 ;;
    *) echo "unknown host architecture" >&2; exit 1 ;;
esac
if [[ ${1:-} == --native-arch ]]; then echo "$native"; exit 0; fi
mode=${1:?signed or unsigned}; work=${2:?new evidence directory}; received=${3:-}
root=$(cd "$(dirname "$0")/.." && pwd)
version=$(python3 -I "$root/scripts/version.py" "$root/VERSION")
mkdir -m 700 "$work"; mkdir "$work/assets"
for arch in arm64 x86_64; do
    name=Copia-$version-$arch.zip
    if [[ -n $received ]]; then
        # Already received and digest-checked: keep the shipped sidecars, never regenerate them.
        cp "$received/$name" "$received/$name.sha256" "$work/assets/"
    else
        cp "$root/dist/$name" "$work/assets/$name"
        (cd "$work/assets" && shasum -a 256 "$name") > "$work/assets/$name.sha256"
    fi
done
python3 -I "$root/scripts/release-assets.py" verify "$work/assets" "$version" "$work/unpacked" "$mode"
# Bind the publisher to the checksums that passed verification, before the runtime smoke.
for arch in arm64 x86_64; do
    read -r reviewed _ < "$work/assets/Copia-$version-$arch.zip.sha256"
    printf '%s\n' "$reviewed" > "$work/zip-sha-$arch.txt"
    if [[ -n ${GITHUB_OUTPUT:-} ]]; then printf 'zip-sha-%s=%s\n' "$arch" "$reviewed" >> "$GITHUB_OUTPUT"; fi
done
/usr/bin/arch "-$native" "$work/unpacked/$native/Copia.app/Contents/MacOS/Copia" --selftest "$work/smoke.json"
os_version=$(sw_vers -productVersion)
python3 -I "$root/scripts/package-proof.py" runtime "$work/smoke.json" "Copia-$version-$native.zip" "$native" "$os_version" > "$work/coverage.txt"
cat "$work/coverage.txt"
