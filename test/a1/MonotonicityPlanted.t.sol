// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {MonotonicityCase} from "./MonotonicityCase.sol";
import {IPokable} from "./MonotonicityHandler.sol";
import {AlphixFeeHarnessPlanted} from
    "../../src/cases/a1-alphix-fee-direction-monotonicity/planted/AlphixFeeHarnessPlanted.sol";
import {DynamicFeeLibPlanted} from
    "../../src/cases/a1-alphix-fee-direction-monotonicity/planted/DynamicFeePlanted.sol";

/// C-A1 planted twin suite. Wires the harness through the planted
/// `DynamicFeeLibPlanted` (byte-copy of Alphix's audited library with
/// the direction guard removed; see `PLANTED twin-diff BEGIN/END` in
/// `src/cases/a1-alphix-fee-direction-monotonicity/planted/DynamicFeePlanted.sol`).
///
/// Expected outcome: the invariant leg
/// `invariant_a1_feeDirectionMonotonicity` and the regression leg
/// `test_regression_a1_upperOobDropsFee` both fail with
/// `INVARIANT VIOLATED a1_fee_direction_monotonicity`. The
/// `a1_fee_bounds` invariant still holds (both twins run `clampFee`
/// identically); the `test_unit_upperOobMutatesFee` leg still passes
/// (the harness IS hooked up, and the planted library still mutates
/// currentFee — it just moves it in the wrong direction).
contract A1MonotonicityPlanted is MonotonicityCase {
    AlphixFeeHarnessPlanted internal plantedHarness;

    function _deployHarness() internal override returns (IPokable) {
        DynamicFeeLibPlanted.PoolParams memory p = DynamicFeeLibPlanted.PoolParams({
            minFee: 100,
            maxFee: 100_000,
            baseMaxFeeDelta: 100,
            lookbackPeriod: 30,
            minPeriod: 1 hours,
            ratioTolerance: 3e16,
            linearSlope: 1e18,
            maxCurrentRatio: 1e21,
            upperSideFactor: 1e18,
            lowerSideFactor: 1e18
        });
        plantedHarness = new AlphixFeeHarnessPlanted(3000, 1e18, 1e19, p);
        return IPokable(address(plantedHarness));
    }

    function _lastPokeWasOob() internal view override returns (bool) {
        return plantedHarness.lastPokeWasOob();
    }
    function _lastPokeIsUpper() internal view override returns (bool) {
        return plantedHarness.lastPokeIsUpper();
    }
    function _lastPokeOldFee() internal view override returns (uint24) {
        return plantedHarness.lastPokeOldFee();
    }
    function _lastPokeNewFee() internal view override returns (uint24) {
        return plantedHarness.lastPokeNewFee();
    }
    function _currentFee() internal view override returns (uint24) {
        return plantedHarness.currentFee();
    }
    function _minFee() internal view override returns (uint24) {
        return plantedHarness.params().minFee;
    }
    function _maxFee() internal view override returns (uint24) {
        return plantedHarness.params().maxFee;
    }
}
