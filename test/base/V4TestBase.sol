// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {InvariantRouter} from "../../src/routers/InvariantRouter.sol";
import {TestERC20} from "./TestERC20.sol";

/// @title V4TestBase - shared deploy helpers + handler conventions for
/// every case suite. Deploys the REAL PoolManager in-test (no mock),
/// sorted test tokens, and our own InvariantRouter; places hooks at
/// flag-encoded addresses via deployCodeTo (no CREATE2 mining needed
/// in a test harness, which is why v4-periphery is not vendored).
abstract contract V4TestBase is Test {
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // 2^96, 1:1

    PoolManager internal manager;
    InvariantRouter internal router;
    TestERC20 internal token0;
    TestERC20 internal token1;

    function deployV4Core() internal {
        manager = new PoolManager(address(this));
        router = newRouterActor(address(this));

        TestERC20 a = new TestERC20("TokenA", "A", 18);
        TestERC20 b = new TestERC20("TokenB", "B", 18);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        token0.mint(address(this), 1_000_000e18);
        token1.mint(address(this), 1_000_000e18);
    }

    /// One router per fuzz actor: on the real surface each "router
    /// identity" the hook sees as `sender` is a distinct router
    /// contract instance (H1's identity surface), not an impersonated
    /// address. `payer` funds are approved to the new router.
    function newRouterActor(address payer) internal returns (InvariantRouter r) {
        r = new InvariantRouter(IPoolManager(address(manager)));
        if (address(token0) != address(0)) {
            vm.startPrank(payer);
            token0.approve(address(r), type(uint256).max);
            token1.approve(address(r), type(uint256).max);
            vm.stopPrank();
        }
    }

    /// Hook addresses must encode the permission bitmap in the low 14
    /// bits; deployCodeTo runs the constructor AT that address so the
    /// hook's Hooks.validateHookPermissions self-check passes.
    function deployHookTo(string memory artifact, bytes memory constructorArgs, uint160 flags, uint160 salt)
        internal
        returns (address hookAddr)
    {
        hookAddr = address(uint160(salt << 20) | flags);
        deployCodeTo(artifact, constructorArgs, hookAddr);
    }

    /// Pool at 1:1 with symmetric concentrated liquidity around tick 0,
    /// added through OUR router (never v4-core's UNLICENSED ones).
    function initPoolWithLiquidity(IHooks hooks, uint24 fee, int24 tickSpacing) internal returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: hooks
        });
        manager.initialize(key, SQRT_PRICE_1_1);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        router.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -10 * tickSpacing,
                tickUpper: 10 * tickSpacing,
                liquidityDelta: 1_000e18,
                salt: 0
            }),
            ""
        );
    }

    /// Exact-input swap zeroForOne through a given router actor.
    function swapExactIn(InvariantRouter via, PoolKey memory key, int256 amountSpecified, bytes memory hookData)
        internal
        returns (BalanceDelta delta)
    {
        delta = via.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            hookData
        );
    }

    /// House marker convention, parsed by the CI planted leg: a failing
    /// invariant prints `INVARIANT VIOLATED <name>` before failing the
    /// test, so a reviewer clicking the planted job sees the catch.
    function requireInvariant(bool holds, string memory name) internal {
        if (!holds) {
            console2.log(string.concat("INVARIANT VIOLATED ", name));
            fail();
        }
    }
}
