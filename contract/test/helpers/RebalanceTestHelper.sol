// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../src/AdaptiveLPVault.sol";
import "../../src/libraries/RebalanceTypes.sol";

abstract contract RebalanceTestHelper is Test {
    function _rebalanceToIdle(AdaptiveLPVault vault) internal {
        RebalanceTypes.RebalanceTarget[] memory targets = new RebalanceTypes.RebalanceTarget[](0);
        vault.rebalance(targets);
    }

    function _buildSingleTarget(
        uint256 venueId,
        uint256 amount0,
        uint256 amount1,
        bytes memory params
    ) internal pure returns (RebalanceTypes.RebalanceTarget[] memory targets) {
        targets = new RebalanceTypes.RebalanceTarget[](1);
        targets[0] = RebalanceTypes.RebalanceTarget({
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
    ) internal pure returns (RebalanceTypes.RebalanceTarget[] memory targets) {
        targets = new RebalanceTypes.RebalanceTarget[](2);

        targets[0] = RebalanceTypes.RebalanceTarget({
            venueId: venueId0,
            amount0: amount00,
            amount1: amount01,
            params: params0
        });

        targets[1] = RebalanceTypes.RebalanceTarget({
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