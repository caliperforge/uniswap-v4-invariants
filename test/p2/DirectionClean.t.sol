// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {DirectionCase} from "./DirectionCase.sol";

/// C-P2 clean twin suite: `afterSwap` selects the swap's unspecified
/// side direction-aware (matching the post-`2678eb9` shape encoded in
/// OpenZeppelin's `BaseDynamicAfterFee` v1.1.0). All legs pass; no
/// marker is ever printed.
contract P2DirectionClean is DirectionCase {
    function _hookArtifact() internal pure override returns (string memory) {
        return "src/cases/p2-dynamicfee-direction-integrity/clean/DemoDynamicAfterFeeHook.sol:DemoDynamicAfterFeeHook";
    }
}
