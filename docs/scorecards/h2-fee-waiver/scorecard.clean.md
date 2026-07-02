# C-H2 fee waiver via hookData, CLEAN scorecard

> Captured from a local run on 2026-07-01 with the pinned toolchain:
> Foundry (forge) 1.7.1, solc 0.8.26, v4-core submodule at tag `v4.0.0`
> (`e50237c43811bd9b526eff40f26772152a42daba`), forge-std `v1.9.4`.
> Real PoolManager deployed in-test; swaps driven through this repo's
> own `InvariantRouter` (no mock, no v4-core test routers).

## Summary

- Invariant asserted: `invariant_h2_accruedFees_match_expected`
  (`hook.accruedFees() == handler.expectedFees()`)
- Invariants violated: **0**
- Tests collected: **5** (1 invariant + 1 deterministic regression + 3 unit)
- Tests passed: **5**, failed: **0**, rc: **0**
- `INVARIANT VIOLATED` markers printed: **0**
- Campaign: 256 runs x depth 50 = 12,800 handler calls, 0 reverts,
  0 discards (`fail_on_revert = true` held throughout)

## Test results

```
Ran 5 tests for test/h2/FeeSwitchClean.t.sol:H2FeeSwitchClean
[PASS] invariant_h2_accruedFees_match_expected() (runs: 256, calls: 12800, reverts: 0)
[PASS] test_regression_h2_unentitledWaiverViaHookData() (gas: 1051541)
[PASS] test_unit_allowlistedSenderPaysZero() (gas: 168795)
[PASS] test_unit_feeSizedOnSpecifiedAmount() (gas: 236841)
[PASS] test_unit_onlyAdminSetsAllowlist() (gas: 8488)
Suite result: ok. 5 passed; 0 failed; 0 skipped; finished in 2.17s (2.17s CPU time)
Ran 1 test suite in 2.17s (2.17s CPU time): 5 tests passed, 0 failed, 0 skipped (5 total tests)
```

## What this scorecard demonstrates

The clean twin's waiver decision reads ONLY the admin-set allowlist.
Across 12,800 fuzzed handler calls (three real router actors, swaps in
both directions with and without the waiver byte in hookData, allowlist
churn through the admin path), `hook.accruedFees()` stayed in lockstep
with the handler's independently computed expected-fee ledger. The
deterministic regression leg confirms a crafted `hookData = 0x01` from a
never-allowlisted router still pays the full fee
(1e18 * 30 / 10_000 = 3e15) on the clean twin.
