# C-P2 fee-direction integrity, CLEAN scorecard

> Captured from a local run on 2026-07-06 with the pinned toolchain:
> Foundry (forge) 1.7.1, solc 0.8.26, v4-core submodule at tag `v4.0.0`,
> forge-std `v1.9.4`, `openzeppelin-uniswap-hooks` submodule at tag
> `v1.1.0` (`e59fe72`): the on-disk reference against which the vendored
> `BaseDynamicAfterFee.sol` under
> `src/cases/p2-dynamicfee-direction-integrity/vendor/oz-uniswap-hooks-v1.1.0/`
> can be byte-compared. Real `PoolManager` deployed in-test; every swap
> driven through this repo's own `InvariantRouter` (no mock, no v4-core
> test routers).

## Summary

- Invariants asserted:
  - `invariant_p2_dynamicfeeDirectionIntegrity`
    (`hook.accruedProtocolFees(c) == handler.expectedFees(c)` for
    `c ∈ {currency0, currency1}`)
  - `invariant_p2_feeSolvency`
    (`hook.accruedProtocolFees(c) <= hook.cumulativeUnspecifiedAmount(c)`)
- Invariants violated: **0**
- Tests collected: **5** (2 invariants + 1 deterministic regression + 2 unit)
- Tests passed: **5**, failed: **0**, rc: **0**
- `INVARIANT VIOLATED` markers printed: **0**
- Campaigns: 2 x (256 runs x depth 50) = 25,600 handler calls total,
  0 reverts, 0 discards (`fail_on_revert = true` held throughout)

## Test results

```
Ran 5 tests for test/p2/DirectionClean.t.sol:P2DirectionClean
[PASS] invariant_p2_dynamicfeeDirectionIntegrity() (runs: 256, calls: 12800, reverts: 0)

╭------------------+----------+-------+---------+----------╮
| Contract         | Selector | Calls | Reverts | Discards |
+==========================================================+
| DirectionHandler | swap     | 12800 | 0       | 0        |
╰------------------+----------+-------+---------+----------╯

[PASS] invariant_p2_feeSolvency() (runs: 256, calls: 12800, reverts: 0)

╭------------------+----------+-------+---------+----------╮
| Contract         | Selector | Calls | Reverts | Discards |
+==========================================================+
| DirectionHandler | swap     | 12800 | 0       | 0        |
╰------------------+----------+-------+---------+----------╯

[PASS] test_regression_p2_directionMismatchOnExactOutput() (gas: 502348)
[PASS] test_unit_exactInputSwapsMatchOnBothTwins() (gas: 429942)
[PASS] test_unit_hookObservesExactInputSwap() (gas: 258424)
Suite result: ok. 5 passed; 0 failed; 0 skipped; finished in 4.02s (7.75s CPU time)

Ran 1 test suite in 4.02s (4.02s CPU time): 5 tests passed, 0 failed, 0 skipped (5 total tests)
```

## What this scorecard demonstrates

The clean twin subclasses OpenZeppelin's audited `BaseDynamicAfterFee`
(vendored under `../vendor/oz-uniswap-hooks-v1.1.0/`, byte-faithful in
the fee-arithmetic block; see the vendor NOTICE for the patch policy).
Its `_afterSwap` override byte-copies the post-`2678eb9` arithmetic
block character-for-character: after selecting the unspecified currency
via `(params.amountSpecified < 0 == params.zeroForOne)` (unchanged
context across the fix), it branches on `exactInput` and computes
`feeAmount = unspec - target` on exactInput or
`feeAmount = target - unspec` on exactOutput, no-op on the guard
inequalities. Across 25,600 fuzzed handler calls (bounded swap amount,
all four `(zeroForOne, exactInput)` combinations exercised via a mode
seed against the real `PoolManager`), the hook's per-currency
`accruedProtocolFees` ledger advanced in lockstep with the handler's
per-currency `expectedFees` reference ledger on every step; the
deterministic regression's `(exactInput, exactOutput, exactInput)`
sequence produced identical accruals in the hook and handler ledgers
across all three steps and both currencies.
