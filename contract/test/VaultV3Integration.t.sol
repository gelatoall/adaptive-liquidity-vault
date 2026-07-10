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
import "../test/helpers/VenueTestHelper.sol";

/// @title VaultV3IntegrationTest
/// @notice Integration tests for `AdaptiveLPVault` wired to `UniswapV3Adapter`.
contract VaultV3IntegrationTest is Test, VaultTestHelper, VenueTestHelper {
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
        uint256 liquidity = _deployVaultToV3(vault, token0, token1, pool, positionManager, 
                                V3_LOW_VENUE_ID, tickLower, tickUpper, amount0, amount1);
        
        assertEq(vault.totalLiquidity(), liquidity);

        assertTrue(adapter.hasPosition());
        assertEq(adapter.tokenId(), 1);

        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token1.balanceOf(address(vault)), 0);
        // Note：真实情况token是在pool里面，这里只是简化了Mock
        assertEq(token0.balanceOf(address(positionManager)), amount0);
    }
    
    /// @notice Verifies deployed V3 funds and explicit fees can be withdrawn back to the vault.
    function test_WithdrawFromVenue_ReturnsFundsAndCollectsFeesFromV3() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 2000e6;
        uint256 fee0 = 0.1 ether;
        uint256 fee1 = 200e6;
        
        // user -> vault
        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);

        // vault -> pool
        uint256 deployedLiquidity = _deployVaultToV3(vault, token0, token1, pool, positionManager, 
                                V3_LOW_VENUE_ID, tickLower, tickUpper, amount0, amount1);

        assertEq(vault.totalLiquidity(), deployedLiquidity);
        assertTrue(adapter.hasPosition());
        assertEq(adapter.tokenId(), 1);

        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token1.balanceOf(address(vault)), 0);

        (uint256 poolAmount0Desired, uint256 poolAmount1Desired) = _mapPoolAmounts(token0, token1, amount0, amount1);
        positionManager.setNextDecreaseResult(poolAmount0Desired, poolAmount1Desired);

        (uint256 feePool0, uint256 feePool1) = _mapPoolAmounts(token0, token1, fee0, fee1);
        positionManager.addFees(adapter.tokenId(), uint128(feePool0), uint128(feePool1));

        (uint256 amount0Out, uint256 amount1Out) = vault.withdrawFromVenue(V3_LOW_VENUE_ID, deployedLiquidity, "");

        assertEq(amount0Out, amount0);
        assertEq(amount1Out, amount1);
        assertFalse(adapter.hasPosition());
        assertEq(adapter.tokenId(), 0);

        assertEq(token0.balanceOf(address(vault)), amount0 + fee0);
        assertEq(token1.balanceOf(address(vault)), amount1 + fee1);
    }

    /// @notice Verifies full redeem withdraws all active V3 liquidity and forwards withdrawal params.
    function test_Redeem_FullyWithdrawsActiveV3Position() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 2000e6;

        uint256 amount0Min = amount0 / 2;
        uint256 amount1Min = amount1 / 2;
        uint256 deadline = block.timestamp + 1 hours;
        AdaptiveLPVault.VenueWithdrawalParams[] memory withdrawalParams =
                new AdaptiveLPVault.VenueWithdrawalParams[](1);
        withdrawalParams[0] = AdaptiveLPVault.VenueWithdrawalParams({
            venueId: V3_LOW_VENUE_ID,
            params: _v3Params(amount0Min, amount1Min, deadline, tickLower, tickUpper)
        });

        // user -> vault
        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);
       
        // vault -> pool
        _deployVaultToV3(vault, token0, token1, pool, positionManager, 
                        V3_LOW_VENUE_ID, tickLower, tickUpper, amount0, amount1);

        assertTrue(adapter.hasPosition());
        assertEq(adapter.tokenId(), 1);
        
        (uint256 poolAmount0Out, uint256 poolAmount1Out) = _mapPoolAmounts(token0, token1, amount0, amount1);
        (uint256 poolAmount0Min, uint256 poolAmount1Min) = _mapPoolAmounts(token0, token1, amount0Min, amount1Min);

        positionManager.setNextDecreaseResult(poolAmount0Out, poolAmount1Out);
        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        (uint256 redeemAmount0, uint256 redeemAmount1) = vault.redeem(aliceShares, alice, alice, withdrawalParams);

        assertEq(redeemAmount0, amount0);
        assertEq(redeemAmount1, amount1);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.venueLiquidity(V3_LOW_VENUE_ID), 0);
        assertEq(vault.totalLiquidity(), 0);
        assertFalse(adapter.hasPosition());
        assertEq(adapter.tokenId(), 0);

        assertEq(positionManager.lastDecreaseAmount0Min(), poolAmount0Min);
        assertEq(positionManager.lastDecreaseAmount1Min(), poolAmount1Min);
        assertEq(positionManager.lastDecreaseDeadline(), deadline);
    }

    /// @notice Verifies partial redeem withdraws only the caller's pro-rata active V3 liquidity.
    function test_Redeem_PartiallyWithdrawsActiveV3Position() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 2000e6;

        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);
        _mintAndDeposit(token0, token1, vault, bob, amount0, amount1);
        uint256 aliceShares = vault.balanceOf(alice);
        uint256 bobShares = vault.balanceOf(bob);
        uint256 totalSharesBefore = vault.totalSupply();
        assertEq(aliceShares, bobShares);
        assertEq(totalSharesBefore, aliceShares + bobShares);

        uint256 totalAmount0 = 2 ether;
        uint256 totalAmount1 = 4000e6;
        uint256 deployedLiquidity = _deployVaultToV3(vault, token0, token1, pool, positionManager, 
                                V3_LOW_VENUE_ID, tickLower, tickUpper, totalAmount0, totalAmount1);
        assertEq(vault.venueLiquidity(V3_LOW_VENUE_ID), deployedLiquidity);
        assertEq(vault.totalLiquidity(), deployedLiquidity);
        assertTrue(adapter.hasPosition());
        assertEq(adapter.tokenId(), 1);

        (uint256 poolAmount0Out, uint256 poolAmount1Out) = _mapPoolAmounts(token0, token1, amount0, amount1);
        positionManager.setNextDecreaseResult(poolAmount0Out, poolAmount1Out);

        vm.prank(alice);
        (uint256 redeemAmount0, uint256 redeemAmount1) = vault.redeem(aliceShares, alice, alice, _emptyWithdrawalParams());

        assertEq(redeemAmount0, amount0);
        assertEq(redeemAmount1, amount1);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(bob), bobShares);
        assertEq(vault.totalSupply(), bobShares);
        assertEq(vault.venueLiquidity(V3_LOW_VENUE_ID), deployedLiquidity / 2);
        assertEq(vault.totalLiquidity(), deployedLiquidity / 2);
        assertTrue(adapter.hasPosition());
        assertEq(adapter.tokenId(), 1);

        (,,,,,,, uint128 remainingLiquidity,,,,) = positionManager.positions(adapter.tokenId());
        assertEq(uint256(remainingLiquidity), deployedLiquidity / 2);
    }

    /// @notice Verifies vault totalAssets includes the deployed V3 position value.
    function test_TotalAssets_IncludesV3PositionValue() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 2000e6;
        
        // user -> vault
        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);

        // vault -> pool
        _deployVaultToV3(vault, token0, token1, pool, positionManager, 
                        V3_LOW_VENUE_ID, tickLower, tickUpper, amount0, amount1);

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
        uint256 liquidity = _deployVaultToV3(vault, token0, token1, pool, positionManager, 
                                V3_LOW_VENUE_ID, tickLower, tickUpper, amount0, amount1);

        (uint256 feePool0, uint256 feePool1) = _mapPoolAmounts(token0, token1, fee0, fee1);
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
