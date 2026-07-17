// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {FlashCase} from "./FlashCase.sol";

/// C-H3 planted twin suite: the bonus path opens a delta via take and
/// never settles it (the seeded specification violation). The
/// invariant and regression legs fail with the
/// `INVARIANT VIOLATED h3_flash_accounting` marker; rc!=0. The suite
/// name ends in `Planted` so the CI planted leg discovers it.
contract H3FlashPlanted is FlashCase {
    function _hookArtifact() internal pure override returns (string memory) {
        return "src/cases/h3-flash-accounting/planted/FlashHook.sol:FlashHook";
    }
}
