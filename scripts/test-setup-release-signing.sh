#!/usr/bin/env bash
# Self-test for scripts/setup-release-signing.sh against a fake `gh` and `openssl`. It never reaches GitHub:
# PATH holds only the fakes and /usr/bin:/bin, and the fake gh refuses any call it does not expect.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAKE="$WORK/bin"
SAFE_PATH="$FAKE:/usr/bin:/bin"
mkdir -p "$FAKE"
: > "$WORK/cert.p12"

cat > "$FAKE/gh" <<'GH'
#!/bin/bash
# Fake gh: logs each call; the environment's deployment policies live in $STATE as "id type name" lines.
args="$*"
echo "$args" >> "$LOG"
fail_if() { if [ "${FAIL:-}" = "$1" ]; then echo "fake gh: $1 failed" >&2; exit 1; fi; }
policies="repos/owner/repo/environments/release/deployment-branch-policies"
case "$args" in
	"repo view --json nameWithOwner -q .nameWithOwner") echo owner/repo ;;
	"api -X PUT repos/owner/repo/environments/release --input -") cat >/dev/null; fail_if put ;;
	"api --paginate $policies --jq "*)
		[ "${args#*--jq }" = '.branch_policies[] | "\(.id) \(.type) \(.name)"' ] || { echo "fake gh: unexpected jq" >&2; exit 98; }
		fail_if list; cat "$STATE" ;;
	"api -X POST $policies -f name=v* -f type=tag")
		fail_if post; echo "$(( $(wc -l < "$STATE") + 100 )) tag v*" >> "$STATE" ;;
	"api -X DELETE $policies/"*)
		fail_if delete
		if [ -z "${STICKY:-}" ]; then { grep -v "^${args##*/} " "$STATE" || true; } > "$STATE.new"; mv "$STATE.new" "$STATE"; fi ;;
	"secret set "*) cat >/dev/null ;;
	"secret list --env release --repo owner/repo") echo SIGNING_CERT_P12_BASE64; echo SIGNING_CERT_PASSWORD ;;
	*) echo "fake gh: unexpected call: $args" >&2; exit 97 ;;
esac
GH
cat > "$FAKE/openssl" <<'SSL'
#!/bin/bash
echo "-----BEGIN PRIVATE KEY-----"
SSL
chmod +x "$FAKE/gh" "$FAKE/openssl"
[ "$(PATH="$SAFE_PATH"; command -v gh)" = "$FAKE/gh" ] || { echo "the fake gh is not first on PATH; refusing to run" >&2; exit 1; }

ok=1
# run NAME EXPECT(pass|fail) INITIAL_STATE FINAL_REGEX [FAIL_STEP] [STICKY]
run() {
	local name="$1" expect="$2" state="$3" final="$4" fail="${5:-}" sticky="${6:-}" code=0 why=""
	printf '%b' "$state" > "$WORK/state"
	: > "$WORK/log"
	env -i PATH="$SAFE_PATH" HOME="$WORK" LOG="$WORK/log" STATE="$WORK/state" FAIL="$fail" STICKY="$sticky" \
		/bin/bash "$ROOT/scripts/setup-release-signing.sh" "$WORK/cert.p12" <<< 'password' > "$WORK/out" 2>&1 || code=$?
	local secrets last_api first_secret
	secrets="$(grep -c '^secret set ' "$WORK/log" || true)"
	if [ "$expect" = pass ]; then
		last_api="$(grep -n '^api ' "$WORK/log" | tail -1 | cut -d: -f1)"
		first_secret="$(grep -n '^secret set ' "$WORK/log" | head -1 | cut -d: -f1)"
		if [ "$code" != 0 ]; then why="exited $code"
		elif [ "$(grep -c . "$WORK/state" || true)" != 1 ] || ! grep -Eqx "$final" "$WORK/state"; then why="policies left: $(tr '\n' ';' < "$WORK/state")"
		elif [ "$secrets" != 2 ]; then why="$secrets secrets stored"
		elif [ -z "$last_api" ] || [ "$first_secret" -lt "$last_api" ]; then why="a secret was stored before the policies were final"
		fi
	else
		if [ "$code" = 0 ]; then why="succeeded"
		elif [ "$secrets" != 0 ]; then why="stored $secrets secret(s) despite the failure"
		fi
	fi
	if [ -z "$why" ]; then echo "ok   $name"; else echo "FAIL $name: $why"; sed 's/^/     | /' "$WORK/out"; ok=0; fi
}

run "keeps only the v* tag policy"        pass '1 branch main\n2 tag v*\n3 tag release-*\n4 branch *\n' '2 tag v\*'
run "adds the v* tag policy when missing" pass ''                                         '[0-9]+ tag v\*'
run "replaces a branch policy named v*"   pass '5 branch v*\n'                            '[0-9]+ tag v\*'
run "a failed delete stores no secret"    fail '1 branch main\n2 tag v*\n'                '' delete
run "a failed listing stores no secret"   fail '2 tag v*\n'                               '' list
run "a failed environment update stores no secret" fail ''                                '' put
run "a failed tag policy add stores no secret"     fail ''                                '' post
run "a delete that did not stick stores no secret" fail '1 branch main\n2 tag v*\n'       '' '' sticky
[ "$ok" = 1 ]
