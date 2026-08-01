// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// Relative-import sibling of TallyFeeHook. Exists so the CI
/// adopter-generator leg exercises the wrapper's recursive
/// relative-import vendoring (ci/vendor_hook_imports.py), not just a
/// single-file copy. A fixture with no relative sibling would leave
/// the vendoring walker untested.
library TallyMath {
    function bump(uint256 x) internal pure returns (uint256) {
        return x + 1;
    }
}
