// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "../interfaces/ISlippageController.sol";
import "../interfaces/IUniswapV3Pool.sol";
import "../libraries/RebalanceTypes.sol";
import "../libraries/V3TwapLib.sol";
import "../adapters/UniswapV3Adapter.sol";

/// @notice Computes min amounts and blocks execution when V3 spot price deviates too far from TWAP.
contract TwapSlippageController is ISlippageController, Ownable2Step {
    /// @notice V3 adapter configured for each venue id.
    mapping(uint256 => address) public override venueAdapters;

    /// @notice Emitted when a venue is bound to its V3 adapter and validation pool.
    event SetVenueAdapter(
        uint256 indexed venueId,
        address indexed adapter,
        address indexed pool
    );

    error InvalidBps();
    error ZeroAddress();
    error ExcessiveTwapDeviation();
    error InvalidVenueAdapter();
    error VenueAdapterNotSet();

    constructor() Ownable(msg.sender) {}

    /// @notice Binds a venue id to the V3 adapter used for spot/TWAP validation.
    /// @dev Reads the validation pool from the adapter instead of accepting a caller-supplied pool.
    function setVenueAdapter(uint256 venueId, address adapter) external onlyOwner {
        if (adapter == address(0)) revert ZeroAddress();

        IUniswapV3Pool pool;
        try UniswapV3Adapter(adapter).pool() returns (IUniswapV3Pool adapterPool) {
            pool = adapterPool;
        } catch {
            revert InvalidVenueAdapter();
        }

        if (address(pool) == address(0)) {
            revert InvalidVenueAdapter();
        }

        venueAdapters[venueId] = adapter;
        emit SetVenueAdapter(venueId, adapter, address(pool));
    }

    /// @inheritdoc ISlippageController
    function calculateMinAmounts(
        uint256 targetVenueId, 
        uint256 amount0, 
        uint256 amount1,
        SlippageParams calldata params
    ) external view returns (uint256 minAmount0, uint256 minAmount1) {
        if (params.maxSlippageBps > RebalanceTypes.BPS) revert InvalidBps();

        address adapter = venueAdapters[targetVenueId];
        if (adapter == address(0)) {
            revert VenueAdapterNotSet();
        }
        IUniswapV3Pool pool = UniswapV3Adapter(adapter).pool();

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
