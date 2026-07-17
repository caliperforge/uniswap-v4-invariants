// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {V4TestBase} from "./base/V4TestBase.sol";
import {CountingHook} from "./base/hooks/CountingHook.sol";

/// Scaffold proof, the feasibility spike's three test shapes reproduced
/// at the v4.0.0 pin with THIS repo's plumbing: real PoolManager
/// deployed in-test, hook at a flag-encoded address, one real swap
/// driven through unlock/flash-accounting via our own InvariantRouter
/// (v4-core's UNLICENSED test routers are not imported) and forge-std
/// derived test tokens (no AGPL mock-token dependency).
contract ScaffoldTest is V4TestBase {
    CountingHook hook;
    PoolKey key;

    function setUp() public {
        deployV4Core();
        address hookAddr =
            deployHookTo("CountingHook.sol:CountingHook", "", uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG), 0);
        hook = CountingHook(hookAddr);
        key = initPoolWithLiquidity(IHooks(hookAddr), 3000, 60);
    }

    function test_realSwap_throughUnlock_hookSeesSenderAndHookData() public {
        uint256 bal0Before = token0.balanceOf(address(this));
        uint256 bal1Before = token1.balanceOf(address(this));

        bytes memory hookData = abi.encodePacked(address(this)); // H1-shaped payload

        // Exact-input swap: negative amountSpecified per v4 convention.
        swapExactIn(router, key, -1e18, hookData);

        // The real PoolManager called both hook legs exactly once...
        assertEq(hook.beforeSwapCount(), 1, "beforeSwap not called");
        assertEq(hook.afterSwapCount(), 1, "afterSwap not called");
        // ...forwarded OUR router as `sender` (the H1 identity surface)...
        assertEq(hook.lastSender(), address(router), "sender != router");
        // ...and forwarded hookData verbatim (the H1/H2 tamper surface).
        assertEq(hook.lastHookData(), hookData, "hookData not forwarded");

        // The swap really moved funds through unlock + flash accounting.
        assertLt(token0.balanceOf(address(this)), bal0Before, "no token0 spent");
        assertGt(token1.balanceOf(address(this)), bal1Before, "no token1 received");
    }

    function test_hookAddressWithoutFlags_reverts() public {
        // Same hook code at a no-flag address must be rejected by the
        // real PoolManager at pool-initialize time.
        address badAddr = address(0x1234000000000000000000000000000000000000);
        vm.etch(badAddr, address(hook).code);
        PoolKey memory badKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 30,
            hooks: IHooks(badAddr)
        });
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, badAddr));
        manager.initialize(badKey, SQRT_PRICE_1_1);
    }

    function test_H3shape_takeWithoutSettle_trippedByRealFlashAccounting() public {
        // H3 planted shape on the REAL manager: hook takes inside
        // beforeSwap without settling; unlock must revert with
        // CurrencyNotSettled (NonzeroDeltaCount != 0 at end of unlock).
        address leakyAddr = deployHookTo(
            "LeakyTakeHook.sol:LeakyTakeHook", abi.encode(manager), uint160(Hooks.BEFORE_SWAP_FLAG), 0xAA
        );
        PoolKey memory leakyKey = initPoolWithLiquidity(IHooks(leakyAddr), 3000, 60);

        // Benign path (no 0xBB trigger byte) completes.
        swapExactIn(router, leakyKey, -1e18, "");

        // Planted path fires the real guard.
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        swapExactIn(router, leakyKey, -1e18, hex"BB");
    }
}
