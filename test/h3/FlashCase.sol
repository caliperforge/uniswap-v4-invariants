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
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {V4TestBase} from "../base/V4TestBase.sol";
// The clean twin is imported as the canonical ABI type; both twins
// share an identical external surface, so the planted suite casts its
// planted deployment (placed via deployCodeTo) to this same type.
import {FlashHook} from "../../src/cases/h3-flash-accounting/clean/FlashHook.sol";
import {FlashHandler} from "./FlashHandler.sol";

/// C-H3 shared test surface. The clean and planted suites inherit this
/// contract unchanged and differ ONLY in which twin artifact they
/// deploy, so the property surface is provably identical across twins.
///
/// Property asserted (stateful invariant, 256 runs x depth 50):
///
///   h3_flash_accounting:
///     handler.settleGuardReverts() == 0
///
///   i.e. no swap, bonus path included, ever ends its unlock with an
///   unsettled hook currency delta. The clean twin's bonus path
///   performs the full settle dance and stays at zero. The planted
///   twin's bonus path opens a delta and never closes it, so the first
///   fuzzed swap that opts into the bonus trips the manager's
///   CurrencyNotSettled guard and fires the marker.
abstract contract FlashCase is V4TestBase {
    /// Mirrors FlashHook.BONUS / BONUS_BYTE for test-side expectations.
    uint256 internal constant BONUS = 1e15;
    bytes1 internal constant BONUS_BYTE = 0xBB;

    /// currency0 funding minted to the hook in setUp so the clean
    /// twin's settle dance can pay every bonus from the hook's own
    /// balance (worst case 12,800 opted-in swaps * 1e15 = 12.8e18).
    uint256 internal constant HOOK_FUNDING = 100e18;

    FlashHook internal hook;
    FlashHandler internal handler;
    PoolKey internal key;

    /// Twin selection point: the ONLY difference between the clean and
    /// planted suites.
    function _hookArtifact() internal pure virtual returns (string memory);

    function setUp() public {
        deployV4Core();

        handler = new FlashHandler(IPoolManager(address(manager)), token0, token1);
        token0.mint(address(handler), 1_000_000e18);
        token1.mint(address(handler), 1_000_000e18);

        // Hook at a beforeSwap-only flag address (deployCodeTo runs the
        // constructor there, so the permission self-check passes).
        address hookAddr = deployHookTo(_hookArtifact(), abi.encode(address(manager)), uint160(Hooks.BEFORE_SWAP_FLAG), 0xF3);
        hook = FlashHook(hookAddr);

        key = initPoolWithLiquidity(IHooks(hookAddr), 3000, 60);
        handler.init(key);

        // Fund the hook: the clean bonus path pays BONUS out of this
        // balance through the settle dance.
        token0.mint(hookAddr, HOOK_FUNDING);

        // Fuzz only the handler's swap selector; init and the view
        // surface are not fuzz targets (fail_on_revert is on).
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = FlashHandler.swap.selector;
        targetSelector(StdInvariant.FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // ------------------------- invariant leg -------------------------

    function invariant_h3_bonusPathSettles() public {
        requireInvariant(handler.settleGuardReverts() == 0, "h3_flash_accounting");
    }

    // ------------------------ regression leg -------------------------

    /// Deterministic regression sequence, the feasibility spike's test
    /// 3 shape verbatim: a benign swap (no opt-in byte) completes, then
    /// a fixed 1e18 exact-input swap opts into the bonus path via
    /// hookData 0xBB.
    ///
    /// Clean twin: the bonus path runs the full settle dance; the swap
    /// completes, the sender router holds the bonus, the hook's funding
    /// dropped by exactly BONUS, and no marker prints.
    /// Planted twin: the unlock ends with the hook's -BONUS delta open;
    /// the manager reverts the whole swap with CurrencyNotSettled, the
    /// counter goes nonzero, and the marker fires.
    function test_regression_h3_takeWithoutSettleTripsGuard() public {
        // Benign leg: no opt-in byte, no flash-accounting interaction.
        swapExactIn(router, key, -1e18, "");
        assertEq(hook.bonusPaid(), 0, "benign leg touched the bonus path");

        uint256 routerBal0Before = token0.balanceOf(address(router));
        uint256 caught = 0;

        try router.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -1e18,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            abi.encodePacked(BONUS_BYTE)
        ) returns (BalanceDelta) {
            // Clean path: the settle dance really moved balances and
            // closed the delta. The bonus recipient is `sender` as the
            // hook sees it, i.e. the router contract.
            assertEq(hook.bonusPaid(), BONUS, "bonus not booked");
            assertEq(token0.balanceOf(address(router)), routerBal0Before + BONUS, "bonus not received by sender");
            assertEq(hook.fundingBalance(Currency.wrap(address(token0))), HOOK_FUNDING - BONUS, "hook funding not debited");
        } catch (bytes memory reason) {
            // length is checked to be exactly 4, so the bytes -> bytes4
            // cast cannot truncate meaningful data
            // forge-lint: disable-next-line(unsafe-typecast)
            if (reason.length == 4 && bytes4(reason) == IPoolManager.CurrencyNotSettled.selector) {
                caught = 1;
            } else {
                assembly ("memory-safe") {
                    revert(add(reason, 0x20), mload(reason))
                }
            }
        }

        requireInvariant(caught == 0, "h3_flash_accounting");
    }

    // --------------------------- unit leg ----------------------------

    /// A swap that does not opt in never touches the flash-accounting
    /// bonus path: no bonus booked, hook funding untouched. Passes on
    /// both twins (the twins are identical off the bonus path).
    function test_unit_benignSwapLeavesFundingUntouched() public {
        swapExactIn(router, key, -1e18, "");
        assertEq(hook.bonusPaid(), 0, "bonus booked without opt-in");
        assertEq(hook.fundingBalance(Currency.wrap(address(token0))), HOOK_FUNDING, "funding moved without opt-in");
    }

    /// Only the real PoolManager may call the hook's beforeSwap.
    function test_unit_onlyManagerCallsBeforeSwap() public {
        vm.expectRevert(FlashHook.NotManager.selector);
        hook.beforeSwap(
            address(this),
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            abi.encodePacked(BONUS_BYTE)
        );
    }

    /// The funding precondition of the clean settle dance is in place
    /// after setUp (documented so a reviewer sees the clean twin pays
    /// bonuses from its own balance, not from thin air).
    function test_unit_bonusFundingInPlace() public view {
        assertEq(hook.fundingBalance(Currency.wrap(address(token0))), HOOK_FUNDING, "hook not funded");
        assertEq(hook.BONUS(), BONUS, "test mirror of BONUS diverged");
    }
}
