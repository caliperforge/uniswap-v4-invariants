// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {StdUtils} from "forge-std/StdUtils.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {InvariantRouter} from "../../src/routers/InvariantRouter.sol";
import {TestERC20} from "../base/TestERC20.sol";
// The clean twin is imported as the canonical ABI type; both twins
// share an identical external surface, so the planted suite casts its
// planted deployment (placed via deployCodeTo) to this same type.
import {RewardsHook} from "../../src/cases/h1-hookdata-identity/clean/RewardsHook.sol";

/// @title RewardsHandler (C-H1 invariant handler)
/// @notice Fuzz surface for the recipient-identity case. Owns three
/// real InvariantRouter actors (each a distinct `sender` identity as
/// the hook sees it) and mirrors the CLEAN recipient semantics in an
/// independent per-router swap ledger:
///
///     swapsByRouter[R] extends by 1 for every swap performed through
///     router R, regardless of hookData.
///
/// Deterministic by construction: the ledger depends only on which
/// router performed the swap, never on pool price, liquidity path, or
/// hookData content. On the planted twin, a fuzzed swap whose hookData
/// names a different address as recipient credits the hook-side ledger
/// under the wrong identity while this ledger still extends under the
/// performing router: divergence, caught by the invariant.
contract RewardsHandler is StdUtils {
    uint256 public constant ROUTER_COUNT = 3;

    /// Max exact-input per fuzzed swap. Worst case one-directional
    /// volume (50-deep run) is 50 * 1e17 = 5e18, well inside the
    /// roughly 30e18 single-side capacity of the seeded liquidity
    /// range, so no swap ever exits the range or hits the price limit
    /// (fail_on_revert stays sound).
    uint256 internal constant MAX_SWAP = 1e17;

    IPoolManager public immutable manager;
    TestERC20 public immutable token0;
    TestERC20 public immutable token1;

    InvariantRouter[ROUTER_COUNT] public routers;
    RewardsHook public hook;
    PoolKey internal poolKey;
    bool internal inited;

    /// The expected per-router swap ledger the invariant compares
    /// against (clean recipient semantics: credit follows the router
    /// that performed the swap).
    mapping(address => uint256) public swapsByRouter;

    /// Observability for scorecards.
    uint256 public swapCount;
    uint256 public otherRecipientNamedCount;

    constructor(IPoolManager manager_, TestERC20 t0, TestERC20 t1) {
        manager = manager_;
        token0 = t0;
        token1 = t1;
        for (uint256 i = 0; i < ROUTER_COUNT; i++) {
            routers[i] = new InvariantRouter(manager_);
            t0.approve(address(routers[i]), type(uint256).max);
            t1.approve(address(routers[i]), type(uint256).max);
        }
    }

    /// One-time wiring. NOT a fuzz target: the suite restricts the
    /// fuzzed selectors to swap via targetSelector.
    function init(PoolKey calldata key, RewardsHook hook_) external {
        require(!inited, "RewardsHandler: already inited");
        inited = true;
        poolKey = key;
        hook = hook_;
    }

    // ---- fuzzed action (the ONLY selector the suites target) ----

    /// Exact-input swap from a fuzz-chosen router actor. hookDataMode
    /// (bounded 0..2) picks what the swapper puts in hookData:
    ///   0: empty bytes
    ///   1: an ABI-encoded address naming the performing router itself
    ///   2: an ABI-encoded address naming a DIFFERENT router actor
    /// All three are legitimate swapper inputs; the hook specification
    /// says none of them may move the reward credit off `sender`.
    function swap(uint256 actorSeed, uint256 amountSeed, uint256 hookDataMode, bool zeroForOne) external {
        uint256 actor = _bound(actorSeed, 0, ROUTER_COUNT - 1);
        InvariantRouter r = routers[actor];
        uint256 amount = _bound(amountSeed, 1, MAX_SWAP);
        uint256 mode = _bound(hookDataMode, 0, 2);

        bytes memory hookData;
        if (mode == 1) {
            hookData = abi.encode(address(r));
        } else if (mode == 2) {
            hookData = abi.encode(address(routers[(actor + 1) % ROUTER_COUNT]));
            otherRecipientNamedCount++;
        }

        r.swap(
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
        );

        // CLEAN semantics, applied unconditionally of hookData: the
        // credit belongs to the router that performed the swap.
        swapsByRouter[address(r)] += 1;
        swapCount++;
    }
}
