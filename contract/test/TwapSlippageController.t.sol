// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../src/interfaces/ISlippageController.sol";
import "../src/slippage/TwapSlippageController.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockUniswapV3Pool.sol";
import "./helpers/VenueTestHelper.sol";

contract TwapSlippageControllerTest is Test, VenueTestHelper {
    uint32 internal constant TWAP_WINDOW = 1800;

    MockERC20 public token0;
    MockERC20 public token1;
    MockUniswapV3Pool public pool;
    TwapSlippageController public slippageController;

    function setUp() public {
        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("token1", "TK1", 6);
        uint24 feeTier = 3000;  // 0.30% fee
        pool = new MockUniswapV3Pool(address(token0), address(token1), feeTier);
        slippageController = new TwapSlippageController();
        slippageController.setVenuePool(V3_LOW_VENUE_ID, address(pool));
        vm.warp(TWAP_WINDOW);
    }

    function _slippageParams(uint256 _maxSlippageBps) internal view returns (ISlippageController.SlippageParams memory){
        return ISlippageController.SlippageParams({
            maxSlippageBps: _maxSlippageBps,      
            twapWindow: TWAP_WINDOW,
            pool: address(pool)
        });
    }

    /// @notice Stable spot/TWAP market returns min amounts after applying the configured bps haircut.
    function test_CalculateMinAmounts_ReturnsHaircutWhenSpotEqualsTwap() public {
        pool.setTwapTick(0);
        pool.setSlot0FromTick(0);

        uint256 maxSlippageBps = 50;
        (uint256 min0, uint256 min1) = slippageController.calculateMinAmounts(
            V3_LOW_VENUE_ID, 100 ether, 20_000e6, _slippageParams(maxSlippageBps));

        assertEq(min0, 99.5 ether);
        assertEq(min1, 19_900e6);    
    }

    /// @notice A large spot-vs-TWAP deviation blocks min amount calculation.
    function test_CalculateMinAmounts_RevertsWhenTwapDeviationExceedsLimit() public {
        pool.setTwapTick(0);
        pool.setSlot0FromTick(1000);

        vm.expectRevert(TwapSlippageController.ExcessiveTwapDeviation.selector);
        slippageController.calculateMinAmounts(V3_LOW_VENUE_ID, 100 ether, 20_000e6, _slippageParams(50));
    }

    /// @notice The target venue id must match the pool used for TWAP validation.
    function test_CalculateMinAmounts_RevertsWhenPoolDoesNotMatchVenue() public {
        MockUniswapV3Pool otherPool = new MockUniswapV3Pool(address(token0), address(token1), 500);
        ISlippageController.SlippageParams memory otherParams = ISlippageController.SlippageParams({
            maxSlippageBps: 50,      
            twapWindow: TWAP_WINDOW,
            pool: address(otherPool)
        });

        vm.expectRevert(TwapSlippageController.InvalidVenuePool.selector);
        slippageController.calculateMinAmounts(V3_LOW_VENUE_ID, 100 ether, 20_000e6, otherParams);
    }

    function test_CalculateMinAmounts_RevertsWhenBpsExceedsMax() public {
        vm.expectRevert(TwapSlippageController.InvalidBps.selector);

        slippageController.calculateMinAmounts(
            V3_LOW_VENUE_ID,
            100 ether,
            20_000e6,
            _slippageParams(10_001)
        );
    }
}
