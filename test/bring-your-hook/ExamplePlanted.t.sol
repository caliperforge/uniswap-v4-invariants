// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {ExampleAdopterTest} from "./ExampleAdopter.t.sol";
// WHY this import exists although the twin is only named by artifact
// string: forge's filtered test runs compile the test tree sparsely,
// and a test-tree source nothing imports gets no artifact, so
// deployCodeTo would miss it. Hooks under src/ (where the walkthrough
// puts YOUR copies) do not need this.
import {CountingHook as PlantedCountingHook} from "./planted/CountingHook.sol";

/// @title ExampleAdopterPlanted (the optional red leg, demonstrated)
/// @notice Same property surface as ExampleAdopterTest; the ONLY
/// difference is the artifact string, which points at a copy of the
/// hook carrying a single-hunk seeded specification violation (its
/// afterSwap tally skips oneForZero swaps). The suite must FAIL with
/// the `INVARIANT VIOLATED byoh_example_afterSwap_count` marker; the
/// CI planted leg is green exactly when it does (inverted assertion).
/// The `Planted` contract-name suffix is the CI discovery convention.
contract ExampleAdopterPlanted is ExampleAdopterTest {
    function _hookArtifact() internal pure override returns (string memory) {
        return "test/bring-your-hook/planted/CountingHook.sol:CountingHook";
    }
}
