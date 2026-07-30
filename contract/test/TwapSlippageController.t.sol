// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/interfaces/ISlippageController.sol";
import "../src/slippage/TwapSlippageController.sol";
import "../src/adapters/UniswapV3Adapter.sol";
import "./mocks/MockNonfungiblePositionManager.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockUniswapV3Pool.sol";
import "./helpers/VenueTestHelper.sol";

contract TwapSlippageControllerTest is Test, VenueTestHelper {
    uint32 internal constant TWAP_WINDOW = 1800;

    MockERC20 public token0;
    MockERC20 public token1;
    MockUniswapV3Pool public pool;
    TwapSlippageController public slippageController;
    MockNonfungiblePositionManager public positionManager;
    UniswapV3Adapter public adapter;

    function setUp() public {
        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("token1", "TK1", 6);
        uint24 feeTier = 3000;  // 0.30% fee
        pool = new MockUniswapV3Pool(address(token0), address(token1), feeTier);
        positionManager = new MockNonfungiblePositionManager();
        adapter = new UniswapV3Adapter(
            address(this),
            address(token0),
            address(token1),
            address(positionManager),
            address(pool),
            -600,
            600
        );

        slippageController = new TwapSlippageController();
        slippageController.setVenueAdapter(V3_LOW_VENUE_ID, address(adapter));
        vm.warp(TWAP_WINDOW);
    }

    function _slippageParams(uint256 _maxSlippageBps) internal view returns (ISlippageController.SlippageParams memory){
        return ISlippageController.SlippageParams({
            maxSlippageBps: _maxSlippageBps,      
            twapWindow: TWAP_WINDOW
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

    /// @notice A venue without a bound V3 adapter cannot request TWAP-validated minimum amounts.
    function test_CalculateMinAmounts_RevertsWhenVenueAdapterNotSet() public {
        vm.expectRevert(TwapSlippageController.VenueAdapterNotSet.selector);
        slippageController.calculateMinAmounts(V3_MID_VENUE_ID, 100 ether, 20_000e6, _slippageParams(50));
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
