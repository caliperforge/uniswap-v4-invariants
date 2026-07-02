# C-H1 reward-recipient identity from hookData, PLANTED scorecard

> Captured from a local run on 2026-07-01 with the pinned toolchain:
> Foundry (forge) 1.7.1, solc 0.8.26, v4-core submodule at tag `v4.0.0`
> (`e50237c43811bd9b526eff40f26772152a42daba`), forge-std `v1.9.4`.
> Real PoolManager deployed in-test; swaps driven through this repo's
> own `InvariantRouter` (no mock, no v4-core test routers).

## Summary

- Invariant asserted: `invariant_h1_rewardsTo_match_swapsByRouter`
  (`hook.rewardsTo(R) == handler.swapsByRouter(R)` for every router R)
- Invariants violated: **1** (fires on the planted twin)
- Tests collected: **5** (1 invariant + 1 deterministic regression + 3 unit)
- Tests passed: **3** (the unit legs, which do not touch the bug path)
- Tests failed: **2** (invariant + deterministic regression; BOTH print
  the `INVARIANT VIOLATED h1_rewards_identity` marker)
- Suite rc: nonzero (forge exits 1)
- Counterexample: shrunk from a 3-call sequence to a SINGLE handler
  call: one fuzzed swap whose hookData names a different router's
  address as recipient

## Test results

```
Ran 5 tests for test/h1/RewardsPlanted.t.sol:H1RewardsPlanted
[FAIL: assertion failed]
	[Sequence] (original: 3, shrunk: 1)
		sender=0x0000000000000000000000000000000000004ca0 addr=[test/h1/RewardsHandler.sol:RewardsHandler]0xc7183455a4C133Ae270771860664b6B7ec320bB1 calldata=swap(uint256,uint256,uint256,bool) args=[7589348 [7.589e6], 346624711236326251293751252649681125062789 [3.466e41], 9179486805618924815700421944899705 [9.179e33], true]
 invariant_h1_rewardsTo_match_swapsByRouter() (runs: 0, calls: 0, reverts: 0)
Logs:
  INVARIANT VIOLATED h1_rewards_identity
  INVARIANT VIOLATED h1_rewards_identity

[FAIL] test_regression_h1_hookDataNamesDifferentRecipient() (gas: 1967639)
Logs:
  INVARIANT VIOLATED h1_rewards_identity

[PASS] test_unit_onlyManagerCallsCallbacks() (gas: 19317)
[PASS] test_unit_rewardCreditedToPerformingRouter() (gas: 259190)
[PASS] test_unit_swapStartRewardConservation() (gas: 492593)
Suite result: FAILED. 3 passed; 2 failed; 0 skipped; finished in 25.28ms (25.21ms CPU time)
Ran 1 test suite in 25.86ms (25.28ms CPU time): 3 tests passed, 2 failed, 0 skipped (5 total tests)
```

Fuzz seed of the captured campaign:
`0xd190f8e5aa80086554a733a81aa88d7c0eba348704c8dc0b9db76bf9c188592a`.
The bug does not depend on the seed: any swap whose hookData names an
address other than the performing router diverges the ledgers, and the
deterministic regression leg encodes that shape seed-independently.
(The invariant leg's marker prints twice: once when the campaign hits
the divergence and once during counterexample shrinking.)

## What this scorecard demonstrates

The planted twin's single-line change (recipient read from
ABI-decoded `hookData` when 32 or more bytes are supplied, instead of
from `sender`) is caught two ways:

- **Fuzz leg**: the campaign hits a swap whose hookData names a
  different router within the first three calls; the hook credits the
  named address while the handler's clean-semantics ledger credits the
  performing router; Foundry shrinks the counterexample to that one
  call.
- **Deterministic regression leg**: router A performs one swap while
  the hookData names router B. The credit lands on B instead of A and
  the marker fires at that first divergent swap.

The three unit legs pass on the planted twin because swaps with empty
hookData still credit `sender`, and total points remain conserved
(`swapsStarted == totalRewards`) on both twins. That is the point of
the twin discipline: conformance-style tests and totals-only checks
stay green while the per-identity property test catches the
specification violation.
