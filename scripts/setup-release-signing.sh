#!/usr/bin/env bash
# One-time setup: stores the signing certificate as secrets of a `release` environment that only `v*` tags may use.
# Usage: scripts/setup-release-signing.sh path/to/certificate.p12   (prompts for the .p12 password; needs `gh` logged in)
set -euo pipefail

P12="${1:?usage: scripts/setup-release-signing.sh certificate.p12}"
[ -f "$P12" ] || { echo "no such file: $P12" >&2; exit 1; }
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"

read -rsp "Password of $P12: " PASSWORD; echo
# Fail early on a wrong password or a file without a private key.
openssl pkcs12 -in "$P12" -passin "pass:$PASSWORD" -nocerts -nodes -legacy 2>/dev/null | grep -q "PRIVATE KEY" \
	|| openssl pkcs12 -in "$P12" -passin "pass:$PASSWORD" -nocerts -nodes 2>/dev/null | grep -q "PRIVATE KEY" \
	|| { echo "cannot read a private key from $P12 with that password" >&2; exit 1; }

# The environment only accepts deployments from v* tags, so branches, pull requests and forks never see the secrets.
gh api -X PUT "repos/$REPO/environments/release" --input - >/dev/null <<JSON
{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
JSON
gh api -X POST "repos/$REPO/environments/release/deployment-branch-policies" -f name='v*' -f type=tag >/dev/null 2>&1 || true

base64 < "$P12" | tr -d '\n' | gh secret set SIGNING_CERT_P12_BASE64 --env release --repo "$REPO"
printf '%s' "$PASSWORD" | gh secret set SIGNING_CERT_PASSWORD --env release --repo "$REPO"
unset PASSWORD
gh secret list --env release --repo "$REPO"
echo "Done. Delete $P12 when you no longer need it."
