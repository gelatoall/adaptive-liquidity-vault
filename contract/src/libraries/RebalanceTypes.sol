// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library RebalanceTypes {
    /// @notice Basis point denominator used for weight configs.
    uint256 internal constant BPS = 10_000;

    /// @notice One desired venue allocation used by the rebalance entrypoint.
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