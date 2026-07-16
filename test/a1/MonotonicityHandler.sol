// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

/// C-A1 fuzz handler. Fires `poke(currentRatio)` on the harness contract
/// (clean or planted) with the ratio bounded into a range that includes
/// deep in-band, both OOB shoulders, and edge cases at the band
/// boundaries. The handler is intentionally minimal — the property being
/// tested lives entirely inside the harness's `poke(...)`, so the fuzz
/// surface only needs to reach every branch of `DynamicFeeLib.withinBounds`
/// and `_applyFeeAdjustment`.
///
/// Bounding rationale: the harness's `_params.maxCurrentRatio` bound is
/// set high (1e21) so the ratio can walk deep into both OOB shoulders
/// without saturating at the max clamp; the low end (1) preserves the
/// non-zero targetRatio path in the library. The `ratioTolerance` on
/// the harness (3e16 = 3%) means any ratio outside ~0.97x..1.03x of the
/// current target ratio hits an OOB branch, which every non-trivial
/// fuzz call reaches.
interface IPokable {
    function poke(uint256 currentRatio) external;
    function targetRatio() external view returns (uint256);
}

contract MonotonicityHandler {
    IPokable public immutable harness;

    // Guard bounds — kept intentionally wide but away from zero and the
    // maxCurrentRatio boundary so `computeNewFee`'s non-trivial branches
    // stay reachable across the whole campaign.
    uint256 public constant MIN_RATIO = 1e15;   // 0.001 in 1e18 fixed-point
    uint256 public constant MAX_RATIO = 1e21;   // matches maxCurrentRatio

    constructor(IPokable _harness) {
        harness = _harness;
    }

    /// Fuzz selector. Bounded so `currentRatio` reliably lands both in
    /// and out of the tolerance band around the (evolving) target.
    function pokeFuzz(uint256 seed) external {
        uint256 r = MIN_RATIO + (seed % (MAX_RATIO - MIN_RATIO));
        harness.poke(r);
    }
}
