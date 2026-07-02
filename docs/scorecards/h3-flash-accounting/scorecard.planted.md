# C-H3 settle protocol on the flash-accounting surface, PLANTED scorecard

> Captured from a local run on 2026-07-01 with the pinned toolchain:
> Foundry (forge) 1.7.1, solc 0.8.26, v4-core submodule at tag `v4.0.0`
> (`e50237c43811bd9b526eff40f26772152a42daba`), forge-std `v1.9.4`.
> Real PoolManager deployed in-test; swaps driven through this repo's
> own `InvariantRouter` (no mock, no v4-core test routers).

## Summary

- Seeded specification violation (single-hunk twin diff): the bonus
  path's `take` opens a -BONUS delta against the manager and the
  settle step (`sync`, ERC20 transfer, `settle`) is missing, so the
  delta is never closed.
- Invariants violated: **1** (`invariant_h3_bonusPathSettles`)
- Tests collected: **5**; passed: **3** (unit leg, off the bonus
  path), failed: **2** (invariant + deterministic regression), rc:
  **1**
- `INVARIANT VIOLATED h3_flash_accounting` markers printed: **2**
  (one per failing leg)
- Fuzzer counterexample shrunk to a single opted-in swap (the minimal
  trigger): the first bonus-path swap ends its unlock with the hook's
  delta open, and the real manager's transient-storage guard reverts
  the whole swap with `CurrencyNotSettled`.

## Test results

```
No files changed, compilation skipped
{"timestamp":1782950599,"event":"failure","invariant":"invariant_h3_bonusPathSettles","target":"test/h3/FlashPlanted.t.sol:H3FlashPlanted","reason":"assertion failed"}

Ran 5 tests for test/h3/FlashPlanted.t.sol:H3FlashPlanted
[FAIL: assertion failed]
	[Sequence] (original: 4, shrunk: 1)
		sender=0x000000000000000000000000000000000000079F addr=[test/h3/FlashHandler.sol:FlashHandler]0xc7183455a4C133Ae270771860664b6B7ec320bB1 calldata=swap(uint256,uint256,bool,bool) args=[494202918207762808493046576467966347395446777617665270301201007999693821156 [4.942e74], 13814676683847362002929355708371691301342234423112240258 [1.381e55], true, true]
 invariant_h3_bonusPathSettles() (runs: 0, calls: 0, reverts: 0)

╭--------------+----------+-------+---------+----------╮
| Contract     | Selector | Calls | Reverts | Discards |
+======================================================+
| FlashHandler | swap     | 4     | 0       | 0        |
╰--------------+----------+-------+---------+----------╯

Logs:
  INVARIANT VIOLATED h3_flash_accounting

[FAIL] test_regression_h3_takeWithoutSettleTripsGuard() (gas: 260732)
Logs:
  INVARIANT VIOLATED h3_flash_accounting

[PASS] test_unit_benignSwapLeavesFundingUntouched() (gas: 141497)
[PASS] test_unit_bonusFundingInPlace() (gas: 17725)
[PASS] test_unit_onlyManagerCallsBeforeSwap() (gas: 15971)
Suite result: FAILED. 3 passed; 2 failed; 0 skipped; finished in 25.53ms (24.83ms CPU time)

Ran 1 test suite in 26.14ms (25.53ms CPU time): 3 tests passed, 2 failed, 0 skipped (5 total tests)

Failing tests:
Encountered 2 failing tests in test/h3/FlashPlanted.t.sol:H3FlashPlanted
[FAIL: assertion failed]
	[Sequence] (original: 4, shrunk: 1)
		sender=0x000000000000000000000000000000000000079F addr=[test/h3/FlashHandler.sol:FlashHandler]0xc7183455a4C133Ae270771860664b6B7ec320bB1 calldata=swap(uint256,uint256,bool,bool) args=[494202918207762808493046576467966347395446777617665270301201007999693821156 [4.942e74], 13814676683847362002929355708371691301342234423112240258 [1.381e55], true, true]
 invariant_h3_bonusPathSettles() (runs: 0, calls: 0, reverts: 0)
[FAIL] test_regression_h3_takeWithoutSettleTripsGuard() (gas: 260732)

Encountered a total of 2 failing tests, 3 tests succeeded

Fuzz seed: 0xa5bdb0d371500da3a4b8c491ae5c71a3ae75756092a5190c9b9877510fd25d1f (use `--fuzz-seed` to reproduce)
```

Command: `rm -rf cache/invariant/failures && forge test
--match-contract '^H3FlashPlanted$' -vv` (fresh campaign, no replay;
rc=1; `grep -c "INVARIANT VIOLATED h3_flash_accounting"` on the
captured output: 2).

## What this scorecard demonstrates

The planted twin's missing settle step is caught two independent ways:
the stateful invariant campaign trips on the first fuzzed swap that
opts into the bonus path, and the deterministic regression sequence
trips on its fixed bonus-path swap. Both print the
`INVARIANT VIOLATED h3_flash_accounting` marker and the suite exits
nonzero, which is exactly what the CI planted leg asserts. Honest
sizing: the real manager's runtime guard already prevents any funds
from leaving the manager this way; what the planted leg demonstrates
is the pre-deploy CI catch of a bug that would otherwise ship as a
production availability failure (every opted-in user swap reverting).
