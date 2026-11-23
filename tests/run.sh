#!/bin/bash
# Runs every shell test and every node test. Works on macOS, Linux and Windows (Git Bash).
set -u
cd "$(dirname "$0")/.."
rc=0
for t in tests/sh/*.test.sh; do
  echo "== $t"
  bash "$t" || rc=1
done
if command -v pwsh >/dev/null 2>&1; then
  echo "== tests/ps1/archive-layout.ps1"
  pwsh -NoProfile -File tests/ps1/archive-layout.ps1 || rc=1
fi
if ls tests/ts/*.test.mjs >/dev/null 2>&1; then
  echo "== node tests"
  for t in tests/ts/*.test.mjs; do
    # one process per test file: the extension reads HOME at import time
    node --experimental-strip-types --no-warnings --test "$t" || rc=1
  done
fi
[[ $rc == 0 ]] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"
exit $rc
