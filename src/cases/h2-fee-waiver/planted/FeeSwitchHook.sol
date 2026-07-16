// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/// @title FeeSwitchHook (case C-H2: fee waiver via hookData)
/// @notice afterSwap hook that accrues a hook fee into an internal
/// ledger on every swap unless the swap is waived. The bug class lives
/// in WHERE the waiver decision comes from: the admin-set allowlist
/// keyed by `sender` (the router contract calling PoolManager.swap),
/// or swapper-controlled hookData. The clean and planted twins are
/// byte-identical except the `_isWaived` hunk; the case README shows
/// the diff.
///
/// Fee sizing: the swap's SPECIFIED amount, `|params.amountSpecified|`
/// (for exact-input swaps the specified amount is
/// `-params.amountSpecified`). Sizing on the specified amount rather
/// than the realized delta keeps the test-side expected-fee ledger
/// exact and path-independent under concentrated liquidity; the ledger
/// is denominated in raw units of each swap's specified currency
/// (teaching-scale simplification, documented in the case README).
contract FeeSwitchHook {
    /// Hook fee in basis points of the specified amount (30 = 0.30%).
    uint256 public constant FEE_BPS = 30;

    IPoolManager public immutable manager;

    /// Admin who controls the waiver allowlist. Set at construction.
    address public immutable admin;

    /// Admin-set waiver allowlist, keyed by the address the real
    /// PoolManager forwards as `sender`: the router contract that
    /// called PoolManager.swap, i.e. an authenticated identity, unlike
    /// hookData which is arbitrary swapper input.
    mapping(address => bool) public feeExempt;

    /// Running total of accrued hook fees across all senders, in raw
    /// units of each swap's specified currency.
    uint256 public accruedFees;

    /// Per-sender accrual, so tests can assert whether an individual
    /// swapper's fee was charged.
    mapping(address => uint256) public feesBy;

    event ExemptUpdated(address indexed sender, bool exempt);
    event FeeAccrued(address indexed sender, uint256 specifiedAmount, uint256 fee);

    error NotAdmin();
    error NotManager();
    error ZeroAdmin();

    constructor(IPoolManager manager_, address admin_) {
        if (admin_ == address(0)) revert ZeroAdmin();
        manager = manager_;
        admin = admin_;
        // Self-check: the deployment address must encode exactly this
        // hook's permission bitmap (afterSwap only) in its low 14 bits,
        // or the real PoolManager would never dispatch to it.
        Hooks.validateHookPermissions(
            IHooks(address(this)),
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: false,
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

    function setFeeExempt(address sender, bool exempt) external {
        if (msg.sender != admin) revert NotAdmin();
        feeExempt[sender] = exempt;
        emit ExemptUpdated(sender, exempt);
    }

    /// Waiver policy (PLANTED BUG, the single-hunk twin diff): the
    /// waiver is ALSO honored from swapper-supplied hookData, on top of
    /// the admin allowlist. Any unprivileged swapper zeroes their own
    /// fee by passing hookData whose first byte is 0x01.
    function _isWaived(address sender, bytes calldata hookData) internal view returns (bool) {
        return feeExempt[sender] || (hookData.length > 0 && hookData[0] == 0x01);
    }

    function afterSwap(
        address sender,
        PoolKey calldata,
        SwapParams calldata params,
        BalanceDelta,
        bytes calldata hookData
    ) external returns (bytes4, int128) {
        if (msg.sender != address(manager)) revert NotManager();
        if (!_isWaived(sender, hookData)) {
            // Specified amount: negative for exact-input, positive for
            // exact-output; the fee is sized on its absolute value.
            uint256 specified = params.amountSpecified < 0
                ? uint256(-params.amountSpecified)
                : uint256(params.amountSpecified);
            uint256 fee = (specified * FEE_BPS) / 10_000;
            accruedFees += fee;
            feesBy[sender] += fee;
            emit FeeAccrued(sender, specified, fee);
        }
        // The manager reverts on a wrong selector return; the int128 is
        // the hook's unspecified-currency delta, unused by this hook.
        return (IHooks.afterSwap.selector, 0);
    }
}
