// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/// @title InvariantRouter
/// @notice Thin unlock-callback router for driving swaps and liquidity
/// modifications through the real PoolManager in tests. Our own code:
/// v4-core's in-repo test routers carry `SPDX: UNLICENSED` and are
/// deliberately not imported anywhere in this repository.
///
/// Settlement model: after the inner manager call, every non-zero
/// currency delta is resolved immediately. Negative delta (caller owes
/// the pool): sync, ERC20 transfer from the payer to the manager,
/// settle. Positive delta (pool owes the caller): take to the payer.
/// The payer must have approved this router. Hook-side deltas are the
/// hook's own responsibility; an unsettled hook delta reverts the whole
/// unlock with `CurrencyNotSettled` (the observable H3 rides on).
contract InvariantRouter is IUnlockCallback {
    error NotPoolManager();

    IPoolManager public immutable manager;

    enum Action {
        Swap,
        ModifyLiquidity
    }

    struct CallData {
        Action action;
        address payer;
        PoolKey key;
        bytes params; // abi-encoded SwapParams or ModifyLiquidityParams
        bytes hookData;
    }

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    function swap(PoolKey memory key, SwapParams memory params, bytes memory hookData)
        external
        returns (BalanceDelta delta)
    {
        bytes memory result =
            manager.unlock(abi.encode(CallData(Action.Swap, msg.sender, key, abi.encode(params), hookData)));
        delta = abi.decode(result, (BalanceDelta));
    }

    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes memory hookData)
        external
        returns (BalanceDelta delta)
    {
        bytes memory result =
            manager.unlock(abi.encode(CallData(Action.ModifyLiquidity, msg.sender, key, abi.encode(params), hookData)));
        delta = abi.decode(result, (BalanceDelta));
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotPoolManager();
        CallData memory data = abi.decode(rawData, (CallData));

        BalanceDelta delta;
        if (data.action == Action.Swap) {
            delta = manager.swap(data.key, abi.decode(data.params, (SwapParams)), data.hookData);
        } else {
            // feesAccrued is informational; callerDelta already includes it.
            (delta,) = manager.modifyLiquidity(
                data.key, abi.decode(data.params, (ModifyLiquidityParams)), data.hookData
            );
        }

        _resolve(data.key.currency0, data.payer, delta.amount0());
        _resolve(data.key.currency1, data.payer, delta.amount1());
        return abi.encode(delta);
    }

    function _resolve(Currency currency, address payer, int128 amount) internal {
        // Widen to int256 before negating so type(int128).min cannot overflow.
        if (amount < 0) {
            manager.sync(currency);
            // amount is int128 < 0, so -int256(amount) is in (0, 2^127] and
            // the uint256 cast is safe. The transferFrom return is not
            // checked because on revert the whole unlock unwinds and any
            // non-standard non-reverting failure leaves the delta unsettled,
            // which the PoolManager surfaces as CurrencyNotSettled.
            // forge-lint: disable-next-line(erc20-unchecked-transfer,unsafe-typecast)
            IERC20Minimal(Currency.unwrap(currency)).transferFrom(payer, address(manager), uint256(-int256(amount)));
            manager.settle();
        } else if (amount > 0) {
            // amount is int128 > 0, so int256(amount) is in (0, 2^127) and
            // the uint256 cast is safe.
            // forge-lint: disable-next-line(unsafe-typecast)
            manager.take(currency, payer, uint256(int256(amount)));
        }
    }
}
