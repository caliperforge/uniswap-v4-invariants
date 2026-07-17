// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {BYOHInvariantBase, Observable} from "./BYOHInvariantBase.sol";
import {CountingHook} from "../base/hooks/CountingHook.sol";

/// @title ExampleAdopterTest (a complete bring-your-hook adoption)
/// @notice Worked example for the walkthrough in this directory's
/// README. The "adopted" hook is the repo's CountingHook fixture,
/// standing in for YOUR hook; every override below is one the
/// walkthrough tells you to write, and nothing here reaches into
/// harness internals.
///
/// Properties declared (the adopter's own semantics, stated as
/// observable/ledger pairs):
///   byoh_example_beforeSwap_count  hook's beforeSwap tally == swaps
///                                  the ledger saw
///   byoh_example_afterSwap_count   same for afterSwap
///   byoh_example_sender_identity   the sender the hook recorded is
///                                  the router that actually swapped
///                                  (the H1-class identity pattern)
contract ExampleAdopterTest is BYOHInvariantBase {
    CountingHook internal hook;

    // Expected-state ledgers, maintained ONLY from the onSwap
    // callback, never read back from the hook. Independence is what
    // makes the comparison a property and not a tautology.
    uint256 internal expectedSwaps;
    address internal expectedLastSender;

    // ----- step 1: say what to deploy -----

    /// virtual so ExamplePlanted.t.sol can re-point the artifact at
    /// the seeded-violation copy; the artifact string is the ONLY
    /// difference between the two suites (house twin discipline).
    function _hookArtifact() internal pure virtual override returns (string memory) {
        return "test/base/hooks/CountingHook.sol:CountingHook";
    }

    /// Must match the permissions the hook validates in its
    /// constructor. CountingHook validates beforeSwap + afterSwap.
    function _hookFlags() internal pure override returns (uint160) {
        return uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
    }

    // CountingHook's constructor takes no args, so the
    // _hookConstructorArgs default (empty) stands. A hook taking the
    // manager would override it with abi.encode(address(manager)).

    // ----- step 2: wire up typed access to the deployed hook -----

    function _afterSetUp() internal override {
        hook = CountingHook(hookAddress);
    }

    // ----- step 3: maintain expected-state ledgers -----

    function onSwap(address routerActor, bool, uint256, bytes calldata) external override {
        expectedSwaps++;
        expectedLastSender = routerActor;
    }

    // ----- step 4: pair observables with expectations -----

    function _observables() internal view override returns (Observable[] memory o) {
        o = new Observable[](3);
        o[0] = obs("byoh_example_beforeSwap_count", hook.beforeSwapCount(), expectedSwaps);
        o[1] = obs("byoh_example_afterSwap_count", hook.afterSwapCount(), expectedSwaps);
        o[2] = obs(
            "byoh_example_sender_identity",
            uint256(uint160(hook.lastSender())),
            uint256(uint160(expectedLastSender))
        );
    }

    // ----- optional: deterministic unit leg alongside the fuzz walk -----

    /// One scripted swap through the walk, asserted end to end. Seeds
    /// are in-range so _bound leaves them unchanged.
    function test_unit_exampleSingleSwapCounted() public {
        actions.swap(0, 1e16, true, 0);
        assertEq(hook.beforeSwapCount(), 1, "beforeSwap not seen");
        assertEq(hook.afterSwapCount(), 1, "afterSwap not seen");
        assertEq(hook.lastSender(), address(actions.routers(0)), "hook saw a different sender");
    }
}
