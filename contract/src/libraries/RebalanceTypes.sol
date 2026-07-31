// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library RebalanceTypes {
    /// @notice Basis point denominator used for weight configs.
    uint256 internal constant BPS = 10_000;

    /// @notice Desired final underlying allocation for one venue after rebalance.
    /// @dev `amount0` and `amount1` are final target amounts, not amounts to add in this transaction.
    struct RebalanceTarget {
        uint256 venueId;
        uint256 amount0;
        uint256 amount1;
        bytes params;
    }

    struct TargetConfig {
        uint256 venueId;
        uint256 weightBps;  // Venue weight in basis points.
        bytes params;       // Venue-specific adapter params.
    }

}