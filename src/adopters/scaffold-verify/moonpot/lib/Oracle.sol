// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

// Ported to Solidity 0.8.x from Uniswap v3-core `Oracle.sol`:
// https://github.com/Uniswap/v3-core/blob/main/contracts/libraries/Oracle.sol
// Behaviour is preserved; arithmetic that relied on pre-0.8 wrapping is wrapped
// in `unchecked` blocks and signed/unsigned multiplications are made explicit.
// This file is BUSL-1.1 (Uniswap), unlike the rest of this MIT-licensed repo.

/// @title Oracle
/// @notice Provides price and liquidity data useful for a wide variety of system designs
/// @dev Observations are collected in the oracle array. Cardinality and index are tracked by the caller.
library Oracle {
    struct Observation {
        uint32 blockTimestamp;
        int56 tickCumulative;
        uint160 secondsPerLiquidityCumulativeX128;
        bool initialized;
    }

    /// @notice Transforms a previous observation into a new one given elapsed time and the current tick/liquidity.
    function transform(
        Observation memory last,
        uint32 blockTimestamp,
        int24 tick,
        uint128 liquidity
    ) private pure returns (Observation memory) {
        unchecked {
            uint32 delta = blockTimestamp - last.blockTimestamp;
            return
                Observation({
                    blockTimestamp: blockTimestamp,
                    tickCumulative: last.tickCumulative +
                        int56(tick) * int56(uint56(delta)),
                    secondsPerLiquidityCumulativeX128: last
                        .secondsPerLiquidityCumulativeX128 +
                        ((uint160(delta) << 128) / (liquidity > 0 ? liquidity : 1)),
                    initialized: true
                });
        }
    }

    /// @notice Initializes the oracle array by writing the first slot.
    function initialize(
        Observation[65535] storage self,
        uint32 time
    ) internal returns (uint16 cardinality, uint16 cardinalityNext) {
        self[0] = Observation({
            blockTimestamp: time,
            tickCumulative: 0,
            secondsPerLiquidityCumulativeX128: 0,
            initialized: true
        });
        return (1, 1);
    }

    /// @notice Writes an oracle observation to the array (at most once per block).
    function write(
        Observation[65535] storage self,
        uint16 index,
        uint32 blockTimestamp,
        int24 tick,
        uint128 liquidity,
        uint16 cardinality,
        uint16 cardinalityNext
    ) internal returns (uint16 indexUpdated, uint16 cardinalityUpdated) {
        unchecked {
            Observation memory last = self[index];

            // early return if we've already written an observation this block
            if (last.blockTimestamp == blockTimestamp) return (index, cardinality);

            if (cardinalityNext > cardinality && index == (cardinality - 1)) {
                cardinalityUpdated = cardinalityNext;
            } else {
                cardinalityUpdated = cardinality;
            }

            indexUpdated = (index + 1) % cardinalityUpdated;
            self[indexUpdated] = transform(last, blockTimestamp, tick, liquidity);
        }
    }

    /// @notice Prepares the oracle array to store up to `next` observations.
    function grow(
        Observation[65535] storage self,
        uint16 current,
        uint16 next
    ) internal returns (uint16) {
        unchecked {
            require(current > 0, "I");
            if (next <= current) return current;
            // store in each slot to prevent fresh SSTOREs in swaps; unused until initialized
            for (uint16 i = current; i < next; i++) {
                self[i].blockTimestamp = 1;
            }
            return next;
        }
    }

    /// @notice 32-bit timestamp comparator, safe for 0 or 1 overflows.
    function lte(uint32 time, uint32 a, uint32 b) private pure returns (bool) {
        unchecked {
            if (a <= time && b <= time) return a <= b;
            uint256 aAdjusted = a > time ? a : uint256(a) + 2 ** 32;
            uint256 bAdjusted = b > time ? b : uint256(b) + 2 ** 32;
            return aAdjusted <= bAdjusted;
        }
    }

    /// @notice Fetches the observations [beforeOrAt, atOrAfter] bracketing a target within the stored boundaries.
    function binarySearch(
        Observation[65535] storage self,
        uint32 time,
        uint32 target,
        uint16 index,
        uint16 cardinality
    )
        private
        view
        returns (Observation memory beforeOrAt, Observation memory atOrAfter)
    {
        unchecked {
            uint256 l = (index + 1) % cardinality; // oldest observation
            uint256 r = l + cardinality - 1; // newest observation
            uint256 i;
            while (true) {
                i = (l + r) / 2;

                beforeOrAt = self[i % cardinality];

                // we've landed on an uninitialized tick, keep searching higher (more recently)
                if (!beforeOrAt.initialized) {
                    l = i + 1;
                    continue;
                }

                atOrAfter = self[(i + 1) % cardinality];

                bool targetAtOrAfter = lte(time, beforeOrAt.blockTimestamp, target);

                if (targetAtOrAfter && lte(time, target, atOrAfter.blockTimestamp))
                    break;

                if (!targetAtOrAfter) r = i - 1;
                else l = i + 1;
            }
        }
    }

    /// @notice Fetches the observations bracketing a target; assumes at least 1 initialized observation.
    function getSurroundingObservations(
        Observation[65535] storage self,
        uint32 time,
        uint32 target,
        int24 tick,
        uint16 index,
        uint128 liquidity,
        uint16 cardinality
    )
        private
        view
        returns (Observation memory beforeOrAt, Observation memory atOrAfter)
    {
        unchecked {
            // optimistically set before to the newest observation
            beforeOrAt = self[index];

            if (lte(time, beforeOrAt.blockTimestamp, target)) {
                if (beforeOrAt.blockTimestamp == target) {
                    return (beforeOrAt, atOrAfter);
                } else {
                    return (beforeOrAt, transform(beforeOrAt, target, tick, liquidity));
                }
            }

            // now, set before to the oldest observation
            beforeOrAt = self[(index + 1) % cardinality];
            if (!beforeOrAt.initialized) beforeOrAt = self[0];

            require(lte(time, beforeOrAt.blockTimestamp, target), "OLD");

            return binarySearch(self, time, target, index, cardinality);
        }
    }

    /// @notice Returns the cumulative values as of `secondsAgo`. Reverts ("OLD") if older than the oldest observation.
    function observeSingle(
        Observation[65535] storage self,
        uint32 time,
        uint32 secondsAgo,
        int24 tick,
        uint16 index,
        uint128 liquidity,
        uint16 cardinality
    )
        internal
        view
        returns (int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128)
    {
        unchecked {
            if (secondsAgo == 0) {
                Observation memory last = self[index];
                if (last.blockTimestamp != time)
                    last = transform(last, time, tick, liquidity);
                return (last.tickCumulative, last.secondsPerLiquidityCumulativeX128);
            }

            uint32 target = time - secondsAgo;

            (
                Observation memory beforeOrAt,
                Observation memory atOrAfter
            ) = getSurroundingObservations(
                    self,
                    time,
                    target,
                    tick,
                    index,
                    liquidity,
                    cardinality
                );

            if (target == beforeOrAt.blockTimestamp) {
                return (
                    beforeOrAt.tickCumulative,
                    beforeOrAt.secondsPerLiquidityCumulativeX128
                );
            } else if (target == atOrAfter.blockTimestamp) {
                return (
                    atOrAfter.tickCumulative,
                    atOrAfter.secondsPerLiquidityCumulativeX128
                );
            } else {
                uint32 observationTimeDelta = atOrAfter.blockTimestamp -
                    beforeOrAt.blockTimestamp;
                uint32 targetDelta = target - beforeOrAt.blockTimestamp;
                return (
                    beforeOrAt.tickCumulative +
                        ((atOrAfter.tickCumulative - beforeOrAt.tickCumulative) /
                            int56(uint56(observationTimeDelta))) *
                        int56(uint56(targetDelta)),
                    beforeOrAt.secondsPerLiquidityCumulativeX128 +
                        uint160(
                            (uint256(
                                atOrAfter.secondsPerLiquidityCumulativeX128 -
                                    beforeOrAt.secondsPerLiquidityCumulativeX128
                            ) * targetDelta) / observationTimeDelta
                        )
                );
            }
        }
    }

    /// @notice Returns cumulative values for each `secondsAgos`. Reverts ("OLD") if any is older than the oldest observation.
    function observe(
        Observation[65535] storage self,
        uint32 time,
        uint32[] memory secondsAgos,
        int24 tick,
        uint16 index,
        uint128 liquidity,
        uint16 cardinality
    )
        internal
        view
        returns (
            int56[] memory tickCumulatives,
            uint160[] memory secondsPerLiquidityCumulativeX128s
        )
    {
        unchecked {
            require(cardinality > 0, "I");

            tickCumulatives = new int56[](secondsAgos.length);
            secondsPerLiquidityCumulativeX128s = new uint160[](secondsAgos.length);
            for (uint256 i = 0; i < secondsAgos.length; i++) {
                (
                    tickCumulatives[i],
                    secondsPerLiquidityCumulativeX128s[i]
                ) = observeSingle(
                    self,
                    time,
                    secondsAgos[i],
                    tick,
                    index,
                    liquidity,
                    cardinality
                );
            }
        }
    }
}
