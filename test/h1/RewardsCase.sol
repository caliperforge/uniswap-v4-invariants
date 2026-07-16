// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {V4TestBase} from "../base/V4TestBase.sol";
import {InvariantRouter} from "../../src/routers/InvariantRouter.sol";
import {RewardsHook} from "../../src/cases/h1-hookdata-identity/clean/RewardsHook.sol";
import {RewardsHandler} from "./RewardsHandler.sol";

/// C-H1 shared test surface. The clean and planted suites inherit this
/// contract unchanged and differ ONLY in which twin artifact they
/// deploy, so the property surface is provably identical across twins.
///
/// Property asserted (stateful invariant, 256 runs x depth 50):
///
///   h1_rewards_identity:
///     hook.rewardsTo(R) == handler.swapsByRouter(R) for every router R
///
///   The handler's ledger extends by CLEAN semantics only (credit
///   follows the router that performed the swap; hookData never
///   consulted). The clean twin stays in lockstep. The planted twin
///   reads the recipient from hookData, so the first fuzzed swap whose
///   hookData names a different address diverges the ledgers and fires
///   the marker.
abstract contract RewardsCase is V4TestBase {
    RewardsHook internal hook;
    RewardsHandler internal handler;
    PoolKey internal key;

    /// Twin selection point: the ONLY difference between the clean and
    /// planted suites.
    function _hookArtifact() internal pure virtual returns (string memory);

    function setUp() public {
        deployV4Core();

        handler = new RewardsHandler(IPoolManager(address(manager)), token0, token1);
        token0.mint(address(handler), 1_000_000e18);
        token1.mint(address(handler), 1_000_000e18);

        // Hook lives at a beforeSwap+afterSwap flag address
        // (deployCodeTo runs the constructor there, so the hook's
        // permission self-check passes).
        address hookAddr = deployHookTo(
            _hookArtifact(),
            abi.encode(address(manager)),
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG),
            0xF1
        );
        hook = RewardsHook(hookAddr);

        key = initPoolWithLiquidity(IHooks(hookAddr), 3000, 60);
        handler.init(key, hook);

        // Fuzz only the handler's swap selector; init and the view
        // surface are not fuzz targets (fail_on_revert is on).
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = RewardsHandler.swap.selector;
        targetSelector(StdInvariant.FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // ------------------------- invariant leg -------------------------

    function invariant_h1_rewardsTo_match_swapsByRouter() public {
        for (uint256 i = 0; i < handler.ROUTER_COUNT(); i++) {
            address r = address(handler.routers(i));
            // Stops at the FIRST divergent router: requireInvariant
            // prints the marker and fails the run immediately.
            requireInvariant(hook.rewardsTo(r) == handler.swapsByRouter(r), "h1_rewards_identity");
        }
    }

    // ----------------------- regression leg --------------------------

    /// Deterministic regression sequence: router A performs one swap
    /// while the hookData names router B's address as recipient.
    ///
    /// Clean twin: hookData plays no part in the identity decision; the
    /// credit lands on A (the manager-forwarded sender) and B stays at
    /// zero; the assertion holds.
    /// Planted twin: the hook reads the recipient from hookData; the
    /// credit lands on B instead of A; the marker fires and the test
    /// fails.
    function test_regression_h1_hookDataNamesDifferentRecipient() public {
        InvariantRouter routerA = newRouterActor(address(this));
        InvariantRouter routerB = newRouterActor(address(this));

        swapExactIn(routerA, key, -1e17, abi.encode(address(routerB)));

        requireInvariant(
            hook.rewardsTo(address(routerA)) == 1 && hook.rewardsTo(address(routerB)) == 0, "h1_rewards_identity"
        );
    }

    // --------------------------- unit leg ----------------------------

    /// One swap with empty hookData credits exactly one point to the
    /// performing router, and hook and handler ledgers agree. Router 1
    /// seeds are in-range so _bound leaves them unchanged.
    function test_unit_rewardCreditedToPerformingRouter() public {
        handler.swap(1, 5e16, 0, true);
        address r = address(handler.routers(1));
        assertEq(hook.rewardsTo(r), 1, "reward not credited to performing router");
        assertEq(hook.rewardsTo(r), handler.swapsByRouter(r), "ledgers diverge on unit path");
        assertEq(hook.totalRewards(), 1, "total rewards != 1 after one swap");
    }

    /// Conservation across the two callbacks: every swap that enters
    /// beforeSwap and completes credits exactly one point, so
    /// swapsStarted == totalRewards on BOTH twins (the planted twin
    /// moves credit between identities, it never mints or loses points).
    function test_unit_swapStartRewardConservation() public {
        handler.swap(0, 5e16, 0, true);
        handler.swap(1, 5e16, 1, false);
        handler.swap(2, 5e16, 1, true);
        assertEq(hook.swapsStarted(), 3, "swapsStarted != swap count");
        assertEq(hook.swapsStarted(), hook.totalRewards(), "started swaps and credited points diverge");
    }

    /// Only the real PoolManager may call the hook callbacks; this test
    /// contract is not the manager.
    function test_unit_onlyManagerCallsCallbacks() public {
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 0});
        vm.expectRevert(RewardsHook.NotManager.selector);
        hook.beforeSwap(address(this), key, params, "");
        vm.expectRevert(RewardsHook.NotManager.selector);
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");
    }
}
