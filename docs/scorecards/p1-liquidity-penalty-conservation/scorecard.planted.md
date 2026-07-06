# C-P1 liquidity-penalty conservation, PLANTED scorecard

> Captured from a local run on 2026-07-06 with the pinned toolchain:
> Foundry (forge) 1.7.1, solc 0.8.26, v4-core submodule at tag `v4.0.0`
> (`e50237c43811bd9b526eff40f26772152a42daba`), forge-std `v1.9.4`.
> Real PoolManager deployed in-test; every modifyLiquidity and swap
> driven through this repo's own `InvariantRouter`. This is the
> INVERTED assertion of the CI planted leg: a green scorecard here is
> a red `forge test` run WITH the marker printed.

## Summary

- Invariants asserted: same 2 as the clean scorecard.
- Invariants violated on this twin: **1**
  (`invariant_p1_penaltyConservation`)
- Tests collected: **6**
- Tests passed: **4**, failed: **2**, rc: **1**
- `INVARIANT VIOLATED p1_liquidity_penalty_conservation` printed: **2**
  (one from the stateful campaign, one from the deterministic
  regression)
- Stateful campaign: original counterexample of 5 handler calls,
  shrunk by forge to **3 handler calls**: swap -> addLiquidity ->
  removeLiquidity, all inside a single 10-block penalty window on top
  of the position seeded in setUp. The initial add is the handler's
  init() call (block 1); the fuzzed sequence realizes an
  `add -> swap -> increase -> remove` pattern in ~3 seconds of
  wall-clock at the default `runs = 256, depth = 50`.

## Test results

```
Ran 6 tests for test/p1/PenaltyPlanted.t.sol:P1PenaltyPlanted
[FAIL: assertion failed]
	[Sequence] (original: 5, shrunk: 3)
		sender=0x0000000000000000000000000000000000000288 addr=[test/p1/PenaltyHandler.sol:PenaltyHandler]0xc7183455a4C133Ae270771860664b6B7ec320bB1 calldata=swap(uint256) args=[20]
		sender=0x0000000000000000000000000000000000000545 addr=[test/p1/PenaltyHandler.sol:PenaltyHandler]0xc7183455a4C133Ae270771860664b6B7ec320bB1 calldata=addLiquidity(uint256) args=[2721153990054287564065143519426170791615720728747836172009054271595 [2.721e66]]
		sender=0x0000000000000000000000000000000000dc149E addr=[test/p1/PenaltyHandler.sol:PenaltyHandler]0xc7183455a4C133Ae270771860664b6B7ec320bB1 calldata=removeLiquidity(uint256) args=[28565260242440166285 [2.856e19]]
 invariant_p1_penaltyConservation() (runs: 0, calls: 0, reverts: 0)

╭----------------+-----------------+-------+---------+----------╮
| Contract       | Selector        | Calls | Reverts | Discards |
+===============================================================+
| PenaltyHandler | addLiquidity    | 1     | 0       | 0        |
|----------------+-----------------+-------+---------+----------|
| PenaltyHandler | removeLiquidity | 2     | 0       | 0        |
|----------------+-----------------+-------+---------+----------|
| PenaltyHandler | swap            | 2     | 0       | 0        |
╰----------------+-----------------+-------+---------+----------╯

Logs:
  INVARIANT VIOLATED p1_liquidity_penalty_conservation

[PASS] invariant_p1_solvency() (runs: 256, calls: 12800, reverts: 0)

╭----------------+-----------------+-------+---------+----------╮
| Contract       | Selector        | Calls | Reverts | Discards |
+===============================================================+
| PenaltyHandler | addLiquidity    | 4158  | 0       | 0        |
|----------------+-----------------+-------+---------+----------|
| PenaltyHandler | removeLiquidity | 4386  | 0       | 0        |
|----------------+-----------------+-------+---------+----------|
| PenaltyHandler | swap            | 4256  | 0       | 0        |
╰----------------+-----------------+-------+---------+----------╯

[FAIL] test_regression_p1_conservationOnIncreaseThenRemove() (gas: 365136)
Logs:
  INVARIANT VIOLATED p1_liquidity_penalty_conservation

[PASS] test_unit_hookObservesInitialAdd() (gas: 21595)
[PASS] test_unit_removeOutsideWindowDonatesZero() (gas: 263503)
[PASS] test_unit_singleAddSwapRemoveMatchesOnBothTwins() (gas: 323259)
Suite result: FAILED. 4 passed; 2 failed; 0 skipped; finished in 3.49s (5.69s CPU time)

Ran 1 test suite in 3.49s (3.49s CPU time): 4 tests passed, 2 failed, 0 skipped (6 total tests)
```

## What this scorecard demonstrates

The planted twin's `afterAddLiquidity` omits the
`pendingPenaltyBase += fees` line, so any fees v4-core auto-collects
on an add-event that lands inside the penalty window are lost from
the base the next remove uses to compute its penalty. The stateful
campaign's fuzzer shrunk to a three-call counterexample realizing the
`add-event -> swap -> add-event -> remove-event` pattern the class
requires; the deterministic regression scripts the same pattern with
one add-event before the shrunk trace and fires the marker with
certainty. The solvency leg still passes: the planted twin only
UNDER-donates (the actual ledger is smaller than the expected), never
over-donates, so the pre-fund cap is never reached.
