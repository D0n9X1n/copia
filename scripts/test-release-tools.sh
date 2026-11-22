#!/usr/bin/env bash
# Full offline release-tool suite. Does not build, sign, or run Copia.
set -euo pipefail
s=$(cd "$(dirname "$0")" && pwd)
for t in "$s"/test-*.py; do python3 -I "$t"; done
"$s/test-check-archs.sh"
"$s/test-setup-release-signing.sh"
python3 -I "$s/check-wiki.py"
python3 -I "$s/check-wiki.py" --self-test
