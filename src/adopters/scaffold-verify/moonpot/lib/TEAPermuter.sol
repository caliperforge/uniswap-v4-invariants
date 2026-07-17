// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/// @title TEAPermuter
/// @notice Format-preserving permutations based on a TEA-like Feistel construction
///         specialized for small integer domains (20-bit ≈ 1M, 10-bit ≈ 1K, 9-bit ≈ 500).
library TEAPermuter {
    // TEA constant
    uint32 private constant DELTA = 0x9E3779B9;

    // --- 20-bit config (≈1,048,576 states) ---
    uint256 private constant BLOCK_BITS_20 = 20;
    uint256 private constant BLOCK_MASK_20 = (1 << BLOCK_BITS_20) - 1;
    uint256 private constant L_BITS0_20 = 10;
    uint256 private constant R_BITS0_20 = 10;
    uint256 private constant L_MASK0_20 = (1 << L_BITS0_20) - 1;
    uint256 private constant R_MASK0_20 = (1 << R_BITS0_20) - 1;

    // --- 17-bit config (131,072 states) ---
    uint256 private constant BLOCK_BITS_17 = 17;
    uint256 private constant BLOCK_MASK_17 = (1 << BLOCK_BITS_17) - 1;
    uint256 private constant L_BITS0_17 = 9;
    uint256 private constant R_BITS0_17 = 8;
    uint256 private constant L_MASK0_17 = (1 << L_BITS0_17) - 1;
    uint256 private constant R_MASK0_17 = (1 << R_BITS0_17) - 1;

    // --- 14-bit config (≈16,384 states) ---
    uint256 private constant BLOCK_BITS_14 = 14;
    uint256 private constant BLOCK_MASK_14 = (1 << BLOCK_BITS_14) - 1;
    // Split 14 bits into 7 (Left) and 7 (Right)
    uint256 private constant L_BITS0_14 = 7;
    uint256 private constant R_BITS0_14 = 7;
    uint256 private constant L_MASK0_14 = (1 << L_BITS0_14) - 1;
    uint256 private constant R_MASK0_14 = (1 << R_BITS0_14) - 1;

    // --- 10-bit config (≈1,024 states) ---
    uint256 private constant BLOCK_BITS_10 = 10;
    uint256 private constant BLOCK_MASK_10 = (1 << BLOCK_BITS_10) - 1;
    uint256 private constant L_BITS0_10 = 5;
    uint256 private constant R_BITS0_10 = 5;
    uint256 private constant L_MASK0_10 = (1 << L_BITS0_10) - 1;
    uint256 private constant R_MASK0_10 = (1 << R_BITS0_10) - 1;

    // --- 9-bit config (≈512 states) ---
    uint256 private constant BLOCK_BITS_9 = 9;
    uint256 private constant BLOCK_MASK_9 = (1 << BLOCK_BITS_9) - 1;
    uint256 private constant L_BITS0_9 = 5;
    uint256 private constant R_BITS0_9 = 4;
    uint256 private constant L_MASK0_9 = (1 << L_BITS0_9) - 1;
    uint256 private constant R_MASK0_9 = (1 << R_BITS0_9) - 1;

    // --- Internal helpers ---
    function _keySchedule(
        uint256 seed
    ) private pure returns (uint32 k0, uint32 k1, uint32 k2, uint32 k3) {
        bytes32 h0 = keccak256(abi.encode(seed, uint256(0)));
        bytes32 h1 = keccak256(abi.encode(seed, uint256(1)));
        k0 = uint32(uint256(h0));
        k1 = uint32(uint256(h0 >> 32));
        k2 = uint32(uint256(h1));
        k3 = uint32(uint256(h1 >> 32));
    }

    function _mix(
        uint32 v,
        uint32 sum,
        uint32 k0,
        uint32 k1
    ) private pure returns (uint32) {
        unchecked {
            return ((v << 4) + k0) ^ (v + sum) ^ ((v >> 5) + k1);
        }
    }

    // --- Core encryptions for different bit widths ---
    function _encryptGeneric(
        uint256 x,
        uint256 rounds,
        uint256 seed,
        uint256 lBits,
        uint256 rBits,
        uint256 lMask,
        uint256 rMask
    ) private pure returns (uint256) {
        (uint32 k0, uint32 k1, uint32 k2, uint32 k3) = _keySchedule(seed);

        uint256 l = (x >> rBits) & lMask;
        uint256 r = x & rMask;
        uint32 sum = 0;

        unchecked {
            for (uint256 i = 0; i < rounds; i++) {
                sum += DELTA;
                uint32 f = (i & 1) == 0
                    ? _mix(uint32(r), sum, k0, k1)
                    : _mix(uint32(r), sum, k2, k3);

                uint256 newL = r;
                uint256 newR = (l ^ (uint256(f) & lMask)) & lMask;

                l = newL & rMask;
                r = newR & lMask;

                (lBits, rBits) = (rBits, lBits);
                (lMask, rMask) = (rMask, lMask);
            }

            return
                ((l & ((1 << lBits) - 1)) << rBits) | (r & ((1 << rBits) - 1));
        }
    }

    // --- Format-preserving permutations ---

    /// @notice Permutation on [0, n) for n ≤ 1,048,576.
    function permute20(
        uint256 x,
        uint256 n,
        uint256 seed,
        uint256 rounds
    ) internal pure returns (uint256) {
        require(x < n, "Out of range");
        require(n > 0 && n <= (1 << BLOCK_BITS_20), "n too large");

        unchecked {
            uint256 y = x & BLOCK_MASK_20;
            while (true) {
                y =
                    _encryptGeneric(
                        y,
                        rounds,
                        seed,
                        L_BITS0_20,
                        R_BITS0_20,
                        L_MASK0_20,
                        R_MASK0_20
                    ) &
                    BLOCK_MASK_20;
                if (y < n) return y;
            }
        }
    }

    /// @notice Permutation on [0, n) for n ≤ 131,072.
    function permute17(
        uint256 x,
        uint256 n,
        uint256 seed,
        uint256 rounds
    ) internal pure returns (uint256) {
        require(x < n, "Out of range");
        require(n > 0 && n <= (1 << BLOCK_BITS_17), "n too large");

        unchecked {
            uint256 y = x & BLOCK_MASK_17;
            while (true) {
                y =
                    _encryptGeneric(
                        y,
                        rounds,
                        seed,
                        L_BITS0_17,
                        R_BITS0_17,
                        L_MASK0_17,
                        R_MASK0_17
                    ) &
                    BLOCK_MASK_17;
                if (y < n) return y;
            }
        }
    }

    /// @notice Permutation on [0, n) for n ≤ 16,384.
    function permute14(
        uint256 x,
        uint256 n,
        uint256 seed,
        uint256 rounds
    ) internal pure returns (uint256) {
        require(x < n, "Out of range");
        require(n > 0 && n <= (1 << BLOCK_BITS_14), "n too large");

        unchecked {
            uint256 y = x & BLOCK_MASK_14;

            while (true) {
                y =
                    _encryptGeneric(
                        y,
                        rounds,
                        seed,
                        L_BITS0_14,
                        R_BITS0_14,
                        L_MASK0_14,
                        R_MASK0_14
                    ) &
                    BLOCK_MASK_14;

                if (y < n) return y;
            }
        }
    }

    /// @notice Permutation on [0, n) for n ≤ 1024 (≈1K).
    function permute10(
        uint256 x,
        uint256 n,
        uint256 seed,
        uint256 rounds
    ) internal pure returns (uint256) {
        require(x < n, "Out of range");
        require(n > 0 && n <= (1 << BLOCK_BITS_10), "n too large");

        unchecked {
            uint256 y = x & BLOCK_MASK_10;
            while (true) {
                y =
                    _encryptGeneric(
                        y,
                        rounds,
                        seed,
                        L_BITS0_10,
                        R_BITS0_10,
                        L_MASK0_10,
                        R_MASK0_10
                    ) &
                    BLOCK_MASK_10;
                if (y < n) return y;
            }
        }
    }

    /// @notice Permutation on [0, n) for n ≤ 512 (≈500).
    function permute9(
        uint256 x,
        uint256 n,
        uint256 seed,
        uint256 rounds
    ) internal pure returns (uint256) {
        require(x < n, "Out of range");
        require(n > 0 && n <= (1 << BLOCK_BITS_9), "n too large");

        unchecked {
            uint256 y = x & BLOCK_MASK_9;
            while (true) {
                y =
                    _encryptGeneric(
                        y,
                        rounds,
                        seed,
                        L_BITS0_9,
                        R_BITS0_9,
                        L_MASK0_9,
                        R_MASK0_9
                    ) &
                    BLOCK_MASK_9;
                if (y < n) return y;
            }
        }
    }
}
