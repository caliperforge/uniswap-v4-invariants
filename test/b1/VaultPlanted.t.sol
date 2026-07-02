// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {VaultCase} from "./VaultCase.sol";

/// C-B1 planted twin suite: the withdraw path's idle-leg rounding
/// direction is flipped (single-hunk twin diff). The invariant and
/// regression legs fail with the `INVARIANT VIOLATED` markers; the CI
/// planted leg discovers this suite by the `*Planted` name and asserts
/// exactly that failure.
contract B1VaultPlanted is VaultCase {
    function _hookArtifact() internal pure override returns (string memory) {
        return "src/cases/b1-custom-accounting/planted/LiquidityVaultHook.sol:LiquidityVaultHook";
    }
}
