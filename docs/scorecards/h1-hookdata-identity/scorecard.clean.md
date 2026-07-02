# C-H1 reward-recipient identity from hookData, CLEAN scorecard

> Captured from a local run on 2026-07-01 with the pinned toolchain:
> Foundry (forge) 1.7.1, solc 0.8.26, v4-core submodule at tag `v4.0.0`
> (`e50237c43811bd9b526eff40f26772152a42daba`), forge-std `v1.9.4`.
> Real PoolManager deployed in-test; swaps driven through this repo's
> own `InvariantRouter` (no mock, no v4-core test routers).

## Summary

- Invariant asserted: `invariant_h1_rewardsTo_match_swapsByRouter`
  (`hook.rewardsTo(R) == handler.swapsByRouter(R)` for every router R)
- Invariants violated: **0**
- Tests collected: **5** (1 invariant + 1 deterministic regression + 3 unit)
- Tests passed: **5**, failed: **0**, rc: **0**
- `INVARIANT VIOLATED` markers printed: **0**
- Campaign: 256 runs x depth 50 = 12,800 handler calls, 0 reverts,
  0 discards (`fail_on_revert = true` held throughout)

## Test results

```
Ran 5 tests for test/h1/RewardsClean.t.sol:H1RewardsClean
[PASS] invariant_h1_rewardsTo_match_swapsByRouter() (runs: 256, calls: 12800, reverts: 0)
[PASS] test_regression_h1_hookDataNamesDifferentRecipient() (gas: 1942774)
[PASS] test_unit_onlyManagerCallsCallbacks() (gas: 19329)
[PASS] test_unit_rewardCreditedToPerformingRouter() (gas: 259154)
[PASS] test_unit_swapStartRewardConservation() (gas: 492161)
Suite result: ok. 5 passed; 0 failed; 0 skipped; finished in 4.68s (4.68s CPU time)
Ran 1 test suite in 4.68s (4.68s CPU time): 5 tests passed, 0 failed, 0 skipped (5 total tests)
```

## What this scorecard demonstrates

The clean twin's recipient decision reads ONLY `sender`, the
manager-forwarded msg.sender of `PoolManager.swap`. Across 12,800
fuzzed handler calls (three real router actors, swaps in both
directions with hookData that is empty, names the performing router, or
names a different router), `hook.rewardsTo(R)` stayed in lockstep with
the handler's independently computed per-router swap ledger for every
router R. The deterministic regression leg confirms a swap whose
hookData names a different address still credits the performing router
on the clean twin.
