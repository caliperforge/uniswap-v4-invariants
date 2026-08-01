// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// CI FIXTURE (T-P034-S1). Third-party-SHAPED hook for the
// adopter-generator CI leg (ci/adopter_generator_leg.sh).
//
// Why this file exists: the branch's CI was green while `./caliper
// run <path>` was broken for every input, because no CI job invoked
// the generator. This fixture arrives the way a stranger's hook
// arrives: through `./caliper run <path>`, with its OWN pragma
// (^0.8.26, not the harness's), the dominant third-party import
// convention (`@uniswap/v4-periphery/src/utils/BaseHook.sol`,
// `@uniswap/v4-core/...` npm prefixes, exactly the convention 5 of 10
// live sampled hooks used in T-P034-A), and a relative-import sibling
// (./libraries/TallyMath.sol) so the vendoring walker is exercised.
// It is NOT the bundled demo, NOT a hand-written adopter suite, and
// no test file for it is checked in: its test is GENERATED at CI
// time, which is the entire point of the leg.
//
// Deliberately NOT covered by this fixture (kept out of scope so the
// leg stays fast and hermetic): delta-returning flags, constructor
// prereqs beyond the pool manager, access-gated logic, exotic deps.
// Those are population walls (W3..W7), not generator regressions.
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import {TallyMath} from "./libraries/TallyMath.sol";

contract TallyFeeHook is BaseHook {
    uint256 public beforeSwapCount;
    uint256 public afterSwapCount;

    constructor(IPoolManager _manager) BaseHook(_manager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        beforeSwapCount = TallyMath.bump(beforeSwapCount);
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        afterSwapCount = TallyMath.bump(afterSwapCount);
        return (BaseHook.afterSwap.selector, 0);
    }
}
