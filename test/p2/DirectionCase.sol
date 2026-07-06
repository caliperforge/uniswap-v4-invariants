// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {V4TestBase} from "../base/V4TestBase.sol";
import {DemoDynamicAfterFeeHook} from
    "../../src/cases/p2-dynamicfee-direction-integrity/clean/DemoDynamicAfterFeeHook.sol";
import {DirectionHandler} from "./DirectionHandler.sol";

/// C-P2 shared test surface. The clean and planted suites inherit this
/// contract unchanged and differ ONLY in which twin artifact they
/// deploy, so the property surface is provably identical across twins.
///
/// Property asserted (stateful invariant, 256 runs x depth 50 over a
/// mixed `(zeroForOne, exactInput)` swap walk):
///
///   p2_dynamicfee_direction_integrity:
///     hook.accruedProtocolFees(c) == handler.expectedFees(c)
///
///     For every currency `c` of the pool, the cumulative fee amount
///     the hook has accrued in `c` must equal the cumulative fee the
///     handler computes for `c` under the direction-aware fee
///     ARITHMETIC specified by `BaseDynamicAfterFee` post-`2678eb9`.
///     The clean twin matches this ledger by construction: it subclasses
///     the audited fixed `BaseDynamicAfterFee` (vendored under
///     `src/cases/p2-dynamicfee-direction-integrity/vendor/`) and runs
///     its `_afterSwap` unchanged. The planted twin overrides
///     `_afterSwap` with the pre-`2678eb9` shape (unconditional
///     `feeAmount = unspec - target` + `TargetOutputExceeds` revert),
///     which is the audited M-01 arithmetic. The first fuzzed
///     exactOutput swap diverges the two ledgers and fires the marker.
///
/// Solvency invariant, held by both twins by construction: the hook
/// only ever accrues a fee amount less-than-or-equal-to the
/// unspecified-side amount it observed on the same swap. The check
/// reads from the hook only (not from the handler) so it stays a
/// same-currency bound: a fee arithmetic that computes the wrong
/// magnitude shows up as a direction-integrity failure, not a fake
/// solvency failure.
///
///   p2_fee_solvency:
///     hook.accruedProtocolFees(c) <= hook.cumulativeUnspecifiedAmount(c)
abstract contract DirectionCase is V4TestBase {
    DemoDynamicAfterFeeHook internal hook;
    DirectionHandler internal handler;
    PoolKey internal key;

    /// Twin selection point: the ONLY difference between the clean and
    /// planted suites.
    function _hookArtifact() internal pure virtual returns (string memory);

    function setUp() public {
        deployV4Core();

        // Deploy the hook at an address whose low 14 bits encode
        // BEFORE_SWAP + AFTER_SWAP + AFTER_SWAP_RETURNS_DELTA (0xC4).
        // `deployCodeTo` runs the constructor AT that address, so the
        // vendored `BaseHook`'s `validateHookAddress` self-check passes
        // against OZ's `getHookPermissions` (which sets those three
        // bits).
        address hookAddr = deployHookTo(
            _hookArtifact(),
            abi.encode(address(manager)),
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG),
            0xF2
        );
        hook = DemoDynamicAfterFeeHook(hookAddr);

        // Pool at 1:1 with symmetric concentrated liquidity around
        // tick 0, added through OUR router (as with every other case).
        key = initPoolWithLiquidity(IHooks(hookAddr), 3000, 60);

        handler = new DirectionHandler(IPoolManager(address(manager)), token0, token1);
        // Handler must be able to cover BOTH the exactInput input
        // settlement AND the extra input the planted twin's pre-fix
        // `take()` forces on exactOutput swaps; fund at 1e24 per
        // currency and approve router at max.
        token0.mint(address(handler), 1_000_000e18);
        token1.mint(address(handler), 1_000_000e18);
        handler.init(key);

        // Fuzz only the handler's swap selector (init and view surface
        // are not fuzz targets; fail_on_revert = true).
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = DirectionHandler.swap.selector;
        targetSelector(StdInvariant.FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // ------------------------ invariant legs -------------------------

    function invariant_p2_dynamicfeeDirectionIntegrity() public {
        Currency c0 = key.currency0;
        Currency c1 = key.currency1;
        requireInvariant(
            hook.accruedProtocolFees(c0) == handler.expectedFees(c0)
                && hook.accruedProtocolFees(c1) == handler.expectedFees(c1),
            "p2_dynamicfee_direction_integrity"
        );
    }

    function invariant_p2_feeSolvency() public {
        Currency c0 = key.currency0;
        Currency c1 = key.currency1;
        requireInvariant(
            hook.accruedProtocolFees(c0) <= hook.cumulativeUnspecifiedAmount(c0)
                && hook.accruedProtocolFees(c1) <= hook.cumulativeUnspecifiedAmount(c1),
            "p2_fee_solvency"
        );
    }

    // ----------------------- regression leg --------------------------

    /// Deterministic regression sequence for the class this case
    /// encodes: `(exactInput, exactOutput, exactInput)`. On the clean
    /// twin the hook's ledger advances only on exactInput swaps
    /// (post-fix arithmetic with target=0 skips the exactOutput branch)
    /// and matches the handler's reference on every step. On the planted
    /// twin the exactOutput step accrues a full-magnitude fee via the
    /// pre-fix arithmetic (`feeAmount = unspec - 0 = unspec`), while the
    /// handler advances the direction-aware post-fix ledger which
    /// records zero for the same step, so the property inequality fires
    /// and the marker prints.
    ///
    /// The sequence detects the seeded specification violation and
    /// stops at the invariant check; it computes no balance deltas for
    /// any party and prints no extraction figures.
    function test_regression_p2_directionMismatchOnExactOutput() public {
        // Step 1: exactInput, zeroForOne. Both twins agree.
        handler.swap(uint256(uint128(1e14)), 0);
        // Step 2: exactOutput, zeroForOne. Clean and planted diverge.
        handler.swap(uint256(uint128(1e14)), 1);
        // Step 3: exactInput, oneForZero. On the clean twin the two
        // ledgers still match after this step; on the planted twin the
        // divergence from step 2 is preserved.
        handler.swap(uint256(uint128(1e14)), 2);

        Currency c0 = key.currency0;
        Currency c1 = key.currency1;
        requireInvariant(
            hook.accruedProtocolFees(c0) == handler.expectedFees(c0)
                && hook.accruedProtocolFees(c1) == handler.expectedFees(c1),
            "p2_dynamicfee_direction_integrity"
        );
    }

    // --------------------------- unit legs ---------------------------

    /// The hook is wired to the real pool: the first exactInput swap
    /// routed through PoolManager.swap reaches its `afterSwap` callback
    /// and advances the accrued-fees ledger on the OUTPUT side.
    function test_unit_hookObservesExactInputSwap() public {
        Currency c1 = key.currency1;
        uint256 accruedBefore = hook.accruedProtocolFees(c1);
        // exactInput zeroForOne: unspecified side is currency1 (output).
        handler.swap(uint256(uint128(1e14)), 0);
        assertGt(hook.accruedProtocolFees(c1) - accruedBefore, 0, "exactInput accrual not observed");
    }

    /// exactInput swaps agree between clean and planted (the twin diff
    /// only affects the fee-arithmetic branch that fires on exactOutput
    /// swaps; on exactInput the pre-fix and post-fix arithmetic reduce
    /// to the same expression `feeAmount = unspec - target`).
    function test_unit_exactInputSwapsMatchOnBothTwins() public {
        Currency c0 = key.currency0;
        Currency c1 = key.currency1;
        handler.swap(uint256(uint128(1e14)), 0);
        handler.swap(uint256(uint128(1e14)), 2);
        assertEq(hook.accruedProtocolFees(c0), handler.expectedFees(c0), "c0 accrual should match on exactInput only");
        assertEq(hook.accruedProtocolFees(c1), handler.expectedFees(c1), "c1 accrual should match on exactInput only");
    }
}
