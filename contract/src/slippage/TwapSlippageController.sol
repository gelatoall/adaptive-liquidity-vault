// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "../interfaces/ISlippageController.sol";
import "../interfaces/IUniswapV3Pool.sol";
import "../libraries/RebalanceTypes.sol";
import "../libraries/V3TwapLib.sol";

/// @notice Computes min amounts and blocks execution when V3 spot price deviates too far from TWAP.
contract TwapSlippageController is ISlippageController, Ownable {
    /// @notice V3 pool expected for each target venue id.
    mapping(uint256 => address) public venuePools;

    /// @notice Emitted when a venue id is bound to a V3 pool for TWAP validation.
    event SetVenuePool(uint256 indexed venueId, address indexed pool);

    error InvalidBps();
    error ZeroAddress();
    error ExcessiveTwapDeviation();
    error VenuePoolNotSet();
    error InvalidVenuePool();

    constructor() Ownable(msg.sender) {}

    /// @notice Binds a venue id to the V3 pool used for spot/TWAP validation.
    function setVenuePool(uint256 venueId, address pool) external onlyOwner {
        if (pool == address(0)) revert ZeroAddress();

        venuePools[venueId] = pool;
        emit SetVenuePool(venueId, pool);
    }

    /// @inheritdoc ISlippageController
    function calculateMinAmounts(
        uint256 targetVenueId, 
        uint256 amount0, 
        uint256 amount1,
        SlippageParams calldata params
    ) external view returns (uint256 minAmount0, uint256 minAmount1) {
        if (params.maxSlippageBps > RebalanceTypes.BPS) revert InvalidBps();
        
        address expectedPool = venuePools[targetVenueId];
        if (expectedPool == address(0)) revert VenuePoolNotSet();
        if (params.pool != expectedPool) revert InvalidVenuePool();
        IUniswapV3Pool pool = IUniswapV3Pool(expectedPool);

        uint256 spotPrice = V3TwapLib.getSpotPrice(pool);
        uint256 twapPrice = V3TwapLib.getTwapPrice(pool, params.twapWindow);
        uint256 volatilityBps = V3TwapLib.getDeviationBps(spotPrice, twapPrice);
        if (volatilityBps > params.maxSlippageBps) revert ExcessiveTwapDeviation();

        minAmount0 = _applySlippage(amount0, params.maxSlippageBps);
        minAmount1 = _applySlippage(amount1, params.maxSlippageBps);
    }

    function _applySlippage(uint256 amount, uint256 maxSlippageBps) internal pure returns (uint256 minAmount) {
        minAmount = amount * (RebalanceTypes.BPS - maxSlippageBps) / RebalanceTypes.BPS;
    }
}
