# C-P1 liquidity-penalty conservation, CLEAN scorecard

> Captured from a local run on 2026-07-06 with the pinned toolchain:
> Foundry (forge) 1.7.1, solc 0.8.26, v4-core submodule at tag `v4.0.0`
> (`e50237c43811bd9b526eff40f26772152a42daba`), forge-std `v1.9.4`.
> Real PoolManager deployed in-test; every modifyLiquidity and swap
> driven through this repo's own `InvariantRouter` (no mock, no v4-core
> test routers). The hook's donate + settle path runs against the real
> flash-accounting protocol on every triggered removal.

## Summary

- Invariants asserted:
  - `invariant_p1_penaltyConservation`
    (`hook.penaltyDonated(P) == hook.expectedPenaltyDonated(P)`)
  - `invariant_p1_solvency`
    (`hook.penaltyDonated(P) <= HOOK_FUNDING`)
- Invariants violated: **0**
- Tests collected: **6** (2 invariants + 1 deterministic regression + 3 unit)
- Tests passed: **6**, failed: **0**, rc: **0**
- `INVARIANT VIOLATED` markers printed: **0**
- Campaigns: 2 x (256 runs x depth 50) = 25,600 handler calls total,
  0 reverts, 0 discards (`fail_on_revert = true` held throughout)

## Test results

```
Ran 6 tests for test/p1/PenaltyClean.t.sol:P1PenaltyClean
[PASS] invariant_p1_penaltyConservation() (runs: 256, calls: 12800, reverts: 0)

╭----------------+-----------------+-------+---------+----------╮
| Contract       | Selector        | Calls | Reverts | Discards |
+===============================================================+
| PenaltyHandler | addLiquidity    | 4201  | 0       | 0        |
|----------------+-----------------+-------+---------+----------|
| PenaltyHandler | removeLiquidity | 4390  | 0       | 0        |
|----------------+-----------------+-------+---------+----------|
| PenaltyHandler | swap            | 4209  | 0       | 0        |
╰----------------+-----------------+-------+---------+----------╯

[PASS] invariant_p1_solvency() (runs: 256, calls: 12800, reverts: 0)

╭----------------+-----------------+-------+---------+----------╮
| Contract       | Selector        | Calls | Reverts | Discards |
+===============================================================+
| PenaltyHandler | addLiquidity    | 4201  | 0       | 0        |
|----------------+-----------------+-------+---------+----------|
| PenaltyHandler | removeLiquidity | 4390  | 0       | 0        |
|----------------+-----------------+-------+---------+----------|
| PenaltyHandler | swap            | 4209  | 0       | 0        |
╰----------------+-----------------+-------+---------+----------╯

[PASS] test_regression_p1_conservationOnIncreaseThenRemove() (gas: 382761)
[PASS] test_unit_hookObservesInitialAdd() (gas: 21595)
[PASS] test_unit_removeOutsideWindowDonatesZero() (gas: 263503)
[PASS] test_unit_singleAddSwapRemoveMatchesOnBothTwins() (gas: 323259)
Suite result: ok. 6 passed; 0 failed; 0 skipped; finished in 3.53s (6.83s CPU time)

Ran 1 test suite in 3.53s (3.53s CPU time): 6 tests passed, 0 failed, 0 skipped (6 total tests)
```

## What this scorecard demonstrates

The clean twin's `afterAddLiquidity` captures v4-core's reported
`feesAccrued` into `pendingPenaltyBase` on every add-event, so the
penalty base used at every subsequent remove reflects the full
fee-accrual lifetime of the position (including any epoch that ended
in an increase inside the penalty window). Across 25,600 fuzzed
handler calls (bounded `addLiquidity` / `removeLiquidity` / `swap`
against the real `PoolManager`, with a `vm.roll` between calls so the
walk actually visits different block distances from the last
add-event), both accounting ledgers advanced in lockstep and the
deterministic regression's single `add -> swap -> increase -> remove`
sequence donated a nonzero, decay-consistent amount that matched the
expected exactly.
