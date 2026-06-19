#!/usr/bin/env bash
# Opt-in: estos tests invocan modelos reales y consumen tokens.
# NO se incluyen en tests/run-all.sh ni en CI.
set -euo pipefail
cd "$(dirname "$0")"
for t in test_*.sh; do
  echo "== $t"
  bash "$t"
done
echo "PROMPT TESTS: OK"
