// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

interface IMoonpotManager {
    function currentRoundId() external view returns (uint256);

    function company() external view returns (address);

    function pendingLiquidityUsdc() external view returns (uint256);
}
