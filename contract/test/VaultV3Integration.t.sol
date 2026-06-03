// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/AdaptiveLPVault.sol";
import "../src/adapters/UniswapV3Adapter.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockPriceOracle.sol";
import "./mocks/MockUniswapV3Pool.sol";
import "./mocks/MockNonfungiblePositionManager.sol";
import "../src/libraries/v3/TickMath.sol";
import "../src/libraries/v3/LiquidityAmounts.sol";
import "../test/helpers/VaultTestHelper.sol";

/// @title VaultV3IntegrationTest
/// @notice Integration tests for `AdaptiveLPVault` wired to `UniswapV3Adapter`.
contract VaultV3IntegrationTest is Test, VaultTestHelper {
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
    function _deployIdleVaultToV3(uint256 amount0, uint256 amount1) internal returns (uint256 liquidity) {
        (uint256 poolAmount0Desired, uint256 poolAmount1Desired) = _mapPoolAmounts(amount0, amount1);

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

        liquidity = vault.deployToVenue(
            amount0,
            amount1,
            abi.encode(0, 0, block.timestamp + 1)
        );

        assertEq(liquidity, liquidityMinted);
        assertEq(vault.totalLiquidity(), liquidityMinted);
    }


    /// @notice Maps vault-ordered amounts to pool-ordered amounts.
    function _mapPoolAmounts(uint256 vaultAmount0, uint256 vaultAmount1) internal view 
        returns (uint256 poolAmount0, uint256 poolAmount1) 
    {
        if (address(token0) < address(token1)) {
            return (vaultAmount0, vaultAmount1);
        } else {
            return (vaultAmount1, vaultAmount0);
        }
    }


    /// @notice Verifies the vault is wired to the configured V3 adapter.
    function test_SetAdapter_SetsV3AdapterCorrectly() public {
        assertEq(address(vault.adapter()), address(adapter));
    }

    /// @notice Verifies idle vault funds can be deployed into V3.
    function test_DeployToVenue_DeploysIdleFundsIntoV3() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 2000e6;
        
        // user -> vault
        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);
        assertEq(token0.balanceOf(address(vault)), amount0);
        assertEq(token1.balanceOf(address(vault)), amount1);

        // vault -> pool
        uint256 liquidity = _deployIdleVaultToV3(amount0, amount1);
        
        assertEq(vault.totalLiquidity(), liquidity);

        assertTrue(adapter.hasPosition());
        assertEq(adapter.tokenId(), 1);

        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token1.balanceOf(address(vault)), 0);
        // Note：真实情况token是在pool里面，这里只是简化了Mock
        assertEq(token0.balanceOf(address(positionManager)), amount0);
    }
    
    /// @notice Verifies deployed V3 funds can be withdrawn back to the vault.
    function test_WithdrawFromVenue_ReturnsFundsFromV3() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 2000e6;
        
        // user -> vault
        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);

        // vault -> pool
        uint256 deployedLiquidity = _deployIdleVaultToV3(amount0, amount1);

        assertEq(vault.totalLiquidity(), deployedLiquidity);
        assertTrue(adapter.hasPosition());
        assertEq(adapter.tokenId(), 1);

        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token1.balanceOf(address(vault)), 0);

        (uint256 poolAmount0Desired, uint256 poolAmount1Desired) = _mapPoolAmounts(amount0, amount1);
        positionManager.setNextDecreaseResult(poolAmount0Desired, poolAmount1Desired);
        (uint256 amount0Out, uint256 amount1Out) =vault.withdrawFromVenue(deployedLiquidity);

        assertEq(amount0Out, amount0);
        assertEq(amount1Out, amount1);
        assertFalse(adapter.hasPosition());
        assertEq(adapter.tokenId(), 0);

        assertEq(token0.balanceOf(address(vault)), amount0);
        assertEq(token1.balanceOf(address(vault)), amount1);
    }

    /// @notice Verifies redemption is blocked while V3 liquidity is still deployed.
    function test_Redeem_RevertsWhenV3PositionIsActive() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 2000e6;
        
        // user -> vault
        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);
       
        // vault -> pool
        _deployIdleVaultToV3(amount0, amount1);

        assertTrue(adapter.hasPosition());
        assertEq(adapter.tokenId(), 1);

        uint256 aliceShares = vault.balanceOf(alice);

        vm.expectRevert(AdaptiveLPVault.ActivePositionExists.selector);
        vm.prank(alice);
        vault.redeem(aliceShares);
    }

    /// @notice Verifies redemption works again after V3 liquidity is withdrawn.
    function test_Redeem_WorksAfterWithdrawFromV3() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 2000e6;
        
        // user -> vault
        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);
       uint256 aliceShares = vault.balanceOf(alice);

        // vault -> pool
        uint256 liquidityMinted = _deployIdleVaultToV3(amount0, amount1);

        assertTrue(adapter.hasPosition());
        assertEq(adapter.tokenId(), 1);

        vm.expectRevert(AdaptiveLPVault.ActivePositionExists.selector);
        vm.prank(alice);
        vault.redeem(aliceShares);

        (uint256 poolAmount0Out, uint256 poolAmount1Out) = _mapPoolAmounts(amount0, amount1);
        positionManager.setNextDecreaseResult(poolAmount0Out, poolAmount1Out);
        vault.withdrawFromVenue(liquidityMinted);
        assertFalse(adapter.hasPosition());
        assertEq(adapter.tokenId(), 0);

        vm.prank(alice);
        (uint256 redeemAmount0, uint256 redeemAmount1) = vault.redeem(aliceShares);
        assertEq(redeemAmount0, amount0);
        assertEq(redeemAmount1, amount1);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.totalSupply(), 0);
    }

    /// @notice Verifies vault totalAssets includes the deployed V3 position value.
    function test_TotalAssets_IncludesV3PositionValue() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 2000e6;
        
        // user -> vault
        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);

        // vault -> pool
        _deployIdleVaultToV3(amount0, amount1);

        (uint256 price0, uint256 price1) = oracle.getPrices();
        
        (uint256 deployed0, uint256 deployed1) = adapter.getPositionValue();
        uint256 expectedTotalAssets = VaultMath.getAssetsTotalValue(
            token0.balanceOf(address(vault)) + deployed0, // vault + adapter
            price0, 
            decimals0, 
            token1.balanceOf(address(vault)) + deployed1, 
            price1, 
            decimals1
        );

        assertEq(vault.totalAssets(), expectedTotalAssets);
    }

    /// @notice Tests that collected Uniswap V3 fees are correctly transferred back to the vault.
    function test_CollectFees_ReturnsFeesToVault() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 2000e6;
        uint256 fee0 = 0.1 ether;
        uint256 fee1 = 200e6;

        // user -> vault
        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);

        // vault -> pool
        uint256 liquidity = _deployIdleVaultToV3(amount0, amount1);

        (uint256 feePool0, uint256 feePool1) = _mapPoolAmounts(fee0, fee1);
        positionManager.addFees(adapter.tokenId(), uint128(feePool0), uint128(feePool1));

        uint256 vault0Before = token0.balanceOf(address(vault));
        uint256 vault1Before = token1.balanceOf(address(vault));

        vm.prank(address(vault));
        (uint256 collected0, uint256 collected1) = adapter.collectFees();
        assertEq(collected0, fee0);
        assertEq(collected1, fee1);

        assertEq(token0.balanceOf(address(vault)), vault0Before + fee0);
        assertEq(token1.balanceOf(address(vault)), vault1Before + fee1);
        
        assertEq(vault.totalLiquidity(), liquidity);
        assertTrue(adapter.hasPosition());
    }
}
