# C-P1: liquidity-penalty conservation (`LiquidityPenaltyHook`)

Same-source clean/planted twin pair against the real v4-core
`PoolManager` (pinned submodule, tag `v4.0.0`). No mock anywhere: the
suite deploys the real manager in-test, places the hook at an
address whose low 14 bits encode
`AFTER_ADD_LIQUIDITY | AFTER_REMOVE_LIQUIDITY`, drives every
`modifyLiquidity` and `swap` call through this repo's own
`InvariantRouter`, and lets the hook's own `manager.donate` +
`sync`/`settle` dance close the penalty flow through the real
flash-accounting protocol.

The teaching-scale hook is modeled after the add-time fee-state guard
pattern published in OpenZeppelin's `LiquidityPenaltyHook`
(`OpenZeppelin/uniswap-hooks/src/general/LiquidityPenaltyHook.sol`
v1.2.0). The class the case encodes was drawn from Zealynx's public
v4-hook write-up (2026-05-25) with the root finding from OpenZeppelin's
own Uniswap Hooks v1.1.0 audit; this repo cites the class provenance
one line in the top-level `README.md` and does not reproduce the source
verbatim.

## The design intent

A liquidity provider that adds a position and removes it within a short
window of blocks donates a share of the fees the position earned during
that window back to the in-range LPs. The donation is proportional to
those in-window fees and decays linearly to zero at
`PENALTY_WINDOW = 10` blocks after the most recent add-event.

v4-core fee-state model this hook rides on: any `modifyLiquidity` call
against an existing position auto-collects the position's accrued fees
as part of the call's `BalanceDelta`. The `feesAccrued` argument on the
`afterAddLiquidity` and `afterRemoveLiquidity` callbacks is v4-core's
authoritative report of what was collected on that call. This is why
the load-bearing decision lives in `afterAddLiquidity`: an add-event
that lands on an EXISTING position (i.e. an increase) triggers v4-core
to auto-collect the position's fees BEFORE the hook's remove-event
sees them; the hook must capture those fees into its own pending
penalty base at that moment, or they are lost from the base used at
the next remove.

- Clean twin: `afterAddLiquidity` snapshots the v4-core-reported
  `feesAccrued` into `pendingPenaltyBase[posKey]` on every add-event.
- Planted twin (single hunk, shown below): the snapshot line is
  omitted. Fees v4-core collected on an increase are no longer in the
  hook's ledger when the next remove computes its penalty; the actual
  amount donated diverges to zero while the reference expected amount
  stays at the decayed epoch total.

## What the invariants assert

```
p1_liquidity_penalty_conservation:
    hook.penaltyDonated(P) == hook.expectedPenaltyDonated(P)
```

Stateful invariant, 256 runs x depth 50 (12,800 handler calls per
campaign). The handler is the sole LP of the pool (the full-range
position it added at init is the only liquidity in-range), so every
swap fee flows to that single position and the reference
`expectedPenaltyDonated` ledger tracks the exact fee-accrual lifetime
without any allocation model.

Both twins compute the reference expected penalty identically, from a
shared `feesSinceEpochStart[posKey]` ledger that increments on every
add-event and remove-event via the `feesAccrued` callback argument.
Both twins compute the actual penalty from `pendingPenaltyBase +
feesAccrued`. The twin diff is the update to `pendingPenaltyBase` on
add: clean captures, planted omits.

- Clean twin: `penaltyDonated == expectedPenaltyDonated` on every
  reachable state; both ledgers advance identically on every remove.
- Planted twin: the first fuzzed sequence of
  `add-event -> swap -> add-event -> remove-event` inside one penalty
  window diverges the ledgers. The fuzz walk shrinks the counterexample
  to a three-call sequence; the deterministic regression fires the
  same divergence in one scripted path.

A second invariant, `p1_penalty_solvency` (both twins hold by
construction), asserts that the hook's cumulative donations never
exceed its pre-funded budget. The hook funds its donations from its
own pre-funded currency0 balance, never from LP principal; this check
keeps the campaign honest about donation capacity.

## Fee scope

The invariant uses currency0 accounting: a fuzzed swap-only-in-one-
direction (`zeroForOne`) walk keeps all accrued fees on the token0
side, matching the hook's token0-only donation path at teaching scale.
The hook's `_sumFees` helper folds both callback legs of `feesAccrued`
into one unsigned total, and the `_donateAndSettle` path donates and
settles in currency0. A production hook would donate on both currency
sides; that widening is a straightforward extension of the same
identity.

Legs (per repo convention, all four required):

| Leg | Clean twin | Planted twin |
|---|---|---|
| `invariant_p1_penaltyConservation` | holds | fires `INVARIANT VIOLATED p1_liquidity_penalty_conservation` |
| `invariant_p1_solvency` | holds | holds (planted twin under-donates, never over-donates) |
| `test_regression_p1_conservationOnIncreaseThenRemove` | penalty ledgers advance in lockstep | actual penalty stays at zero across the increase-then-remove, marker fires |
| Unit legs (hook wiring, single-epoch match, outside-window donation) | pass | pass (do not touch the twin-diff path) |

## Twin diff (the add-time guard only)

```diff
--- clean/LiquidityPenaltyHook.sol
+++ planted/LiquidityPenaltyHook.sol
@@ -113,13 +113,17 @@
         feesSinceEpochStart[posKey] += fees;

-        // CLEAN GUARD (the single-hunk twin diff, see case README): on an
-        // add-on-existing-position the auto-collected fees represent the
-        // position's earnings from the current penalty window, and would
-        // otherwise be lost from the penalty base. Capturing them here
-        // keeps `p1_liquidity_penalty_conservation` exact under an
-        // add -> swap -> increase -> remove sequence.
-        pendingPenaltyBase[posKey] += fees;
+        // PLANTED (single-hunk twin diff, the seeded specification
+        // violation): the CLEAN GUARD line
+        //     pendingPenaltyBase[posKey] += fees;
+        // is omitted here. On an add-on-existing-position the fees v4-core
+        // just auto-collected are the position's earnings from the current
+        // penalty window; without capture they are lost from
+        // `pendingPenaltyBase`, so at the next remove the penalty computed
+        // over the base misses the epoch between the last add and this
+        // increase. Property `p1_liquidity_penalty_conservation` diverges
+        // under an add -> swap -> increase -> remove sequence: the actual
+        // penalty donated goes to zero while the reference expected stays
+        // at the decayed epoch total.

         lastAddBlock[posKey] = block.number;
         return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
```

## Honest scope caveats

- The hook is a teaching-scale penalty ledger, not production penalty
  collection: it denominates donations in a single currency (the pool's
  `currency0`), funds them from its own pre-funded balance rather than
  from LP principal, and folds both legs of `feesAccrued` into one
  unsigned total. A production hook would settle donations on both
  currency sides and would rebase them out of the removing LP's
  principal via the return-delta path; the underlying property
  (donated == expected) is the same shape.
- The property catches the class the invariant encodes (penalty
  conservation across an add-event that lands inside the window and is
  followed by a remove-event in the same window). A penalty hook with
  a different decay schedule or a different fee-source model needs its
  own expected ledger; the bring-your-hook scaffold is the path for
  that.
- The stateful campaign finds the class probabilistically. The
  deterministic regression is what fires with certainty, and only a
  known class can be scripted deterministically.
- Not a runtime guard and not an audit. This is a pre-deploy CI gate:
  the planted leg proves the suite fails loudly when the add-time
  fee-state guard is missing.

## Running it

```
forge test --match-contract '^P1PenaltyClean$' -vv    # all green, zero markers
forge test --match-contract '^P1PenaltyPlanted$' -vv  # detection legs fail WITH marker
```

Scorecards: `docs/scorecards/p1-liquidity-penalty-conservation/`.
