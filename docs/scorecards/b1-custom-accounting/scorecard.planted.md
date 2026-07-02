# C-B1 custom-accounting rounding integrity, PLANTED scorecard

> Captured from a local run on 2026-07-01 with the pinned toolchain:
> Foundry (forge) 1.7.1, solc 0.8.26, v4-core submodule at tag `v4.0.0`
> (`e50237c43811bd9b526eff40f26772152a42daba`), forge-std `v1.9.4`.
> Real PoolManager deployed in-test; swaps driven through this repo's
> own `InvariantRouter` (no mock, no v4-core test routers).

## Summary

- Seeded specification violation: the withdraw path's idle-balance
  rounding direction is flipped (single-hunk twin diff, shown in the
  case README). Correct for a single operation; each remainder-carrying
  withdrawal releases one wei less from the balance split than from
  `trackedTotal`, and the drift accumulates.
- Detection legs failed (as required): **3**
  - `invariant_b1_balanceSplitIntegrity` (fuzz campaign, shrunk to a
    minimal deposit-then-withdraw pair)
  - `invariant_b1_conservation` (fuzz campaign, shrunk to a minimal
    deposit-then-withdraw pair)
  - `test_regression_b1_roundingDriftAccumulates` (deterministic:
    40 withdrawals accumulate 20 wei of split drift, one ordinary swap
    unmasks the MIN estimate, both markers print)
- Unit legs passed on the planted twin too: **5** (they exercise exact
  divisions, on which both twins agree by design)
- rc: **1** (nonzero, as the planted CI leg requires)
- `INVARIANT VIOLATED` markers printed: **4**
  (`b1_balance_split_integrity` x2, `b1_accounting_conservation` x2)

## Test results (detection legs)

```
Ran 8 tests for test/b1/VaultPlanted.t.sol:B1VaultPlanted
[FAIL: assertion failed]
	[Sequence] (original: 2, shrunk: 2)
		... calldata=deposit(uint256) args=[1152921504606846976 [1.152e18]]
		... calldata=withdraw(uint256) args=[0]
 invariant_b1_balanceSplitIntegrity() (runs: 0, calls: 0, reverts: 0)
Logs:
  INVARIANT VIOLATED b1_balance_split_integrity

[FAIL: assertion failed]
	[Sequence] (original: 2, shrunk: 2)
		... calldata=deposit(uint256) args=[1152921504606846976 [1.152e18]]
		... calldata=withdraw(uint256) args=[0]
 invariant_b1_conservation() (runs: 0, calls: 0, reverts: 0)
Logs:
  INVARIANT VIOLATED b1_accounting_conservation

[FAIL] test_regression_b1_roundingDriftAccumulates() (gas: 1294059)
Logs:
  INVARIANT VIOLATED b1_balance_split_integrity
  INVARIANT VIOLATED b1_accounting_conservation

[PASS] test_unit_depositMintsSharesAndSplitsBalance() (gas: 187179)
[PASS] test_unit_hookObservesSwapsOnRealPool() (gas: 161406)
[PASS] test_unit_minEstimateConservativeUnderSpotMove() (gas: 321026)
[PASS] test_unit_onlyAdminSetsPool() (gas: 14955)
[PASS] test_unit_withdrawPaysGrossMinusDeclaredFee() (gas: 222777)
Suite result: FAILED. 5 passed; 3 failed; 0 skipped; finished in 262.33ms (479.70ms CPU time)

Fuzz seed: 0xd8c31590492429b5db3a536de06a9e3b539a105756dd7243459cad32d5f4462f (use `--fuzz-seed` to reproduce)
```

Command: `rm -rf cache/invariant/failures && forge test
--match-contract '^B1VaultPlanted$' -vv` (fresh campaign, no replay;
rc=1; `grep -c 'INVARIANT VIOLATED'` on the captured output: 4).

(Fuzzed handler arguments are bounded inside the handler; the shrunk
sequences above reduce to one deposit and one small withdrawal whose
pro-rata divisions carry remainders, the minimal trigger for the class.)

## What this scorecard demonstrates

The planted twin's flipped idle-leg rounding is caught three ways: the
split-integrity identity fires on the first remainder-carrying
withdrawal of a fuzz walk, the conservation check fires as soon as the
drifted books are compared against actual holdings with the MIN
estimate on its balance-derived leg, and the deterministic regression
reproduces the accumulation (1 wei per remainder-carrying step, 20 wei
across 40 withdrawals) with certainty on every run. The clean twin runs
the identical test surface with zero markers.
