// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";

/// @title FlashHook (case C-H3: settle protocol on the flash-accounting surface)
/// @notice beforeSwap hook that pays a fixed bonus of currency0 to the
/// swap sender when the swapper opts in via hookData. Paying the bonus
/// means interacting with the PoolManager's flash-accounting protocol:
/// `take` moves currency out of the manager and books a negative delta
/// against this hook; the protocol requires that delta to be closed
/// before the unlock ends, via the settle dance
/// (`sync(currency)` then an ERC20 transfer to the manager, then
/// `settle()`). The bug class lives in whether the bonus path performs
/// the full dance. The clean and planted twins are byte-identical
/// except the `_payBonus` hunk; the case README shows the diff.
///
/// The hook pays bonuses from its OWN pre-funded currency0 balance
/// (funded in test setUp), so the clean bonus path moves real balances
/// and closes with a zero delta per the flash-accounting contract.
contract FlashHook {
    /// Fixed bonus per opted-in swap, in raw currency0 units.
    uint256 public constant BONUS = 1e15;

    /// First-byte hookData opt-in for the bonus path (continuity with
    /// the feasibility-spike fixture convention).
    bytes1 public constant BONUS_BYTE = 0xBB;

    IPoolManager public immutable manager;

    /// Running total of bonuses this hook has paid out.
    uint256 public bonusPaid;

    event BonusPaid(address indexed to, uint256 amount);

    error NotManager();
    error BonusTransferFailed();

    constructor(IPoolManager manager_) {
        manager = manager_;
        // Self-check: the deployment address must encode exactly this
        // hook's permission bitmap (beforeSwap only) in its low 14
        // bits, or the real PoolManager would never dispatch to it.
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

    /// The hook's own funding balance in the given currency, i.e. what
    /// it can pay bonuses from. Test surface for the funding
    /// precondition of the clean settle dance.
    function fundingBalance(Currency currency) external view returns (uint256) {
        return IERC20Minimal(Currency.unwrap(currency)).balanceOf(address(this));
    }

    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata, bytes calldata hookData)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (msg.sender != address(manager)) revert NotManager();
        if (hookData.length >= 1 && hookData[0] == BONUS_BYTE) {
            _payBonus(key.currency0, sender);
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// Bonus payout on the flash-accounting surface. `take` opens a
    /// -BONUS delta against this hook; the flash-accounting contract
    /// requires that delta to be zero when the unlock ends.
    function _payBonus(Currency currency, address to) internal {
        // Open: the manager pays BONUS out to the swap sender and books
        // a -BONUS delta against this hook.
        manager.take(currency, to, BONUS);
        // Close: the settle dance the flash-accounting protocol
        // requires. sync snapshots the manager's currency balance, the
        // ERC20 transfer pays the debt from this hook's own funding,
        // settle books the payment and zeroes the delta.
        manager.sync(currency);
        if (!IERC20Minimal(Currency.unwrap(currency)).transfer(address(manager), BONUS)) {
            revert BonusTransferFailed();
        }
        manager.settle();
        bonusPaid += BONUS;
        emit BonusPaid(to, BONUS);
    }
}
