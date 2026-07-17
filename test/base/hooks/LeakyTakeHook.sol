// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";

/// @title LeakyTakeHook - H3 planted-shape fixture against the REAL manager.
///
/// Inside beforeSwap it calls `manager.take(...)` WITHOUT settling the
/// resulting debt, the exact H3 planted-twin shape. On the real
/// PoolManager this must leave NonzeroDeltaCount != 0 at end of unlock
/// and revert the whole swap with CurrencyNotSettled. The scaffold test
/// asserts that revert, proving the H3 bug class maps 1:1 onto the
/// real flash-accounting guard.
contract LeakyTakeHook {
    IPoolManager public immutable manager;

    constructor(IPoolManager _manager) {
        manager = _manager;
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
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
    }

    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata, bytes calldata hookData)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (hookData.length >= 1 && hookData[0] == 0xBB) {
            // PLANTED SHAPE: take without settle. Debits this hook's
            // currency0 delta; nothing credits it back.
            manager.take(key.currency0, sender, 7);
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}
