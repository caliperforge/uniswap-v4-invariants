# C-H3 settle protocol on the flash-accounting surface, CLEAN scorecard

> Captured from a local run on 2026-07-01 with the pinned toolchain:
> Foundry (forge) 1.7.1, solc 0.8.26, v4-core submodule at tag `v4.0.0`
> (`e50237c43811bd9b526eff40f26772152a42daba`), forge-std `v1.9.4`.
> Real PoolManager deployed in-test; swaps driven through this repo's
> own `InvariantRouter` (no mock, no v4-core test routers).

## Summary

- Invariant asserted: `invariant_h3_bonusPathSettles`
  (`handler.settleGuardReverts() == 0`, i.e. zero
  `CurrencyNotSettled` reverts across the campaign, bonus path
  included)
- Invariants violated: **0**
- Tests collected: **5** (1 invariant + 1 deterministic regression + 3 unit)
- Tests passed: **5**, failed: **0**, rc: **0**
- `INVARIANT VIOLATED` markers printed: **0**
- Campaign: 256 runs x depth 50 = 12,800 handler calls, 0 reverts,
  0 discards (`fail_on_revert = true` held throughout)

## Test results

```
No files changed, compilation skipped

Ran 5 tests for test/h3/FlashClean.t.sol:H3FlashClean
[PASS] invariant_h3_bonusPathSettles() (runs: 256, calls: 12800, reverts: 0)

╭--------------+----------+-------+---------+----------╮
| Contract     | Selector | Calls | Reverts | Discards |
+======================================================+
| FlashHandler | swap     | 12800 | 0       | 0        |
╰--------------+----------+-------+---------+----------╯

[PASS] test_regression_h3_takeWithoutSettleTripsGuard() (gas: 255851)
[PASS] test_unit_benignSwapLeavesFundingUntouched() (gas: 141497)
[PASS] test_unit_bonusFundingInPlace() (gas: 17725)
[PASS] test_unit_onlyManagerCallsBeforeSwap() (gas: 15971)
Suite result: ok. 5 passed; 0 failed; 0 skipped; finished in 3.67s (3.67s CPU time)

Ran 1 test suite in 3.67s (3.67s CPU time): 5 tests passed, 0 failed, 0 skipped (5 total tests)
```

Command: `forge test --match-contract '^H3FlashClean$' -vv` (rc=0;
`grep -c "INVARIANT VIOLATED"` on the captured output: 0).

## What this scorecard demonstrates

The clean twin's bonus path performs the full settle dance the
flash-accounting protocol requires (`take`, then `sync`, ERC20
transfer from the hook's own funding, `settle`). Across 12,800 fuzzed
handler calls (three real router actors, swaps in both directions,
with and without the bonus opt-in byte in hookData), no unlock ever
ended with an unsettled hook delta: zero `CurrencyNotSettled` reverts.
The deterministic regression leg additionally confirms the clean bonus
path really moves balances: the sender router receives the bonus and
the hook's funding balance drops by exactly that amount, with the
delta closed at end of unlock.
