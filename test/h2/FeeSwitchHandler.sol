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
import {FeeSwitchHook} from "../../src/cases/h2-fee-waiver/clean/FeeSwitchHook.sol";

/// @title FeeSwitchHandler (C-H2 invariant handler)
/// @notice Fuzz surface for the fee-waiver case. Owns three real
/// InvariantRouter actors (each a distinct `sender` identity as the
/// hook sees it) and mirrors the CLEAN waiver semantics in an
/// independent expected-fee ledger:
///
///     expectedFees extends by amount * FEE_BPS / 10_000 for every
///     swap whose router is NOT on the admin allowlist, regardless of
///     hookData.
///
/// Deterministic by construction: the ledger depends only on the
/// specified amount and the allowlist state, never on pool price or
/// liquidity path (fee sizing on the SPECIFIED amount is a build-spec
/// decision, spec section 3). On the planted twin, a fuzzed swap that
/// claims the hookData waiver from a non-allowlisted router zeroes the
/// hook-side fee while this ledger still extends: divergence, caught
/// by the invariant.
///
/// The handler is also the hook's ADMIN, so the fuzz walk can exercise
/// allowlist churn through setExempt without pranking.
contract FeeSwitchHandler is StdUtils {
    /// Mirrors FeeSwitchHook.FEE_BPS. Deliberately a local constant:
    /// the expected ledger is computed independently of the hook.
    uint256 internal constant FEE_BPS = 30;

    /// Max exact-input per fuzzed swap. Worst case one-directional
    /// volume (50-deep run) is 50 * 1e17 = 5e18, well inside the
    /// roughly 30e18 single-side capacity of the seeded liquidity
    /// range, so no swap ever exits the range or hits the price limit
    /// (fail_on_revert stays sound).
    uint256 internal constant MAX_SWAP = 1e17;

    /// First-byte waiver magic the planted twin honors from hookData.
    bytes1 internal constant WAIVER_BYTE = 0x01;

    IPoolManager public immutable manager;
    TestERC20 public immutable token0;
    TestERC20 public immutable token1;

    InvariantRouter[3] public routers;
    FeeSwitchHook public hook;
    PoolKey internal poolKey;
    bool internal inited;

    /// Test-side mirror of the admin allowlist (clean semantics).
    mapping(address => bool) public exemptModel;

    /// The expected-fee ledger the invariant compares against.
    uint256 public expectedFees;

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

    /// One-time wiring. The hook takes this handler's address as admin
    /// at construction, so pool key and hook can only arrive after both
    /// exist. NOT a fuzz target: the suite restricts the fuzzed
    /// selectors to swap and setExempt via targetSelector.
    function init(PoolKey calldata key, FeeSwitchHook hook_) external {
        require(!inited, "FeeSwitchHandler: already inited");
        inited = true;
        poolKey = key;
        hook = hook_;
    }

    // ---- fuzzed actions (the ONLY selectors the suites target) ----

    /// Exact-input swap from a fuzz-chosen router actor, optionally
    /// claiming the hookData waiver.
    function swap(uint256 actorSeed, uint256 amountSeed, bool claimWaiver, bool zeroForOne) external {
        InvariantRouter r = routers[_bound(actorSeed, 0, routers.length - 1)];
        uint256 amount = _bound(amountSeed, 1, MAX_SWAP);
        bytes memory hookData = claimWaiver ? abi.encodePacked(WAIVER_BYTE) : bytes("");

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

        // CLEAN semantics, applied unconditionally of hookData: only
        // the admin allowlist waives the fee.
        if (!exemptModel[address(r)]) {
            expectedFees += (amount * FEE_BPS) / 10_000;
        }
    }

    /// Allowlist churn through the legitimate admin path, mirrored in
    /// the model so the expected ledger tracks it exactly.
    function setExempt(uint256 actorSeed, bool exempt) external {
        InvariantRouter r = routers[_bound(actorSeed, 0, routers.length - 1)];
        hook.setFeeExempt(address(r), exempt);
        exemptModel[address(r)] = exempt;
    }
}
