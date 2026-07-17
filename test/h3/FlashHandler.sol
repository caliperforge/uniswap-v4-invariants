// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {StdUtils} from "forge-std/StdUtils.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {InvariantRouter} from "../../src/routers/InvariantRouter.sol";
import {TestERC20} from "../base/TestERC20.sol";

/// @title FlashHandler (C-H3 invariant handler)
/// @notice Fuzz surface for the settle-protocol case. Owns three real
/// InvariantRouter actors and fuzzes exact-input swaps in both
/// directions, with and without the bonus opt-in byte in hookData.
///
/// Observable (build spec section 3): the manager's flash-accounting
/// delta state lives in transient storage and is not inspectable after
/// a revert, so the handler try/catches every router call and counts
/// reverts carrying the `IPoolManager.CurrencyNotSettled` selector.
/// A hook whose bonus path performs the full settle dance never trips
/// the guard, so the count stays zero; a hook that opens a delta and
/// never closes it trips the guard on the first opted-in swap.
///
/// Any OTHER revert is rethrown verbatim: it would mean the harness
/// itself is unsound (swap bounds exceeded, funding missing), and
/// `fail_on_revert = true` must fail the campaign loudly.
contract FlashHandler is StdUtils {
    /// Max exact-input per fuzzed swap. Worst case one-directional
    /// volume (50-deep run) is 50 * 1e17 = 5e18, well inside the
    /// roughly 30e18 single-side capacity of the seeded liquidity
    /// range, so no swap ever exits the range or hits the price limit.
    uint256 internal constant MAX_SWAP = 1e17;

    /// First-byte bonus opt-in the FlashHook twins honor from hookData.
    bytes1 internal constant BONUS_BYTE = 0xBB;

    IPoolManager public immutable manager;
    TestERC20 public immutable token0;
    TestERC20 public immutable token1;

    InvariantRouter[3] public routers;
    PoolKey internal poolKey;
    bool internal inited;

    /// The count the invariant compares against zero: reverts on the
    /// swap path carrying the CurrencyNotSettled selector.
    uint256 public settleGuardReverts;

    /// Observability for scorecards.
    uint256 public swapCount;
    uint256 public bonusSwapCount;

    constructor(IPoolManager manager_, TestERC20 t0, TestERC20 t1) {
        manager = manager_;
        token0 = t0;
        token1 = t1;
        for (uint256 i = 0; i < routers.length; i++) {
            routers[i] = new InvariantRouter(manager_);
            t0.approve(address(routers[i]), type(uint256).max);
            t1.approve(address(routers[i]), type(uint256).max);
        }
    }

    /// One-time wiring; NOT a fuzz target (the suite restricts the
    /// fuzzed selectors to swap via targetSelector).
    function init(PoolKey calldata key) external {
        require(!inited, "FlashHandler: already inited");
        inited = true;
        poolKey = key;
    }

    // ----- fuzzed action (the ONLY selector the suites target) -----

    /// Exact-input swap from a fuzz-chosen router actor, optionally
    /// opting into the hook's bonus path via hookData.
    function swap(uint256 actorSeed, uint256 amountSeed, bool requestBonus, bool zeroForOne) external {
        InvariantRouter r = routers[_bound(actorSeed, 0, routers.length - 1)];
        uint256 amount = _bound(amountSeed, 1, MAX_SWAP);
        bytes memory hookData = requestBonus ? abi.encodePacked(BONUS_BYTE) : bytes("");

        try r.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                // exact-input per v4 convention; amount is bounded to
                // MAX_SWAP (1e17) so the uint256 -> int256 cast is safe
                // forge-lint: disable-next-line(unsafe-typecast)
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            hookData
        ) returns (BalanceDelta) {
            swapCount++;
            if (requestBonus) bonusSwapCount++;
        } catch (bytes memory reason) {
            // length is checked to be exactly 4, so the bytes -> bytes4
            // cast cannot truncate meaningful data
            // forge-lint: disable-next-line(unsafe-typecast)
            if (reason.length == 4 && bytes4(reason) == IPoolManager.CurrencyNotSettled.selector) {
                settleGuardReverts++;
            } else {
                // Unexpected revert: rethrow verbatim so the campaign
                // fails loudly instead of miscounting.
                assembly ("memory-safe") {
                    revert(add(reason, 0x20), mload(reason))
                }
            }
        }
    }
}
