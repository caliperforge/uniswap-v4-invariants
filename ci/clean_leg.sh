#!/usr/bin/env bash
# Clean leg: every non-planted suite must pass, and no INVARIANT
# VIOLATED marker may appear anywhere in the output.
#
# Optional first arg: a forge `--match-path` glob to scope the leg to
# one suite subtree (used by bring-your-hook.yml, which points at
# test/bring-your-hook/*). Omit for the repo-wide leg.
set -uo pipefail

match_path="${1:-}"

if [ -n "$match_path" ]; then
  out=$(forge test --match-path "$match_path" --no-match-contract 'Planted$' -vv 2>&1)
else
  out=$(forge test --no-match-contract 'Planted$' -vv 2>&1)
fi
rc=$?
echo "$out"

if [ $rc -ne 0 ]; then
  echo "clean-passes: FAIL (forge test rc=$rc)"
  exit 1
fi
if grep -q "INVARIANT VIOLATED" <<<"$out"; then
  echo "clean-passes: FAIL (marker printed on the clean leg)"
  exit 1
fi
echo "clean-passes: OK"
