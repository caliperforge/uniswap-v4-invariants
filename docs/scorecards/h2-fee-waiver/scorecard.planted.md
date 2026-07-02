# C-H2 fee waiver via hookData, PLANTED scorecard

> Captured from a local run on 2026-07-01 with the pinned toolchain:
> Foundry (forge) 1.7.1, solc 0.8.26, v4-core submodule at tag `v4.0.0`
> (`e50237c43811bd9b526eff40f26772152a42daba`), forge-std `v1.9.4`.
> Real PoolManager deployed in-test; swaps driven through this repo's
> own `InvariantRouter` (no mock, no v4-core test routers).

## Summary

- Invariant asserted: `invariant_h2_accruedFees_match_expected`
  (`hook.accruedFees() == handler.expectedFees()`)
- Invariants violated: **1** (fires on the planted twin)
- Tests collected: **5** (1 invariant + 1 deterministic regression + 3 unit)
- Tests passed: **3** (the unit legs, which do not touch the bug path)
- Tests failed: **2** (invariant + deterministic regression; BOTH print the
  `INVARIANT VIOLATED h2_fee_waiver_via_hookdata` marker)
- Suite rc: nonzero (forge exits 1)
- Counterexample: shrunk from a 9-call sequence to a SINGLE handler
  call: one fuzzed swap with `claimWaiver = true` from a
  non-allowlisted router

## Test results

```
Ran 5 tests for test/h2/FeeSwitchPlanted.t.sol:H2FeeSwitchPlanted
[FAIL: assertion failed]
	[Sequence] (original: 9, shrunk: 1)
		sender=0x0000000000000000000000000000000000000C2e addr=[test/h2/FeeSwitchHandler.sol:FeeSwitchHandler]0xc7183455a4C133Ae270771860664b6B7ec320bB1 calldata=swap(uint256,uint256,bool,bool) args=[45299177519044 [4.529e13], 687549790193723030 [6.875e17], true, false]
 invariant_h2_accruedFees_match_expected() (runs: 0, calls: 0, reverts: 0)
Logs:
  INVARIANT VIOLATED h2_fee_waiver_via_hookdata

[FAIL] test_regression_h2_unentitledWaiverViaHookData() (gas: 1034073)
Logs:
  INVARIANT VIOLATED h2_fee_waiver_via_hookdata

[PASS] test_unit_allowlistedSenderPaysZero() (gas: 168859)
[PASS] test_unit_feeSizedOnSpecifiedAmount() (gas: 236935)
[PASS] test_unit_onlyAdminSetsAllowlist() (gas: 8488)
Suite result: FAILED. 3 passed; 2 failed; 0 skipped; finished in 27.27ms (26.16ms CPU time)
Ran 1 test suite in 28.17ms (27.27ms CPU time): 3 tests passed, 2 failed, 0 skipped (5 total tests)
```

Fuzz seed of the captured campaign:
`0x62e290cf3607aff4e15b05639ae10e6db626e1abc7518cd18038164034f73002`.
The bug does not depend on the seed: any swap that claims the hookData
waiver from a non-allowlisted router diverges the ledgers, and the
deterministic regression leg encodes that shape seed-independently.

## What this scorecard demonstrates

The planted twin's single-hunk change (waiver ALSO honored from
`hookData[0] == 0x01`) is caught two ways:

- **Fuzz leg**: the campaign hits a waiver-claiming swap from a
  non-allowlisted router within the first handful of calls; the hook
  accrues zero while the handler's clean-semantics ledger extends;
  Foundry shrinks the counterexample to that one call.
- **Deterministic regression leg**: a fresh, never-allowlisted router
  swaps 1e18 exact-input with crafted hookData `0x01`. The hook charges
  it nothing (`feesBy(unentitledSwapper) == 0` instead of 3e15) and the
  marker fires.

The three unit legs pass on the planted twin because the admin
allowlist path still works (the planted bug ADDS an evasion path, it
does not remove the legitimate one). That is the point of the twin
discipline: conformance-style tests stay green while the property test
catches the policy break.
