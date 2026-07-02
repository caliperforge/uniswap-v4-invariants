# C-B1: custom-accounting rounding integrity (`LiquidityVaultHook`)

A defender-side regression fixture on our own synthetic vault-style
custom-accounting hook, running against the real v4 `PoolManager`
(submodule at tag `v4.0.0`). This is the case the coverage map calls
out as unique across every free comparator at its pinned commits: the
class it encodes, accumulated rounding-direction drift in vault
share/balance accounting, is not covered by any comparator suite in the
coverage map.

Rounding-direction defects in custom vault share accounting have been
publicly documented as the cause of real-world losses in
custom-liquidity vaults, which is why this class is prioritized; the
file-level citation for that public record lives in
`docs/coverage_map.md`, and everything below stands on its own without
it.

## The hook

`LiquidityVaultHook` is a teaching-scale vault:

- **Share accounting.** Deposits of the pool's `currency0` mint shares
  against a conservative net asset value; withdrawals burn shares for a
  pro-rata gross redemption, minus a declared 0.10% withdrawal fee that
  accrues to a separate fee ledger.
- **Balance split.** Every booked asset lives in one of two tranches:
  `idleBalance` (withdrawable cash) and `activeBalance` (booked as
  deployed against the hooked pool; teaching scale models the tranche
  as a 50/50 token0/token1 position entered at the 1:1 pool price). A
  third figure, `trackedTotal`, is updated exactly on every deposit and
  withdrawal.
- **Liquidity estimate = MIN of two estimates.** The active tranche is
  valued as the minimum of its balance-derived book value and its
  spot-derived value at the pool's live `sqrtPriceX96` (read from the
  real `PoolManager` via `StateLibrary`). Share pricing uses the lower
  figure.

## The seeded specification violation (single-hunk twin diff)

The withdraw path sources each redemption pro rata across the balance
split. The clean twin computes the active share with floor division and
assigns the exact remainder to the idle leg, so the idle term rounds UP
and the two decrements sum to exactly the gross redemption. The planted
twin computes the idle leg with its own floor division instead, flipping
the idle term's rounding direction to round-down:

```diff
-        // Pro-rata sourcing across the balance split. The active share
-        // rounds down and the idle share takes the exact remainder,
-        // i.e. the idle term rounds UP to absorb the split's wei
-        // remainder. The two decrements sum to exactly `gross`, so
-        // idle + active decreases in lockstep with trackedTotal and
-        // the balance-split identity holds to the wei on every path.
+        // PLANTED (single-hunk twin diff, the seeded specification
+        // violation): the idle share of the withdrawal is computed with
+        // its own floor division instead of taking the exact remainder
+        // of the split, flipping the idle term's rounding direction
+        // from round-up-to-the-remainder to round-down. Each individual
+        // withdrawal still pays the correct amount, and both floors
+        // agree with the exact split whenever the divisions are exact;
+        // whenever both carry a remainder the two decrements sum to
+        // gross - 1, so the split releases one wei less than
+        // trackedTotal. Bounded per operation, systematic across many:
+        // the books overstate the split by the accumulated drift,
+        // violating the balance-split identity.
         uint256 fromActive = FullMath.mulDiv(gross, activeBalance, trackedTotal);
-        uint256 fromIdle = gross - fromActive;
+        uint256 fromIdle = FullMath.mulDiv(gross, idleBalance, trackedTotal);
```

Both variants agree whenever the divisions are exact, and the planted
variant never misprices a single withdrawal's payout. That is the
signature of the class: correct for one operation, wrong under
repetition. Each remainder-carrying withdrawal releases one wei less
from the split than from `trackedTotal`, so the books overstate the
split by the accumulated drift.

## The invariants (both twins, 256 runs x depth 50)

Handler walks fuzz `deposit` / `withdraw` / `swap` (swaps run through
this repo's own `InvariantRouter` against the real pool and move the
spot price the MIN estimate reads).

1. `b1_balance_split_integrity`:
   `idleBalance + activeBalance == trackedTotal`, to the wei. Exact by
   construction on the clean twin; on the planted twin the first
   remainder-carrying withdrawal fires the marker.
2. `b1_accounting_conservation`:
   `totalAssets() + accruedFees <= asset.balanceOf(vault)`. The value
   redeemable across all outstanding shares, net of declared fees,
   never exceeds what the vault actually holds. On the planted twin the
   drifted books violate this whenever the MIN estimate selects the
   balance-derived leg; when the spot-derived leg is lower it can
   conservatively mask wei-scale drift, which is exactly why the
   split-integrity identity is the precise catch and conservation is
   the solvency statement.

## The deterministic regression sequence

`test_regression_b1_roundingDriftAccumulates`, described in accounting
terms only. One non-round seed deposit (1,000,000,000,000,007 wei, so
the pro-rata divisions carry remainders from step one), forty small
odd-sized withdrawals, one ordinary swap, then both invariant checks.
The sequence detects the seeded violation and stops; it computes no
balance deltas for any party.

Per-step accounting on the planted twin (captured from the run; the
clean twin logs zero at every step):

| Step | Operation | Accounting property probed | Per-step rounding contribution | Cumulative split drift |
|---|---|---|---|---|
| 0 | deposit 1,000,000,000,000,007 | split books the raw amount exactly | 0 wei | 0 wei |
| 1 | withdraw 3,333 shares | both pro-rata divisions carry remainders; planted floors the idle leg | 1 wei | 1 wei |
| 2 | withdraw 3,604 shares | divisions exact at this state; twins agree | 0 wei | 1 wei |
| 3 | withdraw 3,875 shares | remainders again; one more wei retained by the books | 1 wei | 2 wei |
| ... | 37 further withdrawals, alternating at this seed | 20 of the 40 withdrawals carry remainders in both divisions | 0 or 1 wei each | ... |
| 40 | withdraw 13,902 shares | final withdrawal of the loop | 0 wei | **20 wei** |
| 41 | ordinary swap (exact input, zeroForOne) | moves spot so the MIN estimate selects the balance-derived leg, unmasking conservation | 0 wei | 20 wei |
| 42 | invariant checks | split integrity: books claim 20 wei more than tracked; conservation: redeemable + fees exceeds holdings by 20 wei | | |

On the planted twin the test prints both markers and fails; on the
clean twin every step contributes zero and the test passes:

```
INVARIANT VIOLATED b1_balance_split_integrity
INVARIANT VIOLATED b1_accounting_conservation
```

## What this case claims, and what it does not

A custom-accounting hook team can prove their suite catches this
rounding-integrity class: the clean twin passes both legs, the planted
twin fails both legs with the markers above, and CI asserts both
directions on every commit.

Two honest caveats:

1. Random fuzzing finds the wei-scale accumulation path
   probabilistically, not certainly. The stateful campaign fired
   quickly in our captured runs because the split-integrity identity is
   exact, but the deterministic leg is what fires with certainty, and a
   deterministic leg can only be written for a known class.
2. The honest claim is regression with proof of detection for known bug
   classes, not ex-ante discovery. This fixture proves the invariants
   catch the encoded class in our own synthetic hook; it does not claim
   the suite would have found any specific defect in any specific
   protocol ahead of time.

## Running it

```
forge test --match-contract '^B1VaultClean$' -vv    # all green, zero markers
forge test --match-contract '^B1VaultPlanted$' -vv  # detection legs fail WITH markers
```

Scorecards: `docs/scorecards/b1-custom-accounting/`.
