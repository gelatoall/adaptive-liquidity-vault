// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../src/interfaces/IRebalanceStrategy.sol";
import "../../src/libraries/RebalanceTypes.sol";

/// @notice Test strategy that returns preset rebalance targets.
contract MockRebalanceStrategy is IRebalanceStrategy {
    RebalanceTypes.RebalanceTarget[] internal targets;

    /// @notice Stores one target to be returned by `buildTargets`.
    function setSingleTarget(uint256 _venueId, uint256 _amount0, uint256 _amount1, bytes calldata _params) external {
        delete targets;

        targets.push(RebalanceTypes.RebalanceTarget({
            venueId: _venueId,
            amount0: _amount0,
            amount1: _amount1,
            params: _params
        }));
    }

    /// @notice Stores two targets to be returned by `buildTargets`.
    function setTwoTargets(
        uint256 _venueId0, 
        uint256 _amount0Venue0, 
        uint256 _amount1Venue0, 
        bytes calldata _params0,
        uint256 _venueId1, 
        uint256 _amount0Venue1, 
        uint256 _amount1Venue1, 
        bytes calldata _params1
    ) external {
        delete targets;

        targets.push(RebalanceTypes.RebalanceTarget({
            venueId: _venueId0,
            amount0: _amount0Venue0,
            amount1: _amount1Venue0,
            params: _params0
        }));

        targets.push(RebalanceTypes.RebalanceTarget({
            venueId: _venueId1,
            amount0: _amount0Venue1,
            amount1: _amount1Venue1,
            params: _params1
        }));
    }

    /// @notice Clears all preset targets.
    function clearTargets() external {
        delete targets;
    }

    /// @notice Returns a memory copy of the preset targets.
    function buildTargets(address, bytes calldata) external view returns (
        RebalanceTypes.RebalanceTarget[] memory result
    ) {
        result = new RebalanceTypes.RebalanceTarget[](targets.length);

        for (uint256 i = 0; i < targets.length; i++) {
            result[i] = targets[i];
        }
    }
}
