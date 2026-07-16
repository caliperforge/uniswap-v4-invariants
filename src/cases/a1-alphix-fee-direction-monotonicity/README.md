# C-A1: fee-direction monotonicity (Alphix `DynamicFeeLib`)

Same-source clean/planted twin pair against Alphix's real audited
fee-computation library (`src/libraries/DynamicFee.sol` on
`github.com/alphixfi/alphix-core` at branch `main`, vendored under
`vendor/alphix-main/`). No mock: the clean twin calls the vendored
library directly through a thin storage-backed harness that mirrors
Alphix's own `poke(...)` call-site shape (see `Alphix.sol#poke`); the
planted twin calls a byte-copy of the library with the direction guard
in `_applyFeeAdjustment` removed.

The class the case encodes is a **fee-direction inversion**: on an
out-of-band poke, is the fee moved TOWARD the correct side of the
target band (up on upper-OOB, down on lower-OOB)? Alphix's audited
library encodes the direction with an `if (isUpper) { feeAcc += deltaUp }
else { feeAcc -= deltaDown }` guard inside `_applyFeeAdjustment`. The
planted twin removes that guard (both branches subtract), so upper-OOB
pokes decrease the fee where the audited library increases it. The
invariant catches the divergence on the first upper-OOB poke the fuzz
walk emits.

## Framing

Planted-twin methodology, ANY fabricated bug on our own case code:

- **Clean twin** (`clean/AlphixFeeHarnessClean.sol`) subclasses Alphix's
  actual audited logic in the only way a Solidity library allows — by
  importing and calling `DynamicFeeLib.computeNewFee(...)` from the
  vendored source. NO byte of the vendored library is altered. Property
  holds green on all campaign seeds.
- **Planted twin** (`planted/DynamicFeePlanted.sol` +
  `planted/AlphixFeeHarnessPlanted.sol`) byte-copies the vendored library
  and confines the diff to a single hunk inside `_applyFeeAdjustment`
  (see the `PLANTED twin-diff BEGIN/END` markers). The harness contract
  itself is character-for-character identical to the clean twin's
  modulo the library import.
- The planted variant is a fabricated bug on OUR case code, defined only
  to demonstrate that the property surface catches the class. It is NOT
  a claim we found a live bug in Alphix's production hook, and the clean
  leg on the vendored audited logic passes by construction.

## What the invariants assert

```
a1_fee_direction_monotonicity:
    lastPokeWasOob && lastPokeIsUpper ==>
      (lastPokeNewFee >= lastPokeOldFee)
      || (lastPokeNewFee == params.maxFee)         // clamp on the correct side
    lastPokeWasOob && !lastPokeIsUpper ==>
      (lastPokeNewFee <= lastPokeOldFee)
      || (lastPokeNewFee == params.minFee)         // clamp on the correct side
```

Stateful invariant, 256 runs × depth 50 (~12,800 handler calls per
campaign) on the harness's `poke(uint256 currentRatio)` selector. The
handler bounds `currentRatio` into a range that includes both in-band
and both OOB sides so the fuzz walk exercises every branch of
`computeNewFee`. The clean twin holds the identity because the
audited `if (isUpper)` branches move the fee TOWARD the correct clamp
each call; the planted twin fails on the first upper-OOB poke (because
the removed guard turns every OOB poke into a lower-branch subtract).

A second invariant, `a1_fee_bounds` (both twins hold by construction),
asserts that the fee stays within the pool-params `[minFee, maxFee]`
after every poke. This is a same-currency-shape bound: a
direction-inverted arithmetic that computes the wrong direction shows up
as a monotonicity failure, not a fake bounds failure, because
`clampFee(...)` runs on both twins identically.

## Fee scope

The harness is a call-site facade around a pure library: it maintains
`currentFee`, `targetRatio`, `_oobState`, and `_params` in storage the
same way Alphix's own `Alphix.sol` does, and each `poke(...)` advances
them via the vendored (clean) or planted `DynamicFeeLib.computeNewFee`
followed by the same EMA `_targetRatio` update the on-chain hook runs.
No pool, no swap, no `PoolManager` — the property being tested is
purely on the library's fee-computation, which is where the direction
guard actually lives.

Legs (per repo convention, all four required):

| Leg | Clean twin | Planted twin |
|---|---|---|
| `invariant_a1_feeDirectionMonotonicity` | holds | fires `INVARIANT VIOLATED a1_fee_direction_monotonicity` |
| `invariant_a1_feeBounds` | holds | holds (both twins run `clampFee` unchanged) |
| `test_regression_a1_upperOobDropsFee` | fee non-decreases across a scripted upper-OOB poke | fee drops across the same poke, marker fires |
| `test_unit_upperOobMutatesFee` (both twins wire the library through) | passes | passes: the harness mutates `currentFee` on either twin (the direction is the marker, not the mutation) |

## Twin diff (the `_applyFeeAdjustment` guard only)

```diff
--- vendor/alphix-main/DynamicFee.sol (audited)
+++ planted/DynamicFeePlanted.sol (direction guard removed)
@@ ---- inside _applyFeeAdjustment, after streak + feeDelta compute ----
-        if (isUpper) {
-            uint256 deltaUp = feeDelta.mulDiv(p.upperSideFactor, AlphixGlobalConstants.ONE_WAD);
-            unchecked { feeAcc += deltaUp; } // clamped below
-        } else {
-            uint256 deltaDown = feeDelta.mulDiv(p.lowerSideFactor, AlphixGlobalConstants.ONE_WAD);
-            if (deltaDown >= feeAcc) { return (p.minFee, sOut); }
-            else { unchecked { feeAcc -= deltaDown; } } // clamped below
-        }
+        uint256 deltaDown = feeDelta.mulDiv(p.lowerSideFactor, AlphixGlobalConstants.ONE_WAD);
+        if (deltaDown >= feeAcc) { return (p.minFee, sOut); }
+        else { unchecked { feeAcc -= deltaDown; } }
+        isUpper; p.upperSideFactor; // silence unused-parameter warnings
```

The planted variant is defined ONLY in our case's `planted/` dir; the
vendored library under `vendor/alphix-main/` is never mutated (rule:
planted bugs live only in our own case code, never in vendored source).

## Honest scope caveats

- The property catches the class the invariant encodes
  (direction-integrity on the OOB fee-adjustment branch). A hook that
  uses a different fee-computation shape needs its own reference
  harness; the bring-your-hook scaffold is the path for that.
- The stateful campaign finds the class probabilistically. The
  deterministic regression is what fires with certainty, and only a
  known class can be scripted deterministically.
- Not a runtime guard and not an audit. This is a pre-deploy CI gate:
  the planted leg proves the suite fails loudly when the OOB
  fee-adjustment direction guard is removed.
- The harness exercises the pure library. Alphix's `poke(...)` call-site
  also handles cooldown (`_lastFeeUpdate + minPeriod`), fee-update
  emission, and the `updateDynamicLPFee` call to `PoolManager` — none of
  those affect the direction-integrity property, which is entirely
  determined by `DynamicFeeLib.computeNewFee`. Vendoring the full hook
  would let the same invariant run under the surrounding storage /
  access-control shell; the direction-integrity result would be
  identical.
- The clean twin literally imports Alphix's audited `DynamicFeeLib`.
  The vendored copy at `vendor/alphix-main/` carries a NOTICE with the
  provenance (source path, upstream license BUSL-1.1, patch policy: no
  fee-computation byte altered).

## Running it

Clone-and-run (paste-ready for an outside reader):

```
git clone --recursive https://github.com/caliperforge/uniswap-v4-invariants
cd uniswap-v4-invariants
forge test --match-contract '^A1MonotonicityPlanted$' \
           --match-test 'invariant_a1_feeDirectionMonotonicity' \
           --fuzz-seed 0x1 -vv
# expected: FAIL, log line "INVARIANT VIOLATED a1_fee_direction_monotonicity"
```

Full twin sweep (in-tree, once cloned):

```
forge test --match-contract '^A1MonotonicityClean$' -vv    # all green, zero markers
forge test --match-contract '^A1MonotonicityPlanted$' -vv  # detection legs fail WITH marker
```

## Provenance

> **Provenance.** The class this case encodes is fee-direction
> inversion inside a dynamic-fee hook's out-of-band adjustment branch.
> Alphix's `src/libraries/DynamicFee.sol` (v0.1.0 release on `main`,
> vendored 2026-07-15) encodes the guard as an `if (isUpper) { += }
> else { -= }` branch inside `_applyFeeAdjustment`. This case is a
> defender-side regression fixture: the clean twin imports Alphix's
> library directly (byte-faithful) and holds the monotonicity identity;
> the planted twin byte-copies the library with the direction guard
> removed and fires the invariant on the first upper-OOB poke. The
> planted variant is fabricated on our own case code to demonstrate
> that the property surface catches the class; it is NOT a claim we
> found a live bug in Alphix's production hook. The clean leg on the
> vendored audited library holds by construction.
