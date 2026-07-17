// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {StdUtils} from "forge-std/StdUtils.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {InvariantRouter} from "../../src/routers/InvariantRouter.sol";
import {LiquidityPenaltyHook} from "../../src/cases/p1-liquidity-penalty-conservation/clean/LiquidityPenaltyHook.sol";
import {TestERC20} from "../base/TestERC20.sol";

/// C-P1 fuzz handler: walks the single hook-owned full-range position
/// through add / swap / increase / remove sequences against the real
/// PoolManager. The handler owns the position (its address is the
/// `sender` v4-core reports to the hook, i.e. this handler is what the
/// position key is derived from) and drives its own router actor for
/// modifyLiquidity and swap calls.
///
/// Single-position teaching scale: the position spans the full usable
/// tick range at `tickSpacing = 60`, so it is always in-range for the
/// bounded swap sizes below; every swap fee flows to this position (the
/// pool has no other LP), which is what makes the case's fee-accrual
/// reference exact.
///
/// Bounds (chosen so no fuzzed call can revert on the clean twin;
/// fail_on_revert = true):
/// - initial liquidity: 1000e18 seeded at init, well above the maximum
///   worst-case one-directional swap volume so no swap can exit the range
///   or drive the position's remaining liquidity to zero.
/// - addLiquidity in [1e15, 1e17]: bounded so the pool always has room
///   for approvals and so the cumulative campaign does not overflow the
///   handler's minted balance across 12,800 handler calls per invariant.
/// - removeLiquidity in [1, 10% of current position liquidity]: leaves
///   at least ~90% in-range at all times so the next swap has liquidity
///   AND the next donate has in-range recipients.
/// - swap in [1e12, 1e17], zeroForOne only: single-direction keeps all
///   accrued fees on the token0 side, matching the hook's token0-only
///   donation path at teaching scale.
contract PenaltyHandler is StdUtils {
    // forge-std Vm precompile; used ONLY to call vm.roll for the
    // per-call block-number progression the case's timing depends on.
    // The handler is a plain contract (not a forge-std Test), so it
    // needs the precompile address directly.
    address internal constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
    Vm internal constant vm = Vm(VM_ADDRESS);

    int24 internal constant TICK_LOWER = -600;
    int24 internal constant TICK_UPPER = 600;
    int128 internal constant INITIAL_LIQUIDITY = 1_000e18;

    uint256 internal constant MIN_ADD = 1e15;
    uint256 internal constant MAX_ADD = 1e17;
    uint256 internal constant MIN_SWAP = 1e12;
    uint256 internal constant MAX_SWAP = 1e17;

    IPoolManager public immutable manager;
    TestERC20 public immutable token0;
    TestERC20 public immutable token1;

    LiquidityPenaltyHook public hook;
    InvariantRouter public router;
    PoolKey public key;

    uint256 public currentLiquidity;
    bool internal initialized;

    error AlreadyInitialized();

    constructor(IPoolManager manager_, TestERC20 token0_, TestERC20 token1_) {
        manager = manager_;
        token0 = token0_;
        token1 = token1_;
    }

    /// One-time wiring by the test suite: stands up this handler's own
    /// router (so `sender` in every hook callback is this handler's
    /// router, and the position's `owner` is this handler itself, i.e.
    /// the payer that authorized the router), and adds the initial
    /// full-range position at 1000e18 liquidity.
    function init(PoolKey memory key_, LiquidityPenaltyHook hook_) external {
        if (initialized) revert AlreadyInitialized();
        initialized = true;
        key = key_;
        hook = hook_;
        router = new InvariantRouter(manager);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);

        router.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: int256(uint256(uint128(INITIAL_LIQUIDITY))),
                salt: 0
            }),
            ""
        );
        // int128 constant fits int256 losslessly.
        // forge-lint: disable-next-line(unsafe-typecast)
        currentLiquidity = uint256(uint128(INITIAL_LIQUIDITY));
    }

    // ------------------------- fuzz actions --------------------------

    /// Add liquidity to the existing single position. v4-core auto-
    /// collects any fees the position has accrued since its last touch
    /// as part of this call; the hook's afterAddLiquidity callback
    /// captures those into the pending penalty base on the clean twin.
    function addLiquidity(uint256 amount) public {
        amount = _bound(amount, MIN_ADD, MAX_ADD);
        // amount <= 1e17 fits int256 and int128 losslessly.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 delta = int256(amount);
        router.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: delta,
                salt: 0
            }),
            ""
        );
        currentLiquidity += amount;
        // Advance the block so the campaign spans multiple penalty
        // windows; without this the whole walk lives at block.number 1
        // and dt is always 0, which the property still catches but which
        // trivializes the decay leg of the case.
        vm.roll(block.number + 1);
    }

    function removeLiquidity(uint256 amount) public {
        // Cap removes at 10% of current liquidity so the position never
        // empties: v4-core's donate requires nonzero in-range liquidity
        // and the position must remain the sole LP for the fee-accrual
        // reference to stay exact.
        uint256 cap = currentLiquidity / 10;
        if (cap == 0) cap = 1;
        amount = _bound(amount, 1, cap);
        // amount <= currentLiquidity <= (1e18 + 12800 * 1e17) fits int256 losslessly.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 delta = -int256(amount);
        router.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: delta,
                salt: 0
            }),
            ""
        );
        currentLiquidity -= amount;
        vm.roll(block.number + 1);
    }

    function swap(uint256 amount) public {
        amount = _bound(amount, MIN_SWAP, MAX_SWAP);
        // amount <= 1e17 fits int256 and int128 losslessly.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 specified = -int256(amount);
        router.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: specified,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        vm.roll(block.number + 1);
    }

    // --------------------- accessors for the case --------------------

    /// The position key the hook uses for this handler's sole position.
    /// The `owner` v4-core hashes into the position key is the msg.sender
    /// of `PoolManager.modifyLiquidity`, which is the router in this
    /// harness (the router calls the manager from its unlockCallback);
    /// v4-core's own `Hooks.afterModifyLiquidity` forwards that same
    /// address to the hook as the `sender` argument, so the hook and
    /// v4-core hash the same owner into their respective position keys.
    function positionKey() external view returns (bytes32) {
        return hook.positionKey(address(router), TICK_LOWER, TICK_UPPER, bytes32(0));
    }
}
