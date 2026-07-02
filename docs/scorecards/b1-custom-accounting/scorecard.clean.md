# C-B1 custom-accounting rounding integrity, CLEAN scorecard

> Captured from a local run on 2026-07-01 with the pinned toolchain:
> Foundry (forge) 1.7.1, solc 0.8.26, v4-core submodule at tag `v4.0.0`
> (`e50237c43811bd9b526eff40f26772152a42daba`), forge-std `v1.9.4`.
> Real PoolManager deployed in-test; swaps driven through this repo's
> own `InvariantRouter` (no mock, no v4-core test routers).

## Summary

- Invariants asserted:
  - `invariant_b1_balanceSplitIntegrity`
    (`idleBalance + activeBalance == trackedTotal`)
  - `invariant_b1_conservation`
    (`totalAssets() + accruedFees <= asset.balanceOf(vault)`)
- Invariants violated: **0**
- Tests collected: **8** (2 invariants + 1 deterministic regression + 5 unit)
- Tests passed: **8**, failed: **0**, rc: **0**
- `INVARIANT VIOLATED` markers printed: **0**
- Campaigns: 2 x (256 runs x depth 50) = 25,600 handler calls total,
  0 reverts, 0 discards (`fail_on_revert = true` held throughout)
- Deterministic regression: all 40 withdrawal steps contributed 0 wei
  of split drift; cumulative drift 0 wei

## Test results

```
Ran 8 tests for test/b1/VaultClean.t.sol:B1VaultClean
[PASS] invariant_b1_balanceSplitIntegrity() (runs: 256, calls: 12800, reverts: 0)
[PASS] invariant_b1_conservation() (runs: 256, calls: 12800, reverts: 0)
[PASS] test_regression_b1_roundingDriftAccumulates() (gas: 1254509)
[PASS] test_unit_depositMintsSharesAndSplitsBalance() (gas: 187179)
[PASS] test_unit_hookObservesSwapsOnRealPool() (gas: 161406)
[PASS] test_unit_minEstimateConservativeUnderSpotMove() (gas: 321026)
[PASS] test_unit_onlyAdminSetsPool() (gas: 14955)
[PASS] test_unit_withdrawPaysGrossMinusDeclaredFee() (gas: 222470)
Suite result: ok. 8 passed; 0 failed; 0 skipped; finished in 2.70s (5.17s CPU time)
Ran 1 test suite in 2.70s (2.70s CPU time): 8 tests passed, 0 failed, 0 skipped (8 total tests)
```

## What this scorecard demonstrates

The clean twin's withdraw sourcing assigns the split's wei remainder to
the idle leg, so `idleBalance + activeBalance` decreases in exact
lockstep with `trackedTotal` on every path. Across 25,600 fuzzed handler
calls (deposits, capped withdrawals, real swaps in both directions that
move the spot price the MIN estimate reads), both accounting identities
held to the wei, and the 40-withdrawal deterministic regression
accumulated zero drift.
