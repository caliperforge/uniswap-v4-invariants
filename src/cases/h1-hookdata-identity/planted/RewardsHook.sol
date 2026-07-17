// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";

/// @title RewardsHook (case C-H1: reward-recipient identity from hookData)
/// @notice beforeSwap/afterSwap hook that credits one reward point per
/// completed swap into an internal ledger. The bug class lives in WHERE
/// the recipient identity comes from: `sender` (the first argument of
/// every hook callback, defined by the v4-core IHooks natspec as "The
/// initial msg.sender for the swap call", i.e. the router contract that
/// called PoolManager.swap) is an identity supplied by the manager from
/// the call context; `hookData` is arbitrary swapper-supplied bytes.
/// A reward, rebate, or points system keyed to hookData lets whoever
/// crafts the swap calldata direct credit to any address.
///
/// The clean and planted twins are byte-identical except the recipient
/// assignment line in afterSwap; the case README shows the diff.
///
/// beforeSwap counts swap starts; afterSwap credits the reward. The
/// conservation observable (`swapsStarted == totalRewards`) holds on
/// both twins; the identity observable (`rewardsTo[R]` matching each
/// router R's own swap count) is what the planted twin breaks.
contract RewardsHook {
    IPoolManager public immutable manager;

    /// Reward points credited per recipient, in points (1 per swap).
    mapping(address => uint256) public rewardsTo;

    /// Total points credited across all recipients.
    uint256 public totalRewards;

    /// Swaps that entered beforeSwap. Every started swap that completes
    /// credits exactly one point, so swapsStarted == totalRewards after
    /// any sequence of completed swaps.
    uint256 public swapsStarted;

    event RewardCredited(address indexed recipient, uint256 points);

    error NotManager();

    constructor(IPoolManager manager_) {
        manager = manager_;
        // Self-check: the deployment address must encode exactly this
        // hook's permission bitmap (beforeSwap + afterSwap) in its low
        // 14 bits, or the real PoolManager would never dispatch to it.
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

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (msg.sender != address(manager)) revert NotManager();
        swapsStarted++;
        // No beforeSwapReturnDelta permission: the manager checks the
        // selector and ignores the zero delta and zero fee override.
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// Recipient specification: the reward belongs to the identity that
    /// performed the swap, which is `sender`, the manager-forwarded
    /// msg.sender of PoolManager.swap. hookData is swapper-supplied
    /// bytes and must play no part in the identity decision. The
    /// `hookData` parameter is named in BOTH twins so the callback
    /// signature is byte-identical and the twin diff stays on the
    /// recipient assignment line alone (it is unused in the clean twin
    /// by design).
    function afterSwap(
        address sender,
        PoolKey calldata,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata hookData
    ) external returns (bytes4, int128) {
        if (msg.sender != address(manager)) revert NotManager();
        address recipient = hookData.length >= 32 ? abi.decode(hookData, (address)) : sender;
        rewardsTo[recipient] += 1;
        totalRewards += 1;
        emit RewardCredited(recipient, 1);
        // The manager reverts on a wrong selector return; the int128 is
        // the hook's unspecified-currency delta, unused by this hook.
        return (IHooks.afterSwap.selector, 0);
    }
}
