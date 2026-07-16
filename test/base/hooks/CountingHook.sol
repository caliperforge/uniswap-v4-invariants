// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";

/// @title CountingHook - scaffold fixture against the REAL v4-core surface.
///
/// Proves the harness shape works against the real PoolManager:
///   - constructor self-validates its permission bitmap via
///     Hooks.validateHookPermissions (reverts unless deployed at an
///     address whose low 14 bits encode exactly beforeSwap|afterSwap),
///   - beforeSwap/afterSwap record sender + hookData so the test can
///     assert the real PoolManager forwarded both faithfully, the
///     exact observable H1/H2 ride on.
///
/// Only beforeSwap and afterSwap are implemented; the real PoolManager
/// dispatches hook calls off the address bitmap, so unimplemented
/// callbacks are never invoked when their flag bits are zero.
contract CountingHook {
    uint256 public beforeSwapCount;
    uint256 public afterSwapCount;
    address public lastSender;
    bytes public lastHookData;

    constructor() {
        Hooks.validateHookPermissions(
            IHooks(address(this)),
            Hooks.Permissions({
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
            })
        );
    }

    function beforeSwap(address sender, PoolKey calldata, SwapParams calldata, bytes calldata hookData)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        beforeSwapCount++;
        lastSender = sender;
        lastHookData = hookData;
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        returns (bytes4, int128)
    {
        afterSwapCount++;
        return (IHooks.afterSwap.selector, 0);
    }
}
