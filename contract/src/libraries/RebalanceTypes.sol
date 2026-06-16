// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library RebalanceTypes {
    /// @notice One desired venue allocation used by the rebalance entrypoint.
    struct RebalanceTarget {
        uint256 venueId;
        uint256 amount0;
        uint256 amount1;
        bytes params;
    }
}