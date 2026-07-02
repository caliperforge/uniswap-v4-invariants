#!/usr/bin/env bash
# Planted leg, INVERTED assertion: every planted-twin suite (contract
# name ending in `Planted`) must FAIL its forge run AND print at least
# one `INVARIANT VIOLATED <name>` marker. The job is green exactly when
# the twins are caught; the markers are copied into the GitHub job
# summary so a reviewer clicking the job sees each catch.
#
# Skeleton-aware: with zero planted suites on disk (pre-case scaffold)
# the leg reports that explicitly and passes, so the workflow is
# exercisable before the first case lands.
#
# Optional first arg: a directory to scope the planted-suite discovery
# to one suite subtree (used by bring-your-hook.yml, which points at
# test/bring-your-hook/). Omit for the repo-wide leg (defaults to test/).
set -uo pipefail

search_dir="${1:-test/}"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"

# Planted suites by convention: `contract <Name>Planted is ...` under
# the search directory. Solidity sources only: docs in test/ (the
# bring-your-hook walkthrough) show the naming convention in prose and
# must not be discovered as suites.
suites=$(grep -rhoE --include='*.sol' 'contract [A-Za-z0-9_]*Planted' "$search_dir" 2>/dev/null | awk '{print $2}' | sort -u)

if [ -z "$suites" ]; then
  msg="planted-bug-twin-fails: 0 planted suites found in $search_dir (scaffold skeleton) - leg passes vacuously"
  echo "$msg"
  echo "$msg" >>"$summary"
  exit 0
fi

overall=0
{
  echo "## Planted-twin catches"
  echo ""
} >>"$summary"

for suite in $suites; do
  out=$(forge test --match-contract "^${suite}\$" -vv 2>&1)
  rc=$?
  markers=$(grep "INVARIANT VIOLATED" <<<"$out" | sort -u)

  if [ $rc -eq 0 ]; then
    echo "$suite: NOT CAUGHT (planted twin passed, rc=0)"
    overall=1
  elif [ -z "$markers" ]; then
    echo "$suite: FAILED WITHOUT MARKER (rc=$rc but no INVARIANT VIOLATED line)"
    echo "$out"
    overall=1
  else
    echo "$suite: caught (rc=$rc)"
    echo "$markers"
    {
      echo "### $suite"
      echo '```'
      echo "$markers"
      echo '```'
    } >>"$summary"
  fi
done

if [ $overall -ne 0 ]; then
  echo "planted-bug-twin-fails: FAIL (at least one planted twin escaped)"
  exit 1
fi
echo "planted-bug-twin-fails: OK (all planted twins caught)"
