#!/usr/bin/env bash
# Multi-seed reachability leg for uniswap-v4-invariants planted twins.
#
# Runs `forge test --match-contract <Suite>Planted --fuzz-seed <SEED>`
# across every seed in ci/reachability_seeds.txt (N=16 by default), for
# every planted suite discovered under test/. Every (suite, seed) pair
# must exit non-zero AND print at least one `INVARIANT VIOLATED` marker.
# This upgrades the base planted leg's one-seed catch to a deterministic
# N-of-N certification per suite: no false-green from a lucky CI seed.
#
# The walkthrough suite `ExamplePlanted` under test/bring-your-hook/
# is excluded; it exercises the adopt/ scaffold and is not a real case.
#
# Emits per-(suite, seed) lines and, per suite, a single verdict:
#   reachability certified: yes (N/N failed as required)
#   reachability certified: no  (k/N failed; missed on seeds ...)
# and an overall verdict at the end that is green only when every suite
# certifies fail-on-all-N.
#
# See ../scripts/reachability/ in the caliperforge crypto-contributor
# repo for the canonical runner this mirrors.

set -uo pipefail

summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
seeds_file="${SEEDS_FILE:-ci/reachability_seeds.txt}"
search_dir="${SEARCH_DIR:-test/}"

if [ ! -f "$seeds_file" ]; then
  echo "reachability-multi-seed: seeds file not found: $seeds_file" >&2
  exit 2
fi

seeds=$(grep -vE '^\s*(#|$)' "$seeds_file")

# Planted suites by convention, minus the bring-your-hook walkthrough
# contracts (ExampleAdopterPlanted, MyHookPlanted) which are scaffold
# demos, not real cases in the credited catalog.
suites=$(grep -rhoE --include='*.sol' --exclude-dir='bring-your-hook' \
  'contract [A-Za-z0-9_]*Planted' "$search_dir" 2>/dev/null \
  | awk '{print $2}' | sort -u)

if [ -z "$suites" ]; then
  msg="reachability-multi-seed: 0 real planted suites found in $search_dir - leg passes vacuously"
  echo "$msg"
  echo "$msg" >>"$summary"
  exit 0
fi

{
  echo "## Multi-seed reachability (16 seeds per suite)"
  echo ""
} >>"$summary"

overall_rc=0

for suite in $suites; do
  total=0
  failed=0
  missed=""

  {
    echo "### $suite"
    echo ""
    echo "| seed | outcome | markers |"
    echo "| --- | --- | --- |"
  } >>"$summary"

  for seed in $seeds; do
    total=$((total + 1))
    out=$(forge test --match-contract "^${suite}\$" --fuzz-seed "$seed" -vv 2>&1)
    rc=$?
    markers=$(printf '%s\n' "$out" | grep -c "INVARIANT VIOLATED" || true)

    if [ "$rc" -ne 0 ] && [ "$markers" -gt 0 ]; then
      echo "$suite seed $seed: FAILED as required (rc=$rc, markers=$markers)"
      echo "| \`$seed\` | failed (required) | $markers |" >>"$summary"
      failed=$((failed + 1))
    elif [ "$rc" -eq 0 ]; then
      echo "$suite seed $seed: passed unexpectedly (rc=0). planted-twin escaped on this seed."
      echo "| \`$seed\` | ESCAPED (rc=0) | 0 |" >>"$summary"
      missed="$missed $seed"
    else
      echo "$suite seed $seed: rc=$rc but no INVARIANT VIOLATED marker; treating as escape."
      echo "| \`$seed\` | escape (no marker, rc=$rc) | 0 |" >>"$summary"
      printf '%s\n' "$out" | tail -20
      missed="$missed $seed"
    fi
  done

  if [ "$failed" -eq "$total" ]; then
    verdict="$suite reachability certified: yes ($failed/$total failed as required)"
    echo "$verdict"
    echo "" >>"$summary"
    echo "**$verdict**" >>"$summary"
  else
    verdict="$suite reachability certified: no ($failed/$total failed; missed on seeds:$missed)"
    echo "$verdict"
    echo "" >>"$summary"
    echo "**$verdict**" >>"$summary"
    overall_rc=1
  fi
done

echo ""
if [ "$overall_rc" -eq 0 ]; then
  echo "reachability certified: yes (all suites, 16/16 failed as required)"
  echo "" >>"$summary"
  echo "**reachability certified: yes (all suites, 16/16 failed as required)**" >>"$summary"
else
  echo "reachability certified: no (at least one suite missed; see per-suite lines above)"
  echo "" >>"$summary"
  echo "**reachability certified: no (see per-suite lines above)**" >>"$summary"
fi

exit "$overall_rc"
