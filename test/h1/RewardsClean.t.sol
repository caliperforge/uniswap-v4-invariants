// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {RewardsCase} from "./RewardsCase.sol";

/// C-H1 clean-twin suite: all legs must pass, zero INVARIANT VIOLATED
/// markers (CI clean leg).
contract H1RewardsClean is RewardsCase {
    function _hookArtifact() internal pure override returns (string memory) {
        return "src/cases/h1-hookdata-identity/clean/RewardsHook.sol:RewardsHook";
    }
}
