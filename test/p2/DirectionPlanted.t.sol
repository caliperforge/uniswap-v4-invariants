// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {DirectionCase} from "./DirectionCase.sol";

/// C-P2 planted twin suite: `afterSwap` selects the swap's unspecified
/// side direction-BLIND (single-hunk twin diff), reproducing the pre-
/// `2678eb9` shape reported in OpenZeppelin's Uniswap Hooks v1.1.0 RC 2
/// audit. The invariant and regression legs fail with the
/// `INVARIANT VIOLATED p2_dynamicfee_direction_integrity` marker; the
/// CI planted leg discovers this suite by the `*Planted` name and
/// asserts exactly that failure.
contract P2DirectionPlanted is DirectionCase {
    function _hookArtifact() internal pure override returns (string memory) {
        return
            "src/cases/p2-dynamicfee-direction-integrity/planted/DemoDynamicAfterFeeHook.sol:DemoDynamicAfterFeeHook";
    }
}
