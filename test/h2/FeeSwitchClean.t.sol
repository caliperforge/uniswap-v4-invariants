// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {FeeSwitchCase} from "./FeeSwitchCase.sol";

/// C-H2 clean-twin suite: all legs must pass, zero INVARIANT VIOLATED
/// markers (CI clean leg).
contract H2FeeSwitchClean is FeeSwitchCase {
    function _hookArtifact() internal pure override returns (string memory) {
        return "src/cases/h2-fee-waiver/clean/FeeSwitchHook.sol:FeeSwitchHook";
    }
}
