// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {BaseDynamicAfterFee} from "../vendor/oz-uniswap-hooks-v1.1.0/BaseDynamicAfterFee.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SafeCast} from "openzeppelin/utils/math/SafeCast.sol";

/// @title DemoDynamicAfterFeeHook (case C-P2 CLEAN twin: fee-direction integrity)
/// @notice Subclass of OpenZeppelin's actual audited `BaseDynamicAfterFee` at
/// tag `v1.1.0`, vendored under `../vendor/oz-uniswap-hooks-v1.1.0/`. The
/// vendored base is byte-faithful (see the vendor NOTICE for the patch
/// policy). This twin's `_afterSwap` override BYTE-COPIES OZ's post-`2678eb9`
/// fee-arithmetic block (the exactInput / exactOutput branches; the fix
/// commit's actual delta) into a teaching-scale record-only shape: fee is
/// accrued to the per-currency ledger the case invariant reads, but no
/// ERC-6909 mint (`unspecified.take`), no `HookFee` emit, and no swap-delta
/// return. Stripping that plumbing lets the handler observe the RAW
/// unspecified-side balance-delta the pool computed (unadjusted by hook
/// return-delta), which is the input the reference `expectedFees` ledger
/// needs to be a same-currency same-magnitude comparison.
///
/// The fee-arithmetic block below is a character-for-character copy of the
/// vendored base's `_afterSwap` lines 155-174 (the post-`2678eb9` arithmetic).
/// The single difference against the planted twin is confined to that block
/// (lines marked `TWIN-DIFF`); everything else in this file, and every byte
/// of the vendored base's fee-arithmetic, is identical across twins.
///
/// Configuration: the target unspecified amount is fixed at 0 with
/// `applyTarget = true`. Under OZ's post-fix arithmetic that reduces to:
///   - exactInput: `feeAmount = unspec - 0 = unspec` (the swap's absolute
///     output magnitude is recorded as a fee to the output currency).
///   - exactOutput: `unspec < 0` is false, so `feeAmount = 0` (no accrual).
/// A production dynamic-fee hook would compute a non-zero target in
/// `_getTargetUnspecified`; the trivial target=0 is a teaching-scale choice
/// that makes the direction-blind pre-fix bug fire visibly on the planted
/// twin's first exactOutput swap.
///
/// The accounting identity the case suite asserts as its primary invariant:
///
///   p2_dynamicfee_direction_integrity:
///     hook.accruedProtocolFees(c) == handler.expectedFees(c)
///
/// where `handler.expectedFees(c)` is computed with the same post-`2678eb9`
/// fee-arithmetic and the same target=0 configuration.
contract DemoDynamicAfterFeeHook is BaseDynamicAfterFee {
    using SafeCast for *;

    /// Bookkeeping ledger of fees this hook has accrued per currency
    /// across all observed swaps. Written from `_afterSwap` (this twin's
    /// override), which runs the byte-faithful post-`2678eb9` fee
    /// arithmetic.
    mapping(Currency => uint256) public accruedProtocolFees;

    /// Cumulative absolute unspecified-side amount observed per currency
    /// across all swaps where a non-zero fee was accrued. Bounds the
    /// solvency invariant.
    mapping(Currency => uint256) public cumulativeUnspecifiedAmount;

    constructor(IPoolManager _poolManager) BaseDynamicAfterFee(_poolManager) {}

    /// Trivial target strategy: zero target on every swap, apply=true. See
    /// contract-level docstring for the resulting behavior under OZ's
    /// post-fix arithmetic.
    function _getTargetUnspecified(
        address,
        PoolKey calldata,
        SwapParams calldata,
        bytes calldata
    ) internal pure override returns (uint256 targetUnspecifiedAmount, bool applyTarget) {
        return (0, true);
    }

    /// Unused (this twin overrides `_afterSwap` directly), but required by
    /// the vendored abstract base. A no-op that is never called on this
    /// twin's execution path.
    function _afterSwapHandler(
        PoolKey calldata,
        SwapParams calldata,
        BalanceDelta,
        uint256,
        uint256
    ) internal pure override {}

    /// TWIN-DIFF BLOCK: post-`2678eb9` fee-arithmetic (the audited fix).
    /// The lines between `---- CLEAN twin-diff BEGIN` and `---- CLEAN
    /// twin-diff END` below are a byte-for-byte copy of the vendored base's
    /// `_afterSwap` arithmetic block (lines 155-174 of
    /// `../vendor/oz-uniswap-hooks-v1.1.0/BaseDynamicAfterFee.sol`, itself
    /// character-for-character from OZ v1.1.0 tag / commit `2678eb9`). The
    /// planted twin overrides `_afterSwap` with the pre-`2678eb9` arithmetic
    /// block in this exact same span; every other byte of this file is
    /// identical across twins.
    ///
    /// The take/emit/return-delta plumbing from the vendored base is
    /// intentionally omitted on this teaching-scale hook so the swap-delta
    /// the handler observes is the raw pool-computed delta (not adjusted by
    /// a hook return-delta), which is what makes the same-currency
    /// same-magnitude invariant comparison possible.
    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        uint256 targetUnspecifiedAmount = _transientTargetUnspecifiedAmount();
        _setTransientTargetUnspecifiedAmount(0);

        if (!_transientApplyTarget()) {
            return (IHooks.afterSwap.selector, 0);
        }

        _setTransientApplyTarget(false);

        // Currency selection: unchanged context across `2678eb9`.
        (Currency unspecified, int128 unspecifiedAmount) = (params.amountSpecified < 0 == params.zeroForOne)
            ? (key.currency1, delta.amount1())
            : (key.currency0, delta.amount0());

        // Get the absolute unspecified amount
        if (unspecifiedAmount < 0) unspecifiedAmount = -unspecifiedAmount;

        // ---- CLEAN twin-diff BEGIN (post-`2678eb9` fee-arithmetic; byte-copy) ----
        // Get the exact input flag
        bool exactInput = params.amountSpecified < 0;

        uint256 feeAmount;

        // If the swap is exactInput, any fee should be decreased from the swap output
        if (exactInput) {
            // If the swap output exceeds the target, decrease it by the difference as a hook fee
            if (unspecifiedAmount.toUint256() > targetUnspecifiedAmount) {
                feeAmount = unspecifiedAmount.toUint256() - targetUnspecifiedAmount;
            }
            // If the swap output is less or equal than the target, behave as a no-op
        }
        // If the swap is exactOutput, any fee should be increased to the swap input
        else {
            // If the swap input is less than the target, increase it by the difference as a hook fee
            if (unspecifiedAmount.toUint256() < targetUnspecifiedAmount) {
                feeAmount = targetUnspecifiedAmount - unspecifiedAmount.toUint256();
            }
            // If the swap input is greater or equal than the target, behave as a no-op
        }
        // ---- CLEAN twin-diff END --------------------------------------------------

        if (feeAmount > 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 absAmount = uint256(uint128(unspecifiedAmount));
            accruedProtocolFees[unspecified] += feeAmount;
            cumulativeUnspecifiedAmount[unspecified] += absAmount;
        }

        return (IHooks.afterSwap.selector, 0);
    }
}
