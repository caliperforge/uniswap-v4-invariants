#!/usr/bin/env bash
# Adopter-generator leg (T-P034-S1): run `./caliper run <path>` against
# the checked-in third-party-shaped fixture so the GENERATOR code path
# is exercised by CI.
#
# Why this leg exists: the branch's CI was green while `./caliper run
# <path>` was broken for every input (the generator emitted an exact
# `pragma solidity 0.8.26;` into a project pinned to solc 0.8.33,
# T-P034-A section 4.1). The demo leg and the two hand-written adopter
# suites never invoke the generator, so nothing could see the break.
# This leg goes: fixture hook -> import-graph vendoring -> generated
# CaliperRun.t.sol -> compile under the pinned solc -> invariant walk.
#
# The fixture is checked in at ci/fixtures/third-party-hook/ and is
# hermetic: no network fetch at job time. It is third-party-SHAPED
# (own pragma, @uniswap/v4-periphery BaseHook import convention,
# relative-import sibling), not the bundled demo and not a
# hand-written adopter suite. See the fixture's header comment.
#
# CALIPER_HOOK_CTOR_ARGS_EXPR is a documented adopter override
# (./caliper --help); the fixture's constructor takes the pool
# manager, as the dominant BaseHook lineage requires.
#
# Assertions, strongest first:
#   A1  `./caliper run <fixture>` exits 0.
#   A2  the run output contains the [PASS] line of the BYOH invariant
#       walk (not just a zero exit code).
#   A3  the generated test file exists (the generator actually ran).
#   A4  the generated pragma is a range (^ or >=), not an exact pin:
#       the exact-pin emission is the W1 regression this leg is for.
#   A5  the relative-import sibling was vendored (the import walker
#       actually ran).
set -uo pipefail

FIXTURE="ci/fixtures/third-party-hook/src/TallyFeeHook.sol"
GEN="test/bring-your-hook/adopters/CaliperRun.t.sol"
VENDORED_SIBLING="src/adopters/caliper-run/libraries/TallyMath.sol"

out=$(CALIPER_HOOK_CTOR_ARGS_EXPR='address(manager)' ./caliper run "$FIXTURE" 2>&1)
rc=$?
echo "$out"

if [ $rc -ne 0 ]; then
  echo "adopter-generator-leg: FAIL (./caliper run rc=$rc)"
  exit 1
fi
if ! grep -q "\[PASS\] invariant_byoh_observables_match_ledgers" <<<"$out"; then
  echo "adopter-generator-leg: FAIL (exit 0 but no BYOH invariant PASS line; exit-code-only green is not accepted)"
  exit 1
fi
if [ ! -f "$GEN" ]; then
  echo "adopter-generator-leg: FAIL (generated test $GEN missing; generator did not run)"
  exit 1
fi
if ! grep -Eq '^pragma solidity (\^|>=)' "$GEN"; then
  echo "adopter-generator-leg: FAIL (generated pragma is an exact pin again; W1 regression):"
  grep -n "pragma solidity" "$GEN"
  exit 1
fi
if [ ! -f "$VENDORED_SIBLING" ]; then
  echo "adopter-generator-leg: FAIL (relative-import sibling not vendored to $VENDORED_SIBLING)"
  exit 1
fi
echo "adopter-generator-leg: OK (generator ran, generated pragma is ranged, sibling vendored, BYOH walk passed)"
