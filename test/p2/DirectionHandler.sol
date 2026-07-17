// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {StdUtils} from "forge-std/StdUtils.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {InvariantRouter} from "../../src/routers/InvariantRouter.sol";
import {TestERC20} from "../base/TestERC20.sol";

/// C-P2 fuzz handler: walks a shared pool through a mixed
/// `(direction x exact-side)` swap sequence and maintains a reference
/// `expectedFees[c]` ledger the case invariant compares the hook's
/// `accruedProtocolFees(c)` ledger against.
///
/// All four `(zeroForOne, exactInput)` combinations are exercised via a
/// mode seed. The reference ledger is computed via the SAME direction-
/// aware fee ARITHMETIC encoded in OpenZeppelin's post-`2678eb9`
/// `BaseDynamicAfterFee._afterSwap` (branch on `exactInput`; compute
/// `feeAmount = unspec - target` on exactInput and
/// `feeAmount = target - unspec` on exactOutput). Under this case's
/// trivial `_getTargetUnspecified = 0` strategy, that reduces to:
/// `feeAmount = unspec` on exactInput; `feeAmount = 0` on exactOutput.
/// The clean twin matches this ledger by construction (it runs OZ's
/// audited fixed `_afterSwap` unchanged). The planted twin diverges on
/// every exactOutput swap: the pre-`2678eb9` arithmetic branch computes
/// `feeAmount = unspec - target = unspec` unconditionally, so its
/// accrued ledger records the full unspecified magnitude while this
/// reference records 0.
///
/// Bounds (chosen so no fuzzed call can revert on the clean twin;
/// `fail_on_revert = true`):
/// - swap amount in `[MIN_SWAP, MAX_SWAP]` = `[1e12, 1e15]`. Worst-case
///   one-directional volume across 12,800 handler calls is well below
///   the seeded liquidity's single-side capacity, so no swap can exit
///   the range or hit the sqrt-price limit. Bound tightened from the
///   pre-vendor version (was 1e17) because the clean twin's 100%-fee
///   configuration on exactInput swaps means the caller pays FULL input
///   and receives ZERO output; the router must be pre-funded and
///   pre-approved for the input side and the pool must have enough
///   liquidity to complete every swap without hitting the sqrt-price
///   limit under repeated one-directional volume.
/// - handler is funded with 1e24 of each currency at setup; the router
///   approval is `type(uint256).max`, which covers both the exactInput
///   settlement AND the extra input the planted twin's pre-fix `take()`
///   forces the router to settle on exactOutput swaps.
contract DirectionHandler is StdUtils {
    int24 internal constant TICK_LOWER = -600;
    int24 internal constant TICK_UPPER = 600;

    uint256 internal constant MIN_SWAP = 1e12;
    uint256 internal constant MAX_SWAP = 1e15;

    IPoolManager public immutable manager;
    TestERC20 public immutable token0;
    TestERC20 public immutable token1;

    InvariantRouter public router;
    PoolKey public key;
    Currency public currency0;
    Currency public currency1;

    /// Reference ledger: post-fix (direction-aware) fee accrual per
    /// currency, computed with OZ's post-`2678eb9` arithmetic and the
    /// hook's `_getTargetUnspecified = 0` configuration. Both twins are
    /// checked against this same ledger; the clean twin holds by
    /// construction, the planted twin diverges on exactOutput swaps.
    mapping(Currency => uint256) public expectedFees;

    /// Cumulative absolute unspecified-side amount observed per currency,
    /// mirroring the hook's own `cumulativeUnspecifiedAmount` ledger for
    /// the solvency check. Only advanced on swaps where the post-fix
    /// arithmetic would have accrued a non-zero fee (matching the
    /// vendored `_afterSwapHandler` call-guard `feeAmount > 0`).
    mapping(Currency => uint256) public expectedCumulativeUnspecifiedAmount;

    /// Observability for scorecards.
    uint256 public swapCount;
    uint256 public exactOutputSwapCount;

    bool internal initialized;

    error AlreadyInitialized();

    constructor(IPoolManager manager_, TestERC20 token0_, TestERC20 token1_) {
        manager = manager_;
        token0 = token0_;
        token1 = token1_;
    }

    /// One-time wiring by the suite: stands up this handler's own
    /// router (so `sender` on every hook callback is this handler's
    /// router, matching the invariant's "handler drives the walk"
    /// framing) and records the pool identity for later use.
    function init(PoolKey memory key_) external {
        if (initialized) revert AlreadyInitialized();
        initialized = true;
        key = key_;
        currency0 = key_.currency0;
        currency1 = key_.currency1;
        router = new InvariantRouter(manager);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
    }

    // ------------------------- fuzz actions --------------------------

    /// Mixed-direction, mixed-exact-side swap. The mode seed selects one
    /// of the four `(zeroForOne, exactInput)` combinations; all four
    /// must be exercised for the invariant to catch the planted twin
    /// (the divergence only fires on exactOutput swaps).
    function swap(uint256 amountSeed, uint256 modeSeed) external {
        uint256 amount = _bound(amountSeed, MIN_SWAP, MAX_SWAP);
        uint256 mode = _bound(modeSeed, 0, 3);
        // mode: 0 = zeroForOne exactInput; 1 = zeroForOne exactOutput
        //       2 = oneForZero exactInput; 3 = oneForZero exactOutput
        bool zeroForOne = mode < 2;
        bool exactInput = (mode & 1) == 0;

        // exactInput encoded as negative amount, exactOutput as positive
        // per v4 convention. `amount` is bounded to 1e15 so both casts
        // are lossless.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 amountSpecified = exactInput ? -int256(amount) : int256(amount);

        BalanceDelta delta = router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        // Reference ledger update, mirroring the vendored post-fix
        // arithmetic block in `BaseDynamicAfterFee._afterSwap`:
        //   unspec_currency = (amountSpecified<0 == zeroForOne) ? c1 : c0
        //   |unspec| = |delta.amount(unspec_side)|
        //   target = 0 (this case's `_getTargetUnspecified`)
        //   feeAmount = exactInput
        //     ? (|unspec| > target ? |unspec| - target : 0)
        //     : (|unspec| < target ? target - |unspec| : 0)
        // Under target = 0 this reduces to:
        //   exactInput  -> feeAmount = |unspec|
        //   exactOutput -> feeAmount = 0
        (Currency unspecified, int128 unspecifiedAmount) = (exactInput == zeroForOne)
            ? (key.currency1, delta.amount1())
            : (key.currency0, delta.amount0());
        if (unspecifiedAmount < 0) unspecifiedAmount = -unspecifiedAmount;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 absAmount = uint256(uint128(unspecifiedAmount));
        uint256 feeAmount = exactInput ? absAmount : 0;

        if (feeAmount > 0) {
            // Vendored `_afterSwapHandler` is call-guarded by
            // `feeAmount > 0`; mirror that guard here so the cumulative
            // ledger matches the hook's on both twins.
            expectedFees[unspecified] += feeAmount;
            expectedCumulativeUnspecifiedAmount[unspecified] += absAmount;
        }

        swapCount++;
        if (!exactInput) exactOutputSwapCount++;
    }
}
