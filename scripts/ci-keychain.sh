#!/usr/bin/env bash
# Imports the signing certificate from SIGNING_CERT_P12_BASE64 / SIGNING_CERT_PASSWORD into a temporary keychain
# on a CI runner, and exports COPIA_SIGN_IDENTITY and KEYCHAIN_PATH to later steps. Used by .github/workflows/release.yml.
set -euo pipefail

: "${SIGNING_CERT_P12_BASE64:?missing secret SIGNING_CERT_P12_BASE64}"
: "${SIGNING_CERT_PASSWORD:?missing secret SIGNING_CERT_PASSWORD}"
WORK="${RUNNER_TEMP:?not on a CI runner}"
KEYCHAIN="$WORK/copia-signing.keychain-db"
P12="$WORK/copia-signing.p12"
WWDR="$WORK/AppleWWDRCAG3.cer"
# Apple's Worldwide Developer Relations G3 intermediate, pinned by SHA-256 (valid to 2030-02-20).
WWDR_SHA256="dcf21878c77f4198e4b4614f03d696d89c66c66008d4244e1b99161aac91601f"

KEYCHAIN_PASSWORD="$(openssl rand -base64 24)"
echo "::add-mask::$KEYCHAIN_PASSWORD"

printf '%s' "$SIGNING_CERT_P12_BASE64" | base64 --decode > "$P12"
curl -fsSL https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer -o "$WWDR"
echo "$WWDR_SHA256  $WWDR" | shasum -a 256 -c -

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 3600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$WWDR" -k "$KEYCHAIN" -T /usr/bin/codesign
security import "$P12" -k "$KEYCHAIN" -P "$SIGNING_CERT_PASSWORD" -f pkcs12 -T /usr/bin/codesign
rm -f "$P12"
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
EXISTING=()
while IFS= read -r line; do
	line="${line#"${line%%[![:space:]]*}"}"
	[ -n "$line" ] && EXISTING+=("${line//\"/}")
done < <(security list-keychains -d user)
security list-keychains -d user -s "$KEYCHAIN" "${EXISTING[@]}"

# Sign by certificate hash so the name never has to appear in logs or the workflow.
# -v keeps only identities that chain to Apple; COPIA_CI_DRY_RUN=1 accepts a self-signed test certificate.
VALID=-v
[ "${COPIA_CI_DRY_RUN:-0}" = 1 ] && VALID=
IDENTITY="$(security find-identity $VALID -p codesigning "$KEYCHAIN" | awk '$2 ~ /^[0-9A-F]{40}$/ { print $2; exit }')"
[ -n "$IDENTITY" ] || { echo "no code signing identity in the imported certificate" >&2; exit 1; }
{
	echo "COPIA_SIGN_IDENTITY=$IDENTITY"
	echo "KEYCHAIN_PATH=$KEYCHAIN"
} >> "${GITHUB_ENV:?}"
echo "signing identity ready"
