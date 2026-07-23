// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/AdaptiveLPVault.sol";
import "../src/adapters/UniswapV3Adapter.sol";
import "../src/valuators/V3TwapPositionValuator.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockPriceOracle.sol";
import "./mocks/MockUniswapV3Pool.sol";
import "./mocks/MockNonfungiblePositionManager.sol";
import "./helpers/VaultTestHelper.sol";
import "./helpers/VenueTestHelper.sol";
import "./helpers/RebalanceTestHelper.sol";

/// @title RebalanceV3Test
/// @notice Rebalance-focused tests for the minimal single-venue V3 vault strategy.
contract RebalanceV3Test is Test, VaultTestHelper, VenueTestHelper, RebalanceTestHelper {
    MockERC20 public token0;
    MockERC20 public token1;
    AdaptiveLPVault public vault;

    MockPriceOracle public oracle;
    
    MockUniswapV3Pool public pool;
    MockNonfungiblePositionManager public positionManager;
    UniswapV3Adapter public adapter;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint8 public decimals0 = 18;
    uint8 public decimals1 = 6;
    uint24 public fee = 3000;
    int24 public tickLower = -600;
    int24 public tickUpper = 600;

    /// @notice Deploys the vault, oracle, pool, position manager, and V3 adapter fixture.
    function setUp() public {
        // deploy token0/token1
        token0 = new MockERC20("token0", "T0", decimals0);
        token1 = new MockERC20("token1", "T1", decimals1);

        // deploy vault
        vault = new AdaptiveLPVault(
            "Adaptive LP Vault", "ALPV", 
            address(token0), address(token1), 
            decimals0, decimals1
        );

        // deploy oracle
        oracle = new MockPriceOracle();
        vault.setPriceOracle(address(oracle));
        oracle.setPrices(1e18, 1e18);

        // deploy pool/positionManager/V3adapter
        pool = new MockUniswapV3Pool(address(token0), address(token1), fee);
        pool.setSlot0FromTick(0);

        positionManager = new MockNonfungiblePositionManager();
        
        adapter = new UniswapV3Adapter(
            address(vault), 
            address(token0),
            address(token1),
            address(positionManager),
            address(pool),
            tickLower,
            tickUpper
        );

        // set V3 adapter into vault
        vault.setVenue(V3_LOW_VENUE_ID, address(adapter), V3_LOW_LABEL, true);

        V3TwapPositionValuator valuator = new V3TwapPositionValuator(address(adapter), 1800);
        vault.setVenueValuator(V3_LOW_VENUE_ID, address(valuator));
    }

    /// @notice Verifies rebalance moves all idle balances into V3.
    function test_Rebalance_IdleToV3_DeploysAllIdleBalances() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 2000e6;

        // user -> vault
        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);
        // vault -> adapter
        _primeV3Mint(token0, token1, pool, positionManager, tickLower, tickUpper, amount0, amount1);
        _rebalanceToVenue(vault, V3_LOW_VENUE_ID, amount0, amount1, _defaultV3Params(tickLower, tickUpper));

        assertTrue(adapter.hasPosition());
        assertEq(adapter.tokenId(), 1);

        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token1.balanceOf(address(vault)), 0);
        // Note：真实情况token是在pool里面，这里只是简化了Mock
        assertEq(token0.balanceOf(address(positionManager)), amount0);
        assertEq(token1.balanceOf(address(positionManager)), amount1);
    }
    
    /// @notice Verifies rebalance to IDLE withdraws all deployed liquidity from V3.
    function test_Rebalance_V3ToIdle_WithdrawsAllLiquidity() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 2000e6;

        // user -> vault
        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);
        // vault -> adapter
        _primeV3Mint(token0, token1, pool, positionManager, tickLower, tickUpper, amount0, amount1);
        _rebalanceToVenue(vault, V3_LOW_VENUE_ID, amount0, amount1, _defaultV3Params(tickLower, tickUpper));

        assertTrue(adapter.hasPosition());
        assertEq(adapter.tokenId(), 1);
        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token1.balanceOf(address(vault)), 0);
        // Note：真实情况token是在pool里面，这里只是简化了Mock
        assertEq(token0.balanceOf(address(positionManager)), amount0);
        assertEq(token1.balanceOf(address(positionManager)), amount1);

        uint256 amount0Min = amount0 / 2;
        uint256 amount1Min = amount1 / 2;
        uint256 deadline = block.timestamp + 1 hours;
        AdaptiveLPVault.VenueWithdrawalParams[] memory withdrawalParams = new AdaptiveLPVault.VenueWithdrawalParams[](1);
        withdrawalParams[0] = AdaptiveLPVault.VenueWithdrawalParams({
            venueId: V3_LOW_VENUE_ID,
            params: _v3Params(amount0Min, amount1Min, deadline, tickLower, tickUpper)
        });

        (uint256 poolAmount0Out, uint256 poolAmount1Out) = _mapPoolAmounts(token0, token1, amount0, amount1);
        (uint256 poolAmount0Min, uint256 poolAmount1Min) = _mapPoolAmounts(token0, token1, amount0Min, amount1Min);
        positionManager.setNextDecreaseResult(poolAmount0Out, poolAmount1Out);
        RebalanceTypes.RebalanceTarget[] memory targets = new RebalanceTypes.RebalanceTarget[](0);
        vault.rebalance(targets, withdrawalParams);

        assertFalse(adapter.hasPosition());
        assertEq(adapter.tokenId(), 0);

        assertEq(token0.balanceOf(address(vault)), amount0);
        assertEq(token1.balanceOf(address(vault)), amount1);
        assertEq(token0.balanceOf(address(positionManager)), 0);
        assertEq(token1.balanceOf(address(positionManager)), 0);

        assertEq(positionManager.lastDecreaseAmount0Min(), poolAmount0Min);
        assertEq(positionManager.lastDecreaseAmount1Min(), poolAmount1Min);
        assertEq(positionManager.lastDecreaseDeadline(), deadline);
    }
}
