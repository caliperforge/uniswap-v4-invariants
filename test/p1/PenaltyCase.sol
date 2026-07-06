// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {V4TestBase} from "../base/V4TestBase.sol";
import {LiquidityPenaltyHook} from
    "../../src/cases/p1-liquidity-penalty-conservation/clean/LiquidityPenaltyHook.sol";
import {PenaltyHandler} from "./PenaltyHandler.sol";

/// C-P1 shared test surface. The clean and planted suites inherit this
/// contract unchanged and differ ONLY in which twin artifact they deploy,
/// so the property surface is provably identical across twins.
///
/// Property asserted (stateful invariant, 256 runs x depth 50 over
/// addLiquidity / removeLiquidity / swap handler walks):
///
///   p1_liquidity_penalty_conservation:
///     hook.penaltyDonated(P) == hook.expectedPenaltyDonated(P)
///
///     For the sole position P, the cumulative penalty amount actually
///     donated at removals must equal the cumulative penalty owed under
///     the hook's declared decay schedule applied to P's fee-accrual
///     lifetime (both twins maintain the reference expected ledger
///     identically, from the shared v4-core `feesAccrued` observations
///     on every callback). The clean twin holds by construction. The
///     planted twin's afterAddLiquidity omits capturing feesAccrued into
///     the pending penalty base; the first fuzzed sequence of
///     add -> swap -> addLiquidity -> remove that lands inside the
///     penalty window diverges the two ledgers and fires the marker.
///
/// Solvency invariant, held by both twins by construction (the hook
/// funds its donations from its own pre-funded balance; it never touches
/// LP principal): the pre-fund minus cumulative donated is what the hook
/// still holds. If the actual-penalty ledger ever exceeded the pre-fund
/// the hook could not settle a donate call, so this check keeps the
/// campaign honest about donation capacity.
///
///   p1_penalty_solvency:
///     hook.penaltyDonated(P) <= initialHookFunding
abstract contract PenaltyCase is V4TestBase {
    /// Pre-fund the hook so it can settle its penalty donations from its
    /// own balance without touching LP principal. Sized well above the
    /// campaign's cumulative fee accrual: bounded swap volume across
    /// 12,800 handler calls at 0.30% fee is roughly 4e18, and the hook
    /// only donates a decayed fraction of that.
    uint256 internal constant HOOK_FUNDING = 100e18;

    LiquidityPenaltyHook internal hook;
    PenaltyHandler internal handler;
    PoolKey internal key;

    /// Twin selection point: the ONLY difference between the clean and
    /// planted suites.
    function _hookArtifact() internal pure virtual returns (string memory);

    function setUp() public {
        deployV4Core();

        // Deploy the hook at an address whose low 14 bits encode exactly
        // AFTER_ADD_LIQUIDITY + AFTER_REMOVE_LIQUIDITY. deployCodeTo
        // runs the constructor AT that address, so the hook's own
        // Hooks.validateHookPermissions self-check passes.
        address hookAddr = deployHookTo(
            _hookArtifact(),
            abi.encode(address(manager), address(token0)),
            uint160(Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG),
            0xF1
        );
        hook = LiquidityPenaltyHook(hookAddr);

        // Pre-fund the hook's currency0 balance so its donate/settle
        // path has funds to draw on.
        token0.mint(address(hook), HOOK_FUNDING);

        // Initialize the pool at 1:1 WITHOUT the base's seed liquidity:
        // the case handler is the sole LP, so every swap fee flows to
        // the single position the invariant tracks.
        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });
        manager.initialize(key, SQRT_PRICE_1_1);

        // Handler owns the position (its router's address is the position
        // owner v4-core hashes into the position key, and the `sender`
        // v4-core passes to every hook callback).
        handler = new PenaltyHandler(IPoolManager(address(manager)), token0, token1);
        token0.mint(address(handler), 1_000_000e18);
        token1.mint(address(handler), 1_000_000e18);
        handler.init(key, hook);

        // Fuzz only the handler's three action selectors (init is not a
        // fuzz target; fail_on_revert is on).
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = PenaltyHandler.addLiquidity.selector;
        selectors[1] = PenaltyHandler.removeLiquidity.selector;
        selectors[2] = PenaltyHandler.swap.selector;
        targetSelector(StdInvariant.FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // ------------------------ invariant legs -------------------------

    function invariant_p1_penaltyConservation() public {
        bytes32 posKey = handler.positionKey();
        requireInvariant(
            hook.penaltyDonated(posKey) == hook.expectedPenaltyDonated(posKey), "p1_liquidity_penalty_conservation"
        );
    }

    function invariant_p1_solvency() public {
        bytes32 posKey = handler.positionKey();
        requireInvariant(hook.penaltyDonated(posKey) <= HOOK_FUNDING, "p1_penalty_solvency");
    }

    // ----------------------- regression leg --------------------------

    /// Deterministic regression sequence for the class this case
    /// encodes: add -> swap -> increase -> remove, all within one
    /// penalty window. On the clean twin the increase's afterAdd
    /// captures v4-core's reported feesAccrued into the pending penalty
    /// base, so the subsequent remove's penalty computation sees the
    /// full epoch's fees; on the planted twin the capture is omitted, so
    /// the remove's computed penalty is 0 while the reference expected
    /// stays positive, firing the marker.
    ///
    /// The sequence detects the seeded specification violation and stops
    /// at the invariant check; it computes no balance deltas for any
    /// party and prints no extraction figures.
    function test_regression_p1_conservationOnIncreaseThenRemove() public {
        bytes32 posKey = handler.positionKey();

        // Start of the regression epoch: mark the block. The handler's
        // init() already added an initial full-range position; that add
        // set lastAddBlock in the hook.
        uint256 addBlock = hook.lastAddBlock(posKey);
        assertEq(hook.pendingPenaltyBase(posKey), 0, "pending base should be zero at epoch start");
        assertEq(hook.feesSinceEpochStart(posKey), 0, "shared epoch total should be zero at epoch start");

        // Advance one block to keep everything inside the penalty
        // window (dt after the increase will be 1 block, well under
        // PENALTY_WINDOW = 10).
        vm.roll(addBlock + 1);

        // A swap accrues fees to the sole full-range position. All swap
        // fees flow to this position because it is the only LP.
        handler.swap(1e16);

        // Increase liquidity. v4-core auto-collects the position's
        // accrued fees on this call; the CLEAN afterAdd captures the
        // reported feesAccrued into pendingPenaltyBase, the PLANTED
        // afterAdd omits the capture. Both twins update the shared
        // epoch-total ledger (feesSinceEpochStart) identically.
        handler.addLiquidity(1e16);

        // Remove a small portion of the position. dt at this point is
        // ~2 blocks (well inside the 10-block penalty window), so the
        // CLEAN penalty is a decayed fraction of the captured epoch
        // fees, and the PLANTED penalty is 0.
        handler.removeLiquidity(1e14);

        // Property check. On the clean twin the two ledgers match; on
        // the planted twin the actual-penalty ledger is 0 and the
        // reference expected is the decayed epoch total, so the marker
        // fires.
        requireInvariant(
            hook.penaltyDonated(posKey) == hook.expectedPenaltyDonated(posKey), "p1_liquidity_penalty_conservation"
        );
    }

    // --------------------------- unit leg ----------------------------

    /// The hook is wired to the real pool: the initial add-event routed
    /// through PoolManager.modifyLiquidity reaches its afterAddLiquidity
    /// callback (set at construction time by handler.init()).
    function test_unit_hookObservesInitialAdd() public view {
        bytes32 posKey = handler.positionKey();
        assertGt(hook.lastAddBlock(posKey), 0, "afterAdd not observed on initial add");
    }

    /// A single add -> swap -> remove sequence outside an increase never
    /// triggers the twin diff: both twins observe the swap's fees on the
    /// remove's feesAccrued directly, so both compute the same penalty
    /// from the shared decay formula.
    function test_unit_singleAddSwapRemoveMatchesOnBothTwins() public {
        bytes32 posKey = handler.positionKey();
        uint256 startingBlock = hook.lastAddBlock(posKey);
        vm.roll(startingBlock + 1);
        handler.swap(1e16);
        handler.removeLiquidity(1e14);
        // Actual and expected match on both twins because the twin diff
        // lives in afterAddLiquidity and this sequence hits no add-event
        // between the initial add and the remove.
        assertEq(
            hook.penaltyDonated(posKey), hook.expectedPenaltyDonated(posKey), "single-epoch penalty should match"
        );
    }

    /// A removal outside the penalty window donates zero and expected is
    /// zero: dt >= PENALTY_WINDOW → decay(base, dt) = 0.
    function test_unit_removeOutsideWindowDonatesZero() public {
        bytes32 posKey = handler.positionKey();
        uint256 startingBlock = hook.lastAddBlock(posKey);
        handler.swap(1e16);
        // Roll past the 10-block penalty window; the remove that follows
        // is outside the window and pays zero penalty on both twins.
        vm.roll(startingBlock + hook.PENALTY_WINDOW() + 1);
        uint256 donatedBefore = hook.penaltyDonated(posKey);
        uint256 expectedBefore = hook.expectedPenaltyDonated(posKey);
        handler.removeLiquidity(1e14);
        assertEq(hook.penaltyDonated(posKey), donatedBefore, "actual outside window should not grow");
        assertEq(hook.expectedPenaltyDonated(posKey), expectedBefore, "expected outside window should not grow");
    }
}
