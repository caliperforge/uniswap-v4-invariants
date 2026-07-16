// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {BaseDynamicAfterFee} from "../vendor/oz-uniswap-hooks-v1.1.0/BaseDynamicAfterFee.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/// @title DemoDynamicAfterFeeHook (case C-P2 PLANTED twin: fee-direction integrity)
/// @notice Same subclass shape as the clean twin, byte-identical everywhere
/// EXCEPT the fee-arithmetic block inside `_afterSwap`. The clean twin's
/// block is a byte-copy of OZ's post-`2678eb9` fix (the exactInput branch);
/// this planted twin's block is a byte-copy of the pre-`2678eb9` code that
/// OZ RC-2 finding M-01 named ("Incorrect Fee Application When
/// `unspecifiedAmount` Represents Input Instead of Output"). The pre-fix
/// arithmetic computes `feeAmount = uint128(unspec) - targetOutput`
/// unconditionally (no `exactInput` branch), and reverts with
/// `TargetOutputExceeds()` when the target exceeds the swap's unspecified
/// amount. The currency-selection expression above the arithmetic block is
/// unchanged context across `2678eb9`: the pre-fix code selected the
/// correct unspecified currency; the audited bug is entirely in the fee
/// arithmetic, not in the currency-selection line.
///
/// Under this case's target=0 configuration:
///   - CLEAN exactInput:  fee = unspec (branch matches pre-fix). Twins agree.
///   - CLEAN exactOutput: fee = 0     (exactOutput branch skipped when
///                                     unspec >= target=0).
///   - PLANTED exactInput:  fee = unspec (matches CLEAN by coincidence).
///   - PLANTED exactOutput: fee = unspec (bug: charged as if
///                                        `unspec` were the output).
/// The first fuzzed exactOutput swap diverges the two accrued ledgers and
/// fires `INVARIANT VIOLATED p2_dynamicfee_direction_integrity`.
contract DemoDynamicAfterFeeHook is BaseDynamicAfterFee {
    /// Bookkeeping ledger of fees this hook has accrued per currency
    /// across all observed swaps. Written from `_afterSwap` (this twin's
    /// override), which runs the pre-`2678eb9` fee arithmetic.
    mapping(Currency => uint256) public accruedProtocolFees;

    /// Cumulative absolute unspecified-side amount observed per currency
    /// across all swaps where a non-zero fee was accrued. Bounds the
    /// solvency invariant.
    mapping(Currency => uint256) public cumulativeUnspecifiedAmount;

    /// The pre-`2678eb9` revert shape. Preserved on this planted twin
    /// because it is part of the audited pre-fix arithmetic; the audited
    /// post-fix code (running on the clean twin) removed it in favor of an
    /// `exactInput`-branched no-op-when-below-target flow. Under target=0
    /// this specific revert never fires (0 is never greater than the
    /// unspec magnitude), but the line is retained so a reviewer sees the
    /// full pre-fix arithmetic byte-copied.
    error TargetOutputExceeds();

    constructor(IPoolManager _poolManager) BaseDynamicAfterFee(_poolManager) {}

    function _getTargetUnspecified(
        address,
        PoolKey calldata,
        SwapParams calldata,
        bytes calldata
    ) internal pure override returns (uint256 targetUnspecifiedAmount, bool applyTarget) {
        return (0, true);
    }

    function _afterSwapHandler(
        PoolKey calldata,
        SwapParams calldata,
        BalanceDelta,
        uint256,
        uint256
    ) internal pure override {}

    /// TWIN-DIFF BLOCK: pre-`2678eb9` fee-arithmetic (the audited M-01 bug).
    /// The lines between `---- PLANTED twin-diff BEGIN` and `---- PLANTED
    /// twin-diff END` below are a byte-for-byte copy of the pre-`2678eb9`
    /// arithmetic reported in OZ's Uniswap Hooks v1.1.0 RC 2 audit as
    /// finding M-01. The clean twin overrides `_afterSwap` with the
    /// post-`2678eb9` arithmetic block in this exact same span; every other
    /// byte of this file is identical to the clean twin.
    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        uint256 targetOutput = _transientTargetUnspecifiedAmount();
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

        // ---- PLANTED twin-diff BEGIN (pre-`2678eb9` fee-arithmetic; M-01 bug) ----
        // Revert if the target output exceeds the swap amount
        // forge-lint: disable-next-line(unsafe-typecast)
        if (targetOutput > uint128(unspecifiedAmount)) revert TargetOutputExceeds();

        // Calculate the fee amount, which is the difference between the
        // swap amount and the target output. NOTE: this arithmetic assumes
        // `unspecifiedAmount` always represents OUTPUT, so on exactOutput
        // swaps (where `unspecifiedAmount` is INPUT) the fee is computed
        // with the wrong sign convention: `unspec - target` where post-fix
        // would compute `target - unspec`.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 feeAmount = uint128(unspecifiedAmount) - targetOutput;
        // ---- PLANTED twin-diff END ------------------------------------------------

        if (feeAmount > 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 absAmount = uint256(uint128(unspecifiedAmount));
            accruedProtocolFees[unspecified] += feeAmount;
            cumulativeUnspecifiedAmount[unspecified] += absAmount;
        }

        return (IHooks.afterSwap.selector, 0);
    }
}
