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
# Every policy call must succeed, and the environment must be tag-only, before any secret is stored.
POLICIES="repos/$REPO/environments/release/deployment-branch-policies"
list_policies() {
	gh api --paginate "$POLICIES" --jq '.branch_policies[] | "\(.id) \(.type) \(.name)"' \
		|| { echo "cannot list the release environment's deployment policies" >&2; exit 1; }
}
gh api -X PUT "repos/$REPO/environments/release" --input - >/dev/null <<JSON \
	|| { echo "cannot set the release environment to custom deployment policies" >&2; exit 1; }
{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
JSON
EXISTING="$(list_policies)"
HAS_TAG=0
while read -r id type name; do
	[ -n "$id" ] || continue
	if [ "$type" = tag ] && [ "$name" = 'v*' ]; then HAS_TAG=1; continue; fi
	echo "removing deployment policy $type '$name'"
	gh api -X DELETE "$POLICIES/$id" >/dev/null || { echo "cannot remove deployment policy $type '$name'" >&2; exit 1; }
done <<< "$EXISTING"
if [ "$HAS_TAG" = 0 ]; then
	gh api -X POST "$POLICIES" -f name='v*' -f type=tag >/dev/null || { echo "cannot add the v* tag policy" >&2; exit 1; }
fi
FINAL="$(list_policies)"
if [ "$(printf '%s\n' "$FINAL" | grep -c .)" != 1 ] || ! printf '%s\n' "$FINAL" | grep -Eqx '[0-9]+ tag v\*'; then
	echo "the release environment is not tag-only; its policies are:" >&2
	printf '%s\n' "$FINAL" >&2
	exit 1
fi

base64 < "$P12" | tr -d '\n' | gh secret set SIGNING_CERT_P12_BASE64 --env release --repo "$REPO"
printf '%s' "$PASSWORD" | gh secret set SIGNING_CERT_PASSWORD --env release --repo "$REPO"
unset PASSWORD
gh secret list --env release --repo "$REPO"
echo "Done. Delete $P12 when you no longer need it."
