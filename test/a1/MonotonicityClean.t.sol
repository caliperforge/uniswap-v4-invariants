// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {MonotonicityCase} from "./MonotonicityCase.sol";
import {IPokable} from "./MonotonicityHandler.sol";
import {AlphixFeeHarnessClean} from
    "../../src/cases/a1-alphix-fee-direction-monotonicity/clean/AlphixFeeHarnessClean.sol";
import {DynamicFeeLib} from
    "../../src/cases/a1-alphix-fee-direction-monotonicity/vendor/alphix-main/DynamicFee.sol";

/// C-A1 clean twin suite. Wires the harness through Alphix's real
/// audited `DynamicFeeLib` (vendored under
/// `src/cases/a1-alphix-fee-direction-monotonicity/vendor/alphix-main/`).
/// All legs must pass; no `INVARIANT VIOLATED` marker is ever printed.
contract A1MonotonicityClean is MonotonicityCase {
    AlphixFeeHarnessClean internal cleanHarness;

    function _deployHarness() internal override returns (IPokable) {
        // Params modeled on Alphix's own `test/alphix/BaseAlphix.t.sol`
        // spread + the bounds in `AlphixGlobalConstants`; picked so both
        // OOB shoulders are reachable inside the handler's MIN_RATIO..
        // MAX_RATIO fuzz range.
        DynamicFeeLib.PoolParams memory p = DynamicFeeLib.PoolParams({
            minFee: 100,                 // 0.01%
            maxFee: 100_000,             // 10%
            baseMaxFeeDelta: 100,        // 0.01% per streak unit
            lookbackPeriod: 30,          // days
            minPeriod: 1 hours,
            ratioTolerance: 3e16,        // 3% band
            linearSlope: 1e18,           // 1.0 sensitivity
            maxCurrentRatio: 1e21,       // matches handler MAX_RATIO
            upperSideFactor: 1e18,       // 1.0
            lowerSideFactor: 1e18        // 1.0
        });
        cleanHarness = new AlphixFeeHarnessClean(
            3000,   // initial fee (0.3%), well inside [min, max]
            1e18,   // initial target ratio
            1e19,   // global max adj rate (TEN_WAD, Alphix default)
            p
        );
        return IPokable(address(cleanHarness));
    }

    function _lastPokeWasOob() internal view override returns (bool) {
        return cleanHarness.lastPokeWasOob();
    }
    function _lastPokeIsUpper() internal view override returns (bool) {
        return cleanHarness.lastPokeIsUpper();
    }
    function _lastPokeOldFee() internal view override returns (uint24) {
        return cleanHarness.lastPokeOldFee();
    }
    function _lastPokeNewFee() internal view override returns (uint24) {
        return cleanHarness.lastPokeNewFee();
    }
    function _currentFee() internal view override returns (uint24) {
        return cleanHarness.currentFee();
    }
    function _minFee() internal view override returns (uint24) {
        return cleanHarness.params().minFee;
    }
    function _maxFee() internal view override returns (uint24) {
        return cleanHarness.params().maxFee;
    }
}
