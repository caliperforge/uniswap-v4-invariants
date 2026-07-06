# C-P2 fee-direction integrity, PLANTED scorecard

> Captured from a local run on 2026-07-06 with the pinned toolchain:
> Foundry (forge) 1.7.1, solc 0.8.26, v4-core submodule at tag `v4.0.0`,
> forge-std `v1.9.4`, `openzeppelin-uniswap-hooks` submodule at tag
> `v1.1.0` (`e59fe72`). Real `PoolManager` deployed in-test; every swap
> driven through this repo's own `InvariantRouter`. This is the
> INVERTED assertion of the CI planted leg: a green scorecard here is
> a red `forge test` run WITH the marker printed.

## Summary

- Invariants asserted: same 2 as the clean scorecard.
- Invariants violated on this twin: **1**
  (`invariant_p2_dynamicfeeDirectionIntegrity`)
- Tests collected: **5**
- Tests passed: **3**, failed: **2**, rc: **1**
- `INVARIANT VIOLATED p2_dynamicfee_direction_integrity` printed: **2**
  (one from the stateful campaign, one from the deterministic
  regression)
- Stateful campaign: original counterexample of 1 handler call,
  shrunk by forge to **1 handler call**: a single fuzzed swap whose
  mode seed selected the `exactOutput` branch. The pool is seeded with
  full-range liquidity in setUp, so a single exactOutput swap is
  enough for the planted hook's pre-`2678eb9` fee-arithmetic to
  diverge from the handler's post-fix reference.
- Solvency leg still holds: the planted twin only ever accrues a
  magnitude less-than-or-equal-to the unspecified-side amount it
  observed on the same swap, so `accrued(c) <= cumulative(c)` stays
  true on both currencies for the full 12,800-call campaign.

## Test results

```
Ran 5 tests for test/p2/DirectionPlanted.t.sol:P2DirectionPlanted
[FAIL: <empty revert data>]
	[Sequence] (original: 1, shrunk: 1)
		sender=... calldata=swap(uint256,uint256) args=[<amountSeed>, <modeSeed>]
 invariant_p2_dynamicfeeDirectionIntegrity() (runs: 1, calls: 1, reverts: 1)
Logs:
  INVARIANT VIOLATED p2_dynamicfee_direction_integrity

[PASS] invariant_p2_feeSolvency() (runs: 256, calls: 12800, reverts: 0)

╭------------------+----------+-------+---------+----------╮
| Contract         | Selector | Calls | Reverts | Discards |
+==========================================================+
| DirectionHandler | swap     | 12800 | 0       | 0        |
╰------------------+----------+-------+---------+----------╯

[FAIL] test_regression_p2_directionMismatchOnExactOutput() (gas: 529014)
Logs:
  INVARIANT VIOLATED p2_dynamicfee_direction_integrity

[PASS] test_unit_exactInputSwapsMatchOnBothTwins() (gas: 429636)
[PASS] test_unit_hookObservesExactInputSwap() (gas: 258271)
Suite result: FAILED. 3 passed; 2 failed; 0 skipped; finished in 3.65s (3.73s CPU time)

Ran 1 test suite in 3.65s (3.65s CPU time): 3 tests passed, 2 failed, 0 skipped (5 total tests)
```

## What this scorecard demonstrates

The planted twin subclasses OpenZeppelin's audited
`BaseDynamicAfterFee` (same vendored copy the clean twin uses), and
its `_afterSwap` override byte-copies the PRE-`2678eb9` fee-arithmetic
block character-for-character: the currency-selection expression
above the arithmetic is unchanged from the clean twin (that line
pre-existed the fix), but the arithmetic below is the audited M-01
bug shape. Instead of branching on `exactInput`, it computes
`feeAmount = uint128(unspecifiedAmount) - targetOutput` unconditionally
and reverts with `TargetOutputExceeds()` when the target exceeds the
unspecified amount. Under this case's `_getTargetUnspecified = 0`
configuration, the pre-fix arithmetic reduces to
`feeAmount = |unspec|` on every swap, while the post-fix arithmetic
(the reference ledger's basis) reduces to `feeAmount = |unspec|` on
exactInput and `feeAmount = 0` on exactOutput. The first exactOutput
swap therefore accrues the full unspec magnitude on the planted
twin's ledger and zero on the reference, and the accrued/expected
identity fails. The stateful fuzzer shrunk to a single call landing
on the exactOutput branch and fired the marker; the deterministic
regression scripts the same divergence with a fixed
`(exactInput, exactOutput, exactInput)` sequence and prints the same
marker with certainty. The solvency leg still passes: the planted
twin's ledger records `feeAmount == |unspec|` whenever it accrues, so
`accrued(c) <= cumulative(c)` holds by construction (the wrong-magnitude
arithmetic shows up in the direction-integrity leg, not here).
