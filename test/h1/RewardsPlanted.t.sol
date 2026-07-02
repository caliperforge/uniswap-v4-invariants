// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {RewardsCase} from "./RewardsCase.sol";

/// C-H1 planted-twin suite: the invariant and regression legs must
/// FAIL with INVARIANT VIOLATED markers and nonzero rc (CI planted
/// leg, inverted assertion). The `Planted` contract-name suffix is the
/// CI discovery convention.
contract H1RewardsPlanted is RewardsCase {
    function _hookArtifact() internal pure override returns (string memory) {
        return "src/cases/h1-hookdata-identity/planted/RewardsHook.sol:RewardsHook";
    }
}
