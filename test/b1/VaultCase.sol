// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {V4TestBase} from "../base/V4TestBase.sol";
import {LiquidityVaultHook} from "../../src/cases/b1-custom-accounting/clean/LiquidityVaultHook.sol";
import {VaultHandler} from "./VaultHandler.sol";

/// C-B1 shared test surface. The clean and planted suites inherit this
/// contract unchanged and differ ONLY in which twin artifact they
/// deploy, so the property surface is provably identical across twins.
///
/// Properties asserted (stateful invariants, 256 runs x depth 50 over
/// deposit/withdraw/swap handler walks):
///
///   b1_balance_split_integrity:
///     hook.idleBalance() + hook.activeBalance() == hook.trackedTotal()
///     The split legs must decrease in exact lockstep with the tracked
///     total. The clean twin's withdraw sourcing assigns the split's
///     wei remainder to the idle leg, so the identity is exact by
///     construction. The planted twin floors the idle leg's share
///     independently; the first withdrawal whose pro-rata divisions
///     carry remainders releases one wei less from the split than from
///     trackedTotal and fires the marker.
///
///   b1_accounting_conservation:
///     hook.totalAssets() + hook.accruedFees() <= asset.balanceOf(hook)
///     The value redeemable across all outstanding shares, net of
///     declared fees, never exceeds what the vault actually holds. On
///     the planted twin the accumulated split drift overstates the
///     books; the check fires whenever the MIN estimate selects the
///     balance-derived leg (the spot-derived leg can conservatively
///     mask wei-scale drift, which is why the split-integrity identity
///     is the precise catch and this one is the solvency statement).
abstract contract VaultCase is V4TestBase {
    /// Mirrors LiquidityVaultHook.WITHDRAW_FEE_BPS for test-side expectations.
    uint256 internal constant FEE_BPS = 10;

    LiquidityVaultHook internal hook;
    VaultHandler internal handler;
    PoolKey internal key;

    /// Twin selection point: the ONLY difference between the clean and
    /// planted suites.
    function _hookArtifact() internal pure virtual returns (string memory);

    function setUp() public {
        deployV4Core();

        handler = new VaultHandler(IPoolManager(address(manager)), token0, token1);
        token0.mint(address(handler), 1_000_000e18);
        token1.mint(address(handler), 1_000_000e18);

        // Handler is the vault admin and sole depositor; the hook lives
        // at an afterSwap-only flag address (deployCodeTo runs the
        // constructor there, so the permission self-check passes). The
        // vault's asset is token0 == the pool's currency0.
        address hookAddr = deployHookTo(
            _hookArtifact(),
            abi.encode(address(manager), address(handler), address(token0)),
            uint160(Hooks.AFTER_SWAP_FLAG),
            0xB1
        );
        hook = LiquidityVaultHook(hookAddr);

        key = initPoolWithLiquidity(IHooks(hookAddr), 3000, 60);
        handler.init(key, hook);

        // Fuzz only the handler's three action selectors; init and the
        // view surface are not fuzz targets (fail_on_revert is on).
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = VaultHandler.deposit.selector;
        selectors[1] = VaultHandler.withdraw.selector;
        selectors[2] = VaultHandler.swap.selector;
        targetSelector(StdInvariant.FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // ------------------------ invariant legs -------------------------

    function invariant_b1_balanceSplitIntegrity() public {
        requireInvariant(hook.idleBalance() + hook.activeBalance() == hook.trackedTotal(), "b1_balance_split_integrity");
    }

    function invariant_b1_conservation() public {
        requireInvariant(
            hook.totalAssets() + hook.accruedFees() <= token0.balanceOf(address(hook)), "b1_accounting_conservation"
        );
    }

    // ----------------------- regression leg --------------------------

    /// Deterministic regression sequence for the rounding-integrity
    /// class: one non-round seed deposit, forty small withdrawals whose
    /// pro-rata sourcing divisions carry wei remainders, then one
    /// ordinary swap. Every step is accounting-only: the logged figures
    /// are the per-step rounding contribution to the split drift and
    /// the cumulative drift, nothing else. The sequence detects the
    /// seeded specification violation and stops at the invariant
    /// checks; it computes no balance deltas for any party.
    ///
    /// Clean twin: the idle leg absorbs each remainder exactly, drift
    /// stays zero at every step, both checks pass. Planted twin: each
    /// remainder-carrying withdrawal under-releases the split by one
    /// wei; the drift accumulates, the split-integrity marker fires,
    /// and after the swap restores the spot-derived estimate above the
    /// balance-derived one (unmasking the MIN), the conservation marker
    /// fires as well.
    function test_regression_b1_roundingDriftAccumulates() public {
        // Non-round seed so pro-rata divisions carry remainders from
        // the first step.
        handler.deposit(1_000_000_000_000_007);

        for (uint256 i = 0; i < 40; i++) {
            uint256 before = _splitDrift();
            // Small, odd-sized share redemptions (in-range, so the
            // handler's _bound is the identity).
            handler.withdraw(3_333 + i * 271);
            uint256 drift = _splitDrift();
            console2.log("regression step", i + 1);
            console2.log("  per-step rounding contribution (wei)", drift - before);
            console2.log("  cumulative split drift (wei)", drift);
        }

        // One ordinary swap (exact-input, zeroForOne). In accounting
        // terms: it moves the pool's sqrtPriceX96 so the spot-derived
        // estimate of the active tranche rises above the
        // balance-derived book value, making the MIN select the book
        // value; the conservation check then compares the drifted books
        // against actual holdings without the conservative mask.
        handler.swap(1e15, true);

        requireInvariant(hook.idleBalance() + hook.activeBalance() == hook.trackedTotal(), "b1_balance_split_integrity");
        requireInvariant(
            hook.totalAssets() + hook.accruedFees() <= token0.balanceOf(address(hook)), "b1_accounting_conservation"
        );
    }

    /// Split drift = (idle + active) - trackedTotal. Zero on the clean
    /// twin by construction; the planted twin's floored idle leg makes
    /// it grow by at most one wei per withdrawal (never negative on
    /// either twin, so the guarded subtraction is exact).
    function _splitDrift() internal view returns (uint256) {
        uint256 split = hook.idleBalance() + hook.activeBalance();
        uint256 tracked = hook.trackedTotal();
        return split >= tracked ? split - tracked : 0;
    }

    // --------------------------- unit leg ----------------------------

    /// First deposit mints shares 1:1 and splits the booked amount
    /// half active, half idle; at the untouched 1:1 pool price the
    /// spot-derived and balance-derived estimates agree exactly.
    function test_unit_depositMintsSharesAndSplitsBalance() public {
        handler.deposit(1_000_000);
        assertEq(hook.sharesOf(address(handler)), 1_000_000, "first deposit not 1:1");
        assertEq(hook.activeBalance(), 500_000, "active leg != half");
        assertEq(hook.idleBalance(), 500_000, "idle leg != half");
        assertEq(hook.trackedTotal(), 1_000_000, "tracked total != deposit");
        assertEq(hook.activeValue(), 500_000, "estimates disagree at 1:1");
        assertEq(hook.totalAssets(), 1_000_000, "nav != tracked at 1:1");
    }

    /// Withdrawal redeems gross assets pro rata, carves out the
    /// declared fee, pays the remainder, and decrements the split in
    /// lockstep with the tracked total (amounts chosen so every
    /// division is exact; both twins agree on exact divisions).
    function test_unit_withdrawPaysGrossMinusDeclaredFee() public {
        handler.deposit(1_000_000);
        uint256 balBefore = token0.balanceOf(address(handler));

        handler.withdraw(500_000);

        uint256 gross = 500_000;
        uint256 fee = (gross * FEE_BPS) / 10_000; // 500
        assertEq(token0.balanceOf(address(handler)) - balBefore, gross - fee, "payout != gross - fee");
        assertEq(hook.accruedFees(), fee, "declared-fee ledger wrong");
        assertEq(hook.activeBalance(), 250_000, "active leg after exact split");
        assertEq(hook.idleBalance(), 250_000, "idle leg after exact split");
        assertEq(hook.trackedTotal(), 500_000, "tracked total after gross");
        assertEq(hook.totalShares(), 500_000, "shares not burned");
    }

    /// The MIN of the two estimates is conservative: a swap that moves
    /// the spot price against the modeled token1 leg lowers the
    /// spot-derived estimate below the balance-derived book value, and
    /// the vault prices shares off the lower figure. Conservation still
    /// holds under the moved price.
    function test_unit_minEstimateConservativeUnderSpotMove() public {
        handler.deposit(1_000_000_000_000);
        // Exact-input oneForZero: raises the token1-per-token0 price,
        // so the modeled token1 leg converts to fewer token0.
        handler.swap(1e16, false);

        assertLt(hook.activeValue(), hook.activeBalance(), "MIN did not select spot-derived estimate");
        assertLt(hook.totalAssets(), hook.trackedTotal(), "nav not discounted");
        assertLe(
            hook.totalAssets() + hook.accruedFees(), token0.balanceOf(address(hook)), "conservation under spot move"
        );
    }

    /// Only the admin (the handler) can register the pool, and only
    /// once.
    function test_unit_onlyAdminSetsPool() public {
        vm.expectRevert(LiquidityVaultHook.NotAdmin.selector);
        hook.setPool(key);
    }

    /// The hook is wired to the real pool: swaps routed through the
    /// PoolManager reach its afterSwap callback.
    function test_unit_hookObservesSwapsOnRealPool() public {
        uint256 before = hook.swapCount();
        handler.swap(1e15, true);
        assertEq(hook.swapCount(), before + 1, "afterSwap not observed");
    }
}
