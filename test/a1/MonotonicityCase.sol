// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {V4TestBase} from "../base/V4TestBase.sol";
import {MonotonicityHandler, IPokable} from "./MonotonicityHandler.sol";

/// C-A1 shared test surface. The clean and planted suites inherit this
/// contract unchanged and differ ONLY in which harness they deploy, so
/// the property surface is provably identical across twins.
///
/// Properties asserted (stateful invariant, 256 runs × depth 50):
///
///   a1_fee_direction_monotonicity:
///     if the last poke was OOB and isUpper, then
///        (newFee >= oldFee) || (newFee == maxFee)
///     if the last poke was OOB and !isUpper, then
///        (newFee <= oldFee) || (newFee == minFee)
///
///   a1_fee_bounds (both twins by construction):
///     minFee <= currentFee <= maxFee
///
/// The clean twin holds `a1_fee_direction_monotonicity` because Alphix's
/// audited `_applyFeeAdjustment` branches on `isUpper` and moves the fee
/// toward the correct side of the band. The planted twin (guard removed;
/// both branches subtract) violates it on the first upper-OOB poke.
abstract contract MonotonicityCase is V4TestBase {
    IPokable internal harness;
    MonotonicityHandler internal handler;

    /// Twin-selection point: the ONLY difference between clean and
    /// planted suites.
    function _deployHarness() internal virtual returns (IPokable);

    /// Reads used by the invariant surface (same names on both harnesses,
    /// same semantics). Kept as abstract accessors so the invariant body
    /// is 100% shared between suites.
    function _lastPokeWasOob() internal view virtual returns (bool);
    function _lastPokeIsUpper() internal view virtual returns (bool);
    function _lastPokeOldFee() internal view virtual returns (uint24);
    function _lastPokeNewFee() internal view virtual returns (uint24);
    function _currentFee() internal view virtual returns (uint24);
    function _minFee() internal view virtual returns (uint24);
    function _maxFee() internal view virtual returns (uint24);

    function setUp() public {
        harness = _deployHarness();
        handler = new MonotonicityHandler(harness);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = MonotonicityHandler.pokeFuzz.selector;
        targetSelector(StdInvariant.FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // ------------------------ invariant legs -------------------------

    function invariant_a1_feeDirectionMonotonicity() public {
        if (!_lastPokeWasOob()) {
            // In-band or targetRatio==0: property is vacuously true; the
            // library returns clampFee(currentFee, min, max) unchanged.
            return;
        }
        uint24 oldFee = _lastPokeOldFee();
        uint24 newFee = _lastPokeNewFee();
        bool ok;
        if (_lastPokeIsUpper()) {
            ok = (newFee >= oldFee) || (newFee == _maxFee());
        } else {
            ok = (newFee <= oldFee) || (newFee == _minFee());
        }
        requireInvariant(ok, "a1_fee_direction_monotonicity");
    }

    function invariant_a1_feeBounds() public {
        uint24 f = _currentFee();
        requireInvariant(f >= _minFee() && f <= _maxFee(), "a1_fee_bounds");
    }

    // ----------------------- regression leg --------------------------

    /// Deterministic regression: start with a mid-band fee, push a
    /// current-ratio deep into the UPPER OOB shoulder (10x the initial
    /// target). On the clean twin this walks the fee UP (or clamps to
    /// maxFee); on the planted twin it walks the fee DOWN, violating
    /// direction monotonicity. The oldFee here is >0 by construction so
    /// the direction step is observable (not swallowed by a clamp-to-zero).
    function test_regression_a1_upperOobDropsFee() public {
        // 10_000_000e18 is ~10x the initial 1e18 target ratio the case
        // sets up in setUp; it lies deep outside the 3% tolerance band.
        harness.poke(10_000_000e18);
        // A single upper-OOB poke suffices: the sign of the fee move is
        // fully determined by the branch taken inside `_applyFeeAdjustment`.
        uint24 oldFee = _lastPokeOldFee();
        uint24 newFee = _lastPokeNewFee();
        bool ok = _lastPokeIsUpper()
            ? ((newFee >= oldFee) || (newFee == _maxFee()))
            : ((newFee <= oldFee) || (newFee == _minFee()));
        requireInvariant(ok, "a1_fee_direction_monotonicity");
    }

    // --------------------------- unit legs ---------------------------

    /// Sanity: the harness wires the library through — a deep upper-OOB
    /// poke on either twin actually mutates the stored `currentFee`
    /// (i.e. we're testing a live call-site, not a no-op).
    function test_unit_upperOobMutatesFee() public {
        uint24 before_ = _currentFee();
        harness.poke(10_000_000e18);
        // Fee must change — otherwise the harness isn't hooked up.
        assertTrue(_currentFee() != before_ || before_ == _maxFee() || before_ == _minFee());
    }
}
