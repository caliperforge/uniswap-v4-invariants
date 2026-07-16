// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

/**
 * @title AlphixGlobalConstants
 * @notice Library containing all strict global bounds and constants used across the Alphix contracts.
 * @dev Centralizes constants to ensure consistency and prevent duplication across contracts.
 */
library AlphixGlobalConstants {
    /**
     * @dev WAD constants for fixed-point arithmetic
     */
    uint256 internal constant ONE_TENTH_WAD = 1e17;
    uint256 internal constant ONE_WAD = 1e18;
    uint256 internal constant TEN_WAD = 1e19;

    /**
     * @dev Maximum adjustment rate to protect when casting: uint24(uint256(currentFee).mulDiv(adjustmentRate, ONE_WAD))
     * Calculated as: (uint256(type(uint24).max) * ONE_WAD) / uint256(LPFeeLibrary.MAX_LP_FEE) - 1
     * Approximately 1.67e19
     */
    uint256 internal constant MAX_ADJUSTMENT_RATE =
        (uint256(type(uint24).max) * ONE_WAD) / uint256(LPFeeLibrary.MAX_LP_FEE) - 1;

    /**
     * @dev Pool type parameter bounds
     */

    // Time-related bounds (in seconds)
    uint256 internal constant MIN_PERIOD = 1 hours;
    uint256 internal constant MAX_PERIOD = 30 days;

    // Lookback period bounds (in days)
    uint24 internal constant MIN_LOOKBACK_PERIOD = 7;
    uint24 internal constant MAX_LOOKBACK_PERIOD = 365;

    // Fee bounds
    uint24 internal constant MIN_FEE = 1;

    // Current ratio bounds
    uint256 internal constant MAX_CURRENT_RATIO = 1e24;

    // Ratio and slope bounds
    uint256 internal constant MIN_RATIO_TOLERANCE = 1e15;
    uint256 internal constant MIN_LINEAR_SLOPE = 1e17;
}
