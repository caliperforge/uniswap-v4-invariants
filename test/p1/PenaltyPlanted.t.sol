// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {PenaltyCase} from "./PenaltyCase.sol";

/// C-P1 planted twin suite: `_afterAddLiquidity` omits the capture of
/// v4-core's reported feesAccrued into the pending penalty base (single-
/// hunk twin diff). The invariant and regression legs fail with the
/// `INVARIANT VIOLATED p1_liquidity_penalty_conservation` marker; the
/// CI planted leg discovers this suite by the `*Planted` name and
/// asserts exactly that failure.
contract P1PenaltyPlanted is PenaltyCase {
    function _hookArtifact() internal pure override returns (string memory) {
        return "src/cases/p1-liquidity-penalty-conservation/planted/LiquidityPenaltyHook.sol:LiquidityPenaltyHook";
    }
}
