// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../src/AdaptiveLPVault.sol";

abstract contract RebalanceTestHelper is Test {
    function _rebalanceToIdle(AdaptiveLPVault vault) internal {
        AdaptiveLPVault.RebalanceTarget[] memory targets = new AdaptiveLPVault.RebalanceTarget[](0);
        vault.rebalance(targets);
    }

    function _buildSingleTarget(
        uint256 venueId,
        uint256 amount0,
        uint256 amount1,
        bytes memory params
    ) internal pure returns (AdaptiveLPVault.RebalanceTarget[] memory targets) {
        targets = new AdaptiveLPVault.RebalanceTarget[](1);
        targets[0] = AdaptiveLPVault.RebalanceTarget({
            venueId: venueId,
            amount0: amount0,
            amount1: amount1,
            params: params
        });
    }

    function _buildTwoTargets(
        uint256 venueId0,
        uint256 amount00,
        uint256 amount01,
        bytes memory params0,
        uint256 venueId1,
        uint256 amount10,
        uint256 amount11,
        bytes memory params1
    ) internal pure returns (AdaptiveLPVault.RebalanceTarget[] memory targets) {
        targets = new AdaptiveLPVault.RebalanceTarget[](2);

        targets[0] = AdaptiveLPVault.RebalanceTarget({
            venueId: venueId0,
            amount0: amount00,
            amount1: amount01,
            params: params0
        });

        targets[1] = AdaptiveLPVault.RebalanceTarget({
            venueId: venueId1,
            amount0: amount10,
            amount1: amount11,
            params: params1
        });
    }

    function _rebalanceToVenue(
        AdaptiveLPVault vault,
        uint256 venueId,
        uint256 amount0,
        uint256 amount1,
        bytes memory params
    ) internal {
        vault.rebalance(_buildSingleTarget(venueId, amount0, amount1, params));
    }
}