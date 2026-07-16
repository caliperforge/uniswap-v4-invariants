// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/* UNISWAP V4 IMPORTS */
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

/* LOCAL IMPORTS */
import {AlphixGlobalConstants} from "../vendor/alphix-main/AlphixGlobalConstants.sol";

/// @title DynamicFeeLibPlanted (case A1 PLANTED twin: direction guard removed)
/// @notice Byte-copy of Alphix's audited `DynamicFeeLib` from
/// `../vendor/alphix-main/DynamicFee.sol`, with the direction guard in
/// `_applyFeeAdjustment` removed.
///
/// The TWIN-DIFF is confined to a single hunk inside `_applyFeeAdjustment`
/// (see the `PLANTED twin-diff BEGIN/END` markers below). Every other
/// byte of this file — SPDX, pragma, imports, ALPHA_NUMERATOR,
/// PoolParams / OobState struct shapes, `withinBounds`, `computeNewFee`,
/// `_computeOobFee`, `clampFee`, `ema` — is character-for-character
/// identical to the vendored library, so the property surface across the
/// clean and planted twins is provably the same modulo the direction
/// guard.
///
/// What the diff does: instead of adding `deltaUp` on upper-OOB pokes
/// and subtracting `deltaDown` on lower-OOB pokes, the planted variant
/// SUBTRACTS on BOTH branches. On an upper-OOB poke (where the audited
/// library increases the fee toward `maxFee`) the planted library
/// decreases it toward `minFee`. That is a direct violation of
/// `fee_direction_monotonicity`.
library DynamicFeeLibPlanted {
    using FullMath for uint256;

    uint256 internal constant ALPHA_NUMERATOR = 2 * AlphixGlobalConstants.ONE_WAD;

    struct PoolParams {
        uint24 minFee;
        uint24 maxFee;
        uint24 baseMaxFeeDelta;
        uint24 lookbackPeriod;
        uint256 minPeriod;
        uint256 ratioTolerance;
        uint256 linearSlope;
        uint256 maxCurrentRatio;
        uint256 upperSideFactor;
        uint256 lowerSideFactor;
    }

    struct OobState {
        bool lastOobWasUpper;
        uint24 consecutiveOobHits;
    }

    function withinBounds(uint256 target, uint256 tol, uint256 current)
        internal
        pure
        returns (bool upper, bool inBand)
    {
        uint256 delta = target.mulDiv(tol, AlphixGlobalConstants.ONE_WAD);
        uint256 lowerBound = target > delta ? target - delta : 0;
        uint256 upperBound = target + delta;
        bool lower = current < lowerBound;
        upper = current > upperBound;
        inBand = !(lower || upper);
    }

    function computeNewFee(
        uint24 currentFee,
        uint256 currentRatio,
        uint256 targetRatio,
        uint256 globalMaxAdjRate,
        PoolParams memory p,
        OobState memory s
    ) internal pure returns (uint24 newFee, OobState memory sOut) {
        sOut.lastOobWasUpper = s.lastOobWasUpper;
        sOut.consecutiveOobHits = s.consecutiveOobHits;

        (bool isUpper, bool inBand) = withinBounds(targetRatio, p.ratioTolerance, currentRatio);
        if (targetRatio == 0 || inBand) {
            sOut.consecutiveOobHits = 0;
            return (clampFee(uint256(currentFee), p.minFee, p.maxFee), sOut);
        }

        return _computeOobFee(currentFee, currentRatio, targetRatio, globalMaxAdjRate, p, sOut, isUpper);
    }

    function _computeOobFee(
        uint24 currentFee,
        uint256 currentRatio,
        uint256 targetRatio,
        uint256 globalMaxAdjRate,
        PoolParams memory p,
        OobState memory sOut,
        bool isUpper
    ) private pure returns (uint24 newFee, OobState memory) {
        uint256 deviation = isUpper ? (currentRatio - targetRatio) : (targetRatio - currentRatio);
        uint256 adjustmentRate = deviation.mulDiv(p.linearSlope, targetRatio);
        if (adjustmentRate > globalMaxAdjRate) adjustmentRate = globalMaxAdjRate;

        return _applyFeeAdjustment(currentFee, adjustmentRate, p, sOut, isUpper);
    }

    function _applyFeeAdjustment(
        uint24 currentFee,
        uint256 adjustmentRate,
        PoolParams memory p,
        OobState memory sOut,
        bool isUpper
    ) private pure returns (uint24, OobState memory) {
        uint24 streak = (isUpper != sOut.lastOobWasUpper) ? 1 : sOut.consecutiveOobHits + 1;
        sOut.lastOobWasUpper = isUpper;
        sOut.consecutiveOobHits = streak;

        uint256 feeDelta = uint256(currentFee).mulDiv(adjustmentRate, AlphixGlobalConstants.ONE_WAD);

        uint256 maxFeeDelta = uint256(p.baseMaxFeeDelta) * uint256(streak);
        if (feeDelta > maxFeeDelta) feeDelta = maxFeeDelta;

        uint256 feeAcc = uint256(currentFee);

        // ---- PLANTED twin-diff BEGIN (direction guard removed) --------------
        // Audited library (clean twin) branches on `isUpper`:
        //   isUpper == true  →  feeAcc += deltaUp  (fee walks toward maxFee)
        //   isUpper == false →  feeAcc -= deltaDown (fee walks toward minFee)
        //
        // Planted variant applies the LOWER branch unconditionally: on any
        // OOB poke, whether the pool is above or below its target band, the
        // fee walks TOWARD minFee. Upper-OOB pokes then violate
        // `fee_direction_monotonicity` because `newFee < oldFee` where the
        // audited library requires `newFee >= oldFee`. Every other byte of
        // `_applyFeeAdjustment` — streak update, feeDelta computation,
        // baseMaxFeeDelta throttle, sideFactor scaling, final clampFee — is
        // identical across twins.
        uint256 deltaDown = feeDelta.mulDiv(p.lowerSideFactor, AlphixGlobalConstants.ONE_WAD);
        if (deltaDown >= feeAcc) {
            return (p.minFee, sOut);
        } else {
            unchecked {
                feeAcc -= deltaDown;
            }
        }
        // Silence the "unused parameter" warning without changing behavior:
        // the audited library uses `p.upperSideFactor` inside the upper
        // branch this planted variant deletes.
        isUpper; p.upperSideFactor;
        // ---- PLANTED twin-diff END ------------------------------------------

        return (clampFee(feeAcc, p.minFee, p.maxFee), sOut);
    }

    function clampFee(uint256 fee, uint24 minFee, uint24 maxFee) internal pure returns (uint24) {
        if (fee < minFee) return minFee;
        if (fee > maxFee) return maxFee;
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint24(fee);
    }

    function ema(uint256 currentRatio, uint256 oldTargetRatio, uint24 lookbackPeriod)
        internal
        pure
        returns (uint256 newTargetRatio)
    {
        uint256 alpha = ALPHA_NUMERATOR / (uint256(lookbackPeriod) + 1);
        if (currentRatio >= oldTargetRatio) {
            uint256 up = (currentRatio - oldTargetRatio).mulDiv(alpha, AlphixGlobalConstants.ONE_WAD);
            return oldTargetRatio + up;
        } else {
            uint256 down = (oldTargetRatio - currentRatio).mulDiv(alpha, AlphixGlobalConstants.ONE_WAD);
            return oldTargetRatio - down;
        }
    }
}
