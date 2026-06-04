// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/AdaptiveLPVault.sol";
import "../src/adapters/UniswapV3Adapter.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockPriceOracle.sol";
import "./mocks/MockUniswapV3Pool.sol";
import "./mocks/MockNonfungiblePositionManager.sol";
import "./helpers/VaultTestHelper.sol";
import "./helpers/V3TestHelper.sol";

/// @title RebalanceV3Test
/// @notice Rebalance-focused tests for the minimal single-venue V3 vault strategy.
contract RebalanceV3Test is Test, VaultTestHelper, V3TestHelper {
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
        vault.setOracle(address(oracle));
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
        vault.setAdapter(address(adapter));
    }

    /// @notice Deploys idle vault funds into the configured V3 adapter.
    function _deployIdleVaultToV3(uint256 amount0, uint256 amount1) internal {
        (uint256 poolAmount0Desired, uint256 poolAmount1Desired) = _mapPoolAmounts(token0, token1, amount0, amount1);

        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        uint160 sqrtRatioLowerX96 = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioUpperX96 = TickMath.getSqrtRatioAtTick(tickUpper);

        uint128 liquidityMinted = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtRatioLowerX96,
            sqrtRatioUpperX96,
            poolAmount0Desired,
            poolAmount1Desired
        );

        positionManager.setNextMintResult(liquidityMinted, poolAmount0Desired, poolAmount1Desired);

        vault.rebalance(AdaptiveLPVault.Venue.DEPLOYED_V3);
    }
    
    /// @notice Verifies rebalance moves all idle balances into V3.
    function test_Rebalance_IdleToV3_DeploysAllIdleBalances() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 2000e6;

        // user -> vault
        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);
        // vault -> adapter
        _deployIdleVaultToV3(amount0, amount1);

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
        _deployIdleVaultToV3(amount0, amount1);
        assertTrue(adapter.hasPosition());
        assertEq(adapter.tokenId(), 1);
        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token1.balanceOf(address(vault)), 0);
        // Note：真实情况token是在pool里面，这里只是简化了Mock
        assertEq(token0.balanceOf(address(positionManager)), amount0);
        assertEq(token1.balanceOf(address(positionManager)), amount1);

        (uint256 poolAmount0Out, uint256 poolAmount1Out) = _mapPoolAmounts(token0, token1, amount0, amount1);
        positionManager.setNextDecreaseResult(poolAmount0Out, poolAmount1Out);
        vault.rebalance(AdaptiveLPVault.Venue.IDLE);

        assertFalse(adapter.hasPosition());
        assertEq(adapter.tokenId(), 0);

        assertEq(token0.balanceOf(address(vault)), amount0);
        assertEq(token1.balanceOf(address(vault)), amount1);
        assertEq(token0.balanceOf(address(positionManager)), 0);
        assertEq(token1.balanceOf(address(positionManager)), 0);
    }
}