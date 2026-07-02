// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {VaultCase} from "./VaultCase.sol";

/// C-B1 clean twin suite: correct rounding discipline in the withdraw
/// path's pro-rata sourcing. All legs pass; no marker is ever printed.
contract B1VaultClean is VaultCase {
    function _hookArtifact() internal pure override returns (string memory) {
        return "src/cases/b1-custom-accounting/clean/LiquidityVaultHook.sol:LiquidityVaultHook";
    }
}
