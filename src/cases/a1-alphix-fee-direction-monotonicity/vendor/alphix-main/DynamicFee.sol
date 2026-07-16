// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/* UNISWAP V4 IMPORTS */
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

/* LOCAL IMPORTS */
import {AlphixGlobalConstants} from "./AlphixGlobalConstants.sol";

/**
 * @title DynamicFeeLib.
 * @notice Pure library for Alphix dynamic fee algorithm and EMA.
 * @dev All math uses 1e18 fixed-point for ratios; fees are uint24.
 */
library DynamicFeeLib {
    using FullMath for uint256;

    uint256 internal constant ALPHA_NUMERATOR = 2 * AlphixGlobalConstants.ONE_WAD;

    /**
     * @dev Pool parameters for dynamic fee algorithm.
     * - Bounds are used by clampFee and to validate updates.
     * - Algorithm knobs control fee sensitivity and EMA smoothing.
     * - Side multipliers to throttle by side.
     */
    struct PoolParams {
        // Bounds
        uint24 minFee;
        uint24 maxFee;
        // Algorithm knobs
        uint24 baseMaxFeeDelta; // e.g. 100 = 0.01%
        uint24 lookbackPeriod; // EMA smoothing factor alpha = 1e18 * 2 / (lookbackPeriod + 1)
        uint256 minPeriod; // cooldown in seconds
        uint256 ratioTolerance; // band half-width in 1e18
        uint256 linearSlope; // sensitivity vs relative deviation in 1e18
        uint256 maxCurrentRatio; // maximum allowed current ratio in 1e18
        // Side multipliers
        uint256 upperSideFactor;
        uint256 lowerSideFactor;
    }

    /**
     * @dev Tracks out-of-band dynamics per pool.
     * - consecutiveOobHits increases within a same-side run and resets in band.
     * - lastOobWasUpper records side to reset streak on flip.
     */
    struct OobState {
        bool lastOobWasUpper;
        uint24 consecutiveOobHits;
    }

    /**
     * @notice Check whether a current ratio is within a symmetric tolerance band.
     * @param target The target ratio in 1e18.
     * @param tol The tolerance width around the target ratio in 1e18 (e.g. 3e16 = 3%).
     * @param current The current ratio in 1e18.
     * @return upper True if above upper bound.
     * @return inBand True if within tolerated bounds.
     */
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

    /**
     * @notice Compute a new fee based on current/target ratios and parameters.
     * @dev Implements:
     *  - in-band: clamp current fee to bounds, reset streak.
     *  - out-of-band: update streak/side, compute deviation and linear adjustment rate,
     *    clamp to maxAdjRate, convert to feeDelta proportional to current fee,
     *    throttle by streak, then apply side multiplier and clamp to bounds.
     * @param currentFee The current LP fee from pool.
     * @param currentRatio The current ratio in 1e18.
     * @param targetRatio The target ratio in 1e18.
     * @param globalMaxAdjRate Global cap for adjustmentRate in 1e18.
     * @param p Pool parameters (including bounds and factors).
     * @param s Out-of-band state (streak and last side).
     * @return newFee The clamped new LP fee.
     * @return sOut The updated out-of-band state.
     */
    function computeNewFee(
        uint24 currentFee,
        uint256 currentRatio,
        uint256 targetRatio,
        uint256 globalMaxAdjRate,
        PoolParams memory p,
        OobState memory s
    ) internal pure returns (uint24 newFee, OobState memory sOut) {
        // Create a proper copy of the input state
        sOut.lastOobWasUpper = s.lastOobWasUpper;
        sOut.consecutiveOobHits = s.consecutiveOobHits;

        (bool isUpper, bool inBand) = withinBounds(targetRatio, p.ratioTolerance, currentRatio);
        if (targetRatio == 0 || inBand) {
            sOut.consecutiveOobHits = 0;
            return (clampFee(uint256(currentFee), p.minFee, p.maxFee), sOut);
        }

        return _computeOobFee(currentFee, currentRatio, targetRatio, globalMaxAdjRate, p, sOut, isUpper);
    }

    /**
     * @dev Helper function for out-of-band fee computation to reduce stack depth.
     */
    function _computeOobFee(
        uint24 currentFee,
        uint256 currentRatio,
        uint256 targetRatio,
        uint256 globalMaxAdjRate,
        PoolParams memory p,
        OobState memory sOut,
        bool isUpper
    ) private pure returns (uint24 newFee, OobState memory) {
        // Compute adjustment
        uint256 deviation = isUpper ? (currentRatio - targetRatio) : (targetRatio - currentRatio);
        uint256 adjustmentRate = deviation.mulDiv(p.linearSlope, targetRatio);
        if (adjustmentRate > globalMaxAdjRate) adjustmentRate = globalMaxAdjRate;

        return _applyFeeAdjustment(currentFee, adjustmentRate, p, sOut, isUpper);
    }

    /**
     * @dev Helper function to apply fee adjustment and throttling to reduce stack depth.
     */
    function _applyFeeAdjustment(
        uint24 currentFee,
        uint256 adjustmentRate,
        PoolParams memory p,
        OobState memory sOut,
        bool isUpper
    ) private pure returns (uint24, OobState memory) {
        // Compute and update streak
        uint24 streak = (isUpper != sOut.lastOobWasUpper) ? 1 : sOut.consecutiveOobHits + 1;
        sOut.lastOobWasUpper = isUpper;
        sOut.consecutiveOobHits = streak;

        uint256 feeDelta = uint256(currentFee).mulDiv(adjustmentRate, AlphixGlobalConstants.ONE_WAD);

        // throttle by streak
        uint256 maxFeeDelta = uint256(p.baseMaxFeeDelta) * uint256(streak);
        if (feeDelta > maxFeeDelta) feeDelta = maxFeeDelta;

        uint256 feeAcc = uint256(currentFee);

        // throttle by side
        if (isUpper) {
            uint256 deltaUp = feeDelta.mulDiv(p.upperSideFactor, AlphixGlobalConstants.ONE_WAD);
            unchecked {
                feeAcc += deltaUp;
            } // clamped below
        } else {
            uint256 deltaDown = feeDelta.mulDiv(p.lowerSideFactor, AlphixGlobalConstants.ONE_WAD);
            if (deltaDown >= feeAcc) {
                return (p.minFee, sOut);
            } else {
                unchecked {
                    feeAcc -= deltaDown;
                } // clamped below
            }
        }

        return (clampFee(feeAcc, p.minFee, p.maxFee), sOut);
    }

    /**
     * @notice Clamp a fee to pool-type bounds.
     * @param fee The fee to clamp.
     * @param minFee The minimum fee of the pool type.
     * @param maxFee The maximum fee of the pool type.
     * @return The clamped fee.
     */
    function clampFee(uint256 fee, uint24 minFee, uint24 maxFee) internal pure returns (uint24) {
        if (fee < minFee) return minFee;
        if (fee > maxFee) return maxFee;
        // Casting to uint24 is safe because fee is clamped between minFee and maxFee (both uint24)
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint24(fee);
    }

    /**
     * @notice Exponential moving average: new = old + alpha*(current - old).
     * @dev alpha = 2 * AlphixGlobalConstants.ONE_WAD / (lookbackPeriod + 1).
     * @param currentRatio The current ratio in 1e18.
     * @param oldTargetRatio The previous target ratio in 1e18.
     * @param lookbackPeriod The lookbackPeriod in days.
     * @return newTargetRatio The updated target ratio in 1e18.
     */
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
