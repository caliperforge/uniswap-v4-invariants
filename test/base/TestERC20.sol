// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {MockERC20} from "forge-std/mocks/MockERC20.sol";

/// @notice forge-std's MockERC20 (MIT) with a constructor and a public
/// mint. Exists so no test file ever reaches for v4-core's nested
/// AGPL-3.0-only mock-token dependency, which is banned from this
/// repository (see NOTICE).
contract TestERC20 is MockERC20 {
    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        initialize(name_, symbol_, decimals_);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
