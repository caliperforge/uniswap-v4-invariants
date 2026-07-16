// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {DynamicFeeLib} from "../vendor/alphix-main/DynamicFee.sol";

/// @title AlphixFeeHarnessClean (case A1 CLEAN twin: fee-direction monotonicity)
/// @notice Direct wrapper around Alphix's real audited `DynamicFeeLib`
/// pure library, vendored under `../vendor/alphix-main/DynamicFee.sol`.
///
/// The clean twin "subclasses" Alphix's audited logic in the only way
/// available for a Solidity library: it imports and calls
/// `DynamicFeeLib.computeNewFee(...)` directly. NO byte of the vendored
/// library is altered on this leg. The planted twin (see
/// `../planted/AlphixFeeHarnessPlanted.sol`) imports a byte-copy of the
/// library with the `isUpper` guard removed in `_applyFeeAdjustment` —
/// that is the sole twin-diff hunk.
///
/// Alphix's `Alphix.sol` calls this same `DynamicFeeLib.computeNewFee`
/// from inside its own `poke(...)` (owner-restricted, reads current fee
/// from `PoolManager.getSlot0`). The harness here reproduces that
/// call-site shape at the pure-library level: it keeps the current fee,
/// target ratio, OOB state, and pool params in storage across a
/// stateful fuzz walk, and lets each `poke(...)` advance them exactly
/// the way `Alphix._poke` advances the on-chain state.
///
/// The monotonicity property this case asserts (see the case README for
/// the full statement) is a byte-faithful consequence of Alphix's
/// `_applyFeeAdjustment` direction guard:
///
///   isUpper == true  →  newFee >= oldFee  (or clamped to maxFee)
///   isUpper == false →  newFee <= oldFee  (or clamped to minFee)
///
/// The clean twin holds this property by construction. The planted twin,
/// with the direction guard removed (both branches subtract), fails it
/// on the first out-of-band UPPER poke.
contract AlphixFeeHarnessClean {
    // --------------------- state (mirrors Alphix._poke) ---------------------

    uint24 public currentFee;
    uint256 public targetRatio;
    DynamicFeeLib.OobState internal _oobState;
    DynamicFeeLib.PoolParams internal _params;
    uint256 public globalMaxAdjRate;

    // ----- last-call observation ledger (read by the invariant surface) -----

    /// Whether the last `poke` was OOB and, if so, on which side. Set
    /// straight from `DynamicFeeLib.withinBounds` before the call, so
    /// the invariant reads the same isUpper the library saw.
    bool public lastPokeWasOob;
    bool public lastPokeIsUpper;
    uint24 public lastPokeOldFee;
    uint24 public lastPokeNewFee;
    uint256 public pokeCount;

    // ----------------------------- init ---------------------------------

    constructor(
        uint24 initialFee,
        uint256 initialTargetRatio,
        uint256 initialGlobalMaxAdjRate,
        DynamicFeeLib.PoolParams memory p
    ) {
        currentFee = initialFee;
        targetRatio = initialTargetRatio;
        globalMaxAdjRate = initialGlobalMaxAdjRate;
        _params = p;
        // _oobState defaults to zero (no streak, lastOobWasUpper=false),
        // which matches Alphix's own storage default in `_oobState`.
    }

    // ------------------------- library facade -------------------------

    /// Mirror of the poke() call-site in `Alphix.sol`: compute new fee
    /// via the vendored `DynamicFeeLib.computeNewFee`, then advance
    /// EMA-updated target ratio, and store both. The current-fee input
    /// each call is the last stored `currentFee` (same as Alphix reads
    /// `poolManager.getSlot0(_poolId)` on-chain; the pure library sees
    /// the same value either way).
    function poke(uint256 currentRatio) external {
        // Observe branch BEFORE the library call so the invariant sees
        // the same (upper, inBand) the library saw. Function is pure so
        // this is free of state effects.
        (bool isUpper, bool inBand) =
            DynamicFeeLib.withinBounds(targetRatio, _params.ratioTolerance, currentRatio);
        bool wasOob = (targetRatio != 0) && !inBand;

        uint24 oldFee = currentFee;

        (uint24 newFee, DynamicFeeLib.OobState memory sOut) = DynamicFeeLib.computeNewFee(
            oldFee, currentRatio, targetRatio, globalMaxAdjRate, _params, _oobState
        );

        // Advance target ratio via the same EMA the on-chain hook uses.
        // The monotonicity property this case asserts is on `newFee` vs
        // `oldFee`; EMA advance is included so the stateful walk exercises
        // the whole call-site sequence Alphix actually runs.
        uint256 newTarget =
            DynamicFeeLib.ema(currentRatio, targetRatio, _params.lookbackPeriod);
        if (newTarget > _params.maxCurrentRatio) newTarget = _params.maxCurrentRatio;
        if (newTarget == 0) newTarget = 1;

        currentFee = newFee;
        targetRatio = newTarget;
        _oobState = sOut;

        lastPokeWasOob = wasOob;
        lastPokeIsUpper = isUpper;
        lastPokeOldFee = oldFee;
        lastPokeNewFee = newFee;
        pokeCount += 1;
    }

    // ------------------------- read surface ---------------------------

    function params() external view returns (DynamicFeeLib.PoolParams memory) {
        return _params;
    }

    function oobState() external view returns (DynamicFeeLib.OobState memory) {
        return _oobState;
    }
}
