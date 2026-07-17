// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {FeeSwitchCase} from "./FeeSwitchCase.sol";

/// C-H2 planted-twin suite: the invariant and regression legs must FAIL
/// with INVARIANT VIOLATED markers and nonzero rc (CI planted leg,
/// inverted assertion). The `Planted` contract-name suffix is the CI
/// discovery convention.
contract H2FeeSwitchPlanted is FeeSwitchCase {
    function _hookArtifact() internal pure override returns (string memory) {
        return "src/cases/h2-fee-waiver/planted/FeeSwitchHook.sol:FeeSwitchHook";
    }
}
