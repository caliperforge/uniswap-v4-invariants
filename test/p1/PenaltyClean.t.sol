// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {PenaltyCase} from "./PenaltyCase.sol";

/// C-P1 clean twin suite: `_afterAddLiquidity` captures v4-core's
/// reported feesAccrued into the pending penalty base on every add-
/// event, so a removal within the penalty window that follows an
/// increase still sees the full epoch's fees in its penalty
/// computation. All legs pass; no marker is ever printed.
contract P1PenaltyClean is PenaltyCase {
    function _hookArtifact() internal pure override returns (string memory) {
        return "src/cases/p1-liquidity-penalty-conservation/clean/LiquidityPenaltyHook.sol:LiquidityPenaltyHook";
    }
}
