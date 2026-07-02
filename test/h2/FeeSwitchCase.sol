// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {V4TestBase} from "../base/V4TestBase.sol";
import {InvariantRouter} from "../../src/routers/InvariantRouter.sol";
import {FeeSwitchHook} from "../../src/cases/h2-fee-waiver/clean/FeeSwitchHook.sol";
import {FeeSwitchHandler} from "./FeeSwitchHandler.sol";

/// C-H2 shared test surface. The clean and planted suites inherit this
/// contract unchanged and differ ONLY in which twin artifact they
/// deploy, so the property surface is provably identical across twins.
///
/// Property asserted (stateful invariant, 256 runs x depth 50):
///
///   h2_fee_waiver_via_hookdata:
///     hook.accruedFees() == handler.expectedFees()
///
///   The handler's ledger extends by CLEAN semantics only (admin
///   allowlist; hookData never consulted). The clean twin stays in
///   lockstep. The planted twin honors the waiver from hookData[0], so
///   the first fuzzed swap that claims the waiver from a
///   non-allowlisted router diverges the ledgers and fires the marker.
abstract contract FeeSwitchCase is V4TestBase {
    /// Mirrors FeeSwitchHook.FEE_BPS for test-side expectations.
    uint256 internal constant FEE_BPS = 30;
    bytes1 internal constant WAIVER_BYTE = 0x01;

    FeeSwitchHook internal hook;
    FeeSwitchHandler internal handler;
    PoolKey internal key;

    /// Twin selection point: the ONLY difference between the clean and
    /// planted suites.
    function _hookArtifact() internal pure virtual returns (string memory);

    function setUp() public {
        deployV4Core();

        handler = new FeeSwitchHandler(IPoolManager(address(manager)), token0, token1);
        token0.mint(address(handler), 1_000_000e18);
        token1.mint(address(handler), 1_000_000e18);

        // Handler is the hook admin; hook lives at an afterSwap-only
        // flag address (deployCodeTo runs the constructor there, so the
        // hook's permission self-check passes).
        address hookAddr = deployHookTo(
            _hookArtifact(), abi.encode(address(manager), address(handler)), uint160(Hooks.AFTER_SWAP_FLAG), 0xF2
        );
        hook = FeeSwitchHook(hookAddr);

        key = initPoolWithLiquidity(IHooks(hookAddr), 3000, 60);
        handler.init(key, hook);

        // One allowlisted actor from the start so the fuzz walk
        // exercises the legitimate waiver path alongside churn.
        handler.setExempt(0, true);

        // Fuzz only the handler's two action selectors; init and the
        // view surface are not fuzz targets (fail_on_revert is on).
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = FeeSwitchHandler.swap.selector;
        selectors[1] = FeeSwitchHandler.setExempt.selector;
        targetSelector(StdInvariant.FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // ------------------------- invariant leg -------------------------

    function invariant_h2_accruedFees_match_expected() public {
        requireInvariant(hook.accruedFees() == handler.expectedFees(), "h2_fee_waiver_via_hookdata");
    }

    // ------------------------ regression leg ------------------------

    /// Deterministic regression sequence: an UNENTITLED swapper (a fresh
    /// router, never allowlisted) crafts hookData whose first byte is
    /// the waiver magic and swaps 1e18 exact-input.
    ///
    /// Clean twin: hookData plays no part in the waiver; the full fee
    /// (1e18 * 30 / 10_000 = 3e15) is charged; the assertion holds.
    /// Planted twin: the hook honors the crafted waiver; the unentitled
    /// swapper's fee is zeroed; the marker fires and the test fails.
    function test_regression_h2_unentitledWaiverViaHookData() public {
        InvariantRouter unentitledSwapper = newRouterActor(address(this));
        uint256 amount = 1e18;
        uint256 accruedBefore = hook.accruedFees();
        uint256 expectedFee = (amount * FEE_BPS) / 10_000;

        // amount is the constant 1e18, so the uint256 -> int256 cast is safe
        // forge-lint: disable-next-line(unsafe-typecast)
        swapExactIn(unentitledSwapper, key, -int256(amount), abi.encodePacked(WAIVER_BYTE));

        requireInvariant(
            hook.feesBy(address(unentitledSwapper)) == expectedFee && hook.accruedFees() == accruedBefore + expectedFee,
            "h2_fee_waiver_via_hookdata"
        );
    }

    // --------------------------- unit leg ----------------------------

    /// Fee is sized on the specified amount, exactly FEE_BPS of it, and
    /// the handler ledger agrees. Router 1 is not allowlisted; seeds
    /// are in-range so _bound leaves them unchanged.
    function test_unit_feeSizedOnSpecifiedAmount() public {
        handler.swap(1, 5e16, false, true);
        assertEq(hook.accruedFees(), (5e16 * FEE_BPS) / 10_000, "fee != FEE_BPS of specified");
        assertEq(hook.accruedFees(), handler.expectedFees(), "ledgers diverge on unit path");
    }

    /// The admin allowlist waives on BOTH twins (the planted twin adds
    /// an evasion path on top of the admin path, it does not replace
    /// it). Router 0 was allowlisted in setUp.
    function test_unit_allowlistedSenderPaysZero() public {
        handler.swap(0, 5e16, false, false);
        assertEq(hook.accruedFees(), 0, "allowlisted sender was charged");
        assertEq(handler.expectedFees(), 0, "model charged allowlisted sender");
        assertEq(hook.feesBy(address(handler.routers(0))), 0, "per-sender ledger nonzero");
    }

    /// Only the admin can edit the allowlist; this test contract is not
    /// the admin (the handler is).
    function test_unit_onlyAdminSetsAllowlist() public {
        vm.expectRevert(FeeSwitchHook.NotAdmin.selector);
        hook.setFeeExempt(address(0xBEEF), true);
    }
}
