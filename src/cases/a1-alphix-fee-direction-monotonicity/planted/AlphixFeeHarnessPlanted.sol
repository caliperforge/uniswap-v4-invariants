// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {DynamicFeeLibPlanted} from "./DynamicFeePlanted.sol";

/// @title AlphixFeeHarnessPlanted (case A1 PLANTED twin: direction guard removed)
/// @notice Byte-identical to `../clean/AlphixFeeHarnessClean.sol` except
/// for the single-line import at top (planted library instead of the
/// vendored audited library) and the two struct-type references that
/// follow from it. The `poke(...)` body and observation ledger are
/// character-for-character identical to the clean twin's.
///
/// The planted library subtracts on both OOB branches (see the
/// `PLANTED twin-diff BEGIN/END` markers in `DynamicFeePlanted.sol`),
/// so upper-OOB pokes decrease the fee instead of increasing it. The
/// invariant `fee_direction_monotonicity` catches this: any `lastPokeIsUpper`
/// walk step where `lastPokeNewFee < lastPokeOldFee` and the fee did not
/// clamp exactly to `maxFee` fires the marker.
contract AlphixFeeHarnessPlanted {
    uint24 public currentFee;
    uint256 public targetRatio;
    DynamicFeeLibPlanted.OobState internal _oobState;
    DynamicFeeLibPlanted.PoolParams internal _params;
    uint256 public globalMaxAdjRate;

    bool public lastPokeWasOob;
    bool public lastPokeIsUpper;
    uint24 public lastPokeOldFee;
    uint24 public lastPokeNewFee;
    uint256 public pokeCount;

    constructor(
        uint24 initialFee,
        uint256 initialTargetRatio,
        uint256 initialGlobalMaxAdjRate,
        DynamicFeeLibPlanted.PoolParams memory p
    ) {
        currentFee = initialFee;
        targetRatio = initialTargetRatio;
        globalMaxAdjRate = initialGlobalMaxAdjRate;
        _params = p;
    }

    function poke(uint256 currentRatio) external {
        (bool isUpper, bool inBand) = DynamicFeeLibPlanted.withinBounds(
            targetRatio, _params.ratioTolerance, currentRatio
        );
        bool wasOob = (targetRatio != 0) && !inBand;

        uint24 oldFee = currentFee;

        (uint24 newFee, DynamicFeeLibPlanted.OobState memory sOut) =
            DynamicFeeLibPlanted.computeNewFee(
                oldFee, currentRatio, targetRatio, globalMaxAdjRate, _params, _oobState
            );

        uint256 newTarget = DynamicFeeLibPlanted.ema(
            currentRatio, targetRatio, _params.lookbackPeriod
        );
        if (newTarget > _params.maxCurrentRatio) newTarget = _params.maxCurrentRatio;
        if (newTarget == 0) newTarget = 1;

        currentFee = newFee;
        targetRatio = newTarget;
        _oobState = sOut;

        lastPokeWasOob = wasOob;
        lastPokeIsUpper = isUpper;
        lastPokeOldFee = oldFee;
        lastPokeNewFee = newFee;
        pokeCount += 1;
    }

    function params() external view returns (DynamicFeeLibPlanted.PoolParams memory) {
        return _params;
    }

    function oobState() external view returns (DynamicFeeLibPlanted.OobState memory) {
        return _oobState;
    }
}
