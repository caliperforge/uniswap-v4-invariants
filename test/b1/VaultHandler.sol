// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {StdUtils} from "forge-std/StdUtils.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {InvariantRouter} from "../../src/routers/InvariantRouter.sol";
import {LiquidityVaultHook} from "../../src/cases/b1-custom-accounting/clean/LiquidityVaultHook.sol";
import {TestERC20} from "../base/TestERC20.sol";

/// C-B1 fuzz handler: walks the vault through deposit/withdraw/swap
/// sequences against the real PoolManager. The handler is the vault
/// admin (resolves the wiring circularity without pranks, per the H2
/// pattern) and the sole depositor; the case invariants are aggregate
/// accounting identities, so a single depositor identity is sufficient
/// and keeps fail_on_revert sound.
///
/// Bounds (all chosen so no fuzzed call can revert on the clean twin;
/// fail_on_revert = true):
/// - deposit in [1e6, 1e18]: the floor keeps minted shares nonzero even
///   when nav per share drifts above 1 (nav/shares stays well under 2
///   because the spot-derived MIN estimate can discount at most the
///   active tranche, roughly half of trackedTotal).
/// - withdraw shares in [1, 90% of totalShares]: a full exit priced at
///   a spot-discounted MIN estimate could orphan the undiscounted
///   residue of the split with zero shares outstanding, making the
///   next MIN_DEPOSIT-sized deposit unpriceable; below 10 shares the
///   cap equals the total and the orphanable residue is a few wei.
/// - swap in [1e12, 1e17], either direction: worst-case one-directional
///   volume at depth 50 is 5e18 against roughly 30e18 single-side
///   capacity of the +-600-tick band seeded by the test base, so no
///   fuzzed swap can exit the range or hit the price limit (H2-proven
///   numbers, same pool shape).
contract VaultHandler is StdUtils {
    uint256 internal constant MIN_DEPOSIT = 1e6;
    uint256 internal constant MAX_DEPOSIT = 1e18;
    uint256 internal constant MIN_SWAP = 1e12;
    uint256 internal constant MAX_SWAP = 1e17;

    IPoolManager public immutable manager;
    TestERC20 public immutable token0;
    TestERC20 public immutable token1;

    LiquidityVaultHook public hook;
    InvariantRouter public router;
    PoolKey public key;
    bool internal initialized;

    error AlreadyInitialized();

    constructor(IPoolManager manager_, TestERC20 token0_, TestERC20 token1_) {
        manager = manager_;
        token0 = token0_;
        token1 = token1_;
    }

    /// One-time wiring by the test suite: registers the pool with the
    /// vault (handler is admin), stands up this handler's router actor,
    /// and grants the approvals the deposit and swap paths need.
    function init(PoolKey memory key_, LiquidityVaultHook hook_) external {
        if (initialized) revert AlreadyInitialized();
        initialized = true;
        key = key_;
        hook = hook_;
        hook.setPool(key_);
        router = new InvariantRouter(manager);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        token0.approve(address(hook), type(uint256).max);
    }

    // ------------------------- fuzz actions --------------------------

    function deposit(uint256 assets) public {
        assets = _bound(assets, MIN_DEPOSIT, MAX_DEPOSIT);
        hook.deposit(assets);
    }

    function withdraw(uint256 shares) public {
        uint256 total = hook.sharesOf(address(this));
        if (total == 0) {
            // Nothing to redeem yet: seed the vault instead so the walk
            // stays productive under fail_on_revert.
            hook.deposit(MIN_DEPOSIT);
            return;
        }
        // Cap redemptions at 90% of outstanding shares. A full exit
        // priced at a spot-discounted MIN estimate would orphan the
        // undiscounted residue of the balance split with zero shares
        // outstanding, inflating nav-per-share for the next depositor
        // far enough that a MIN_DEPOSIT-sized deposit mints zero shares
        // and reverts (a share-pricing edge outside this case's bug
        // class; fail_on_revert is on). Below 10 shares the cap equals
        // the total, and the residue a dust-scale full exit can orphan
        // is bounded by a few wei, which cannot distort share pricing.
        shares = _bound(shares, 1, total - total / 10);
        hook.withdraw(shares);
    }

    function swap(uint256 amount, bool zeroForOne) public {
        amount = _bound(amount, MIN_SWAP, MAX_SWAP);
        // amount is bounded to at most 1e17, so the cast is safe
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 specified = -int256(amount);
        router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: specified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
    }
}
