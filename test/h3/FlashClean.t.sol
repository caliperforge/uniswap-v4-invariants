// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {FlashCase} from "./FlashCase.sol";

/// C-H3 clean twin suite: the bonus path performs the full settle
/// dance. All legs pass; zero markers; rc=0.
contract H3FlashClean is FlashCase {
    function _hookArtifact() internal pure override returns (string memory) {
        return "src/cases/h3-flash-accounting/clean/FlashHook.sol:FlashHook";
    }
}
