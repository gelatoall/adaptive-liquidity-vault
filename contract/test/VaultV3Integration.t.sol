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

        assertEq(amount0Out, amount0 + fee0);
        assertEq(amount1Out, amount1 + fee1);
        assertFalse(adapter.hasPosition());
        assertEq(adapter.tokenId(), 0);

        assertEq(token0.balanceOf(address(vault)), amount0 + fee0);
        assertEq(token1.balanceOf(address(vault)), amount1 + fee1);
    }

    /// @notice Verifies redeeming all user-owned shares preserves locked-share V3 liquidity and forwards params.
    function test_Redeem_AllUserSharesPreservesLockedV3Liquidity() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 2000e6;
        uint256 fee0 = 0.1 ether;
        uint256 fee1 = 200e6;

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
        uint256 deployedLiquidity = _deployVaultToV3(vault, token0, token1, pool, positionManager, 
                        V3_LOW_VENUE_ID, tickLower, tickUpper, amount0, amount1);

        assertTrue(adapter.hasPosition());
        assertEq(adapter.tokenId(), 1);

        uint256 aliceShares = vault.balanceOf(alice);
        uint256 totalSharesBefore = vault.totalSupply();
        uint256 principal0Out = amount0 * aliceShares / totalSharesBefore;
        uint256 principal1Out = amount1 * aliceShares / totalSharesBefore;
        uint256 aliceFee0 = fee0 * aliceShares / totalSharesBefore;
        uint256 aliceFee1 = fee1 * aliceShares / totalSharesBefore;
        uint256 liquidityToWithdraw = deployedLiquidity * aliceShares / totalSharesBefore;
        uint256 remainingLiquidity = deployedLiquidity - liquidityToWithdraw;
        
        (uint256 poolAmount0Out, uint256 poolAmount1Out) = _mapPoolAmounts(token0, token1, principal0Out, principal1Out);
        (uint256 poolAmount0Min, uint256 poolAmount1Min) = _mapPoolAmounts(token0, token1, amount0Min, amount1Min);
        (uint256 feePool0, uint256 feePool1) = _mapPoolAmounts(token0, token1, fee0, fee1);

        positionManager.setNextDecreaseResult(poolAmount0Out, poolAmount1Out);
        positionManager.addFees(adapter.tokenId(), uint128(feePool0), uint128(feePool1));
        
        vm.prank(alice);
        (uint256 redeemAmount0, uint256 redeemAmount1) = vault.redeem(aliceShares, alice, alice, withdrawalParams, 0, 0);

        assertEq(redeemAmount0, principal0Out + aliceFee0);
        assertEq(redeemAmount1, principal1Out + aliceFee1);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.totalSupply(), vault.MINIMUM_LOCKED_SHARES());
        assertEq(vault.venueLiquidity(V3_LOW_VENUE_ID), remainingLiquidity);
        assertEq(vault.totalLiquidity(), remainingLiquidity);
        assertTrue(adapter.hasPosition());
        assertEq(adapter.tokenId(), 1);

        assertEq(positionManager.lastDecreaseAmount0Min(), poolAmount0Min);
        assertEq(positionManager.lastDecreaseAmount1Min(), poolAmount1Min);
        assertEq(positionManager.lastDecreaseDeadline(), deadline);
    }

    /// @notice Verifies a partial V3 redeem distributes principal and harvested fees pro rata.
    function test_Redeem_PartiallyDistributesV3FeesProRata() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 2000e6;
        uint256 fee0 = 0.2 ether;
        uint256 fee1 = 400e6;

        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);
        _mintAndDeposit(token0, token1, vault, bob, amount0, amount1);
        uint256 aliceShares = vault.balanceOf(alice);
        uint256 bobShares = vault.balanceOf(bob);
        uint256 totalSharesBefore = vault.totalSupply();
        assertEq(aliceShares + vault.MINIMUM_LOCKED_SHARES(), bobShares);
        assertEq(totalSharesBefore, aliceShares + bobShares + vault.MINIMUM_LOCKED_SHARES());

        uint256 totalAmount0 = 2 ether;
        uint256 totalAmount1 = 4000e6;
        uint256 deployedLiquidity = _deployVaultToV3(vault, token0, token1, pool, positionManager, 
                                V3_LOW_VENUE_ID, tickLower, tickUpper, totalAmount0, totalAmount1);
        assertEq(vault.venueLiquidity(V3_LOW_VENUE_ID), deployedLiquidity);
        assertEq(vault.totalLiquidity(), deployedLiquidity);
        assertTrue(adapter.hasPosition());
        assertEq(adapter.tokenId(), 1);

        uint256 principal0Out = totalAmount0 * aliceShares / totalSharesBefore;
        uint256 principal1Out = totalAmount1 * aliceShares / totalSharesBefore;
        uint256 aliceFee0 = fee0 * aliceShares / totalSharesBefore;
        uint256 aliceFee1 = fee1 * aliceShares / totalSharesBefore;
        uint256 liquidityToWithdraw = deployedLiquidity * aliceShares / totalSharesBefore;
        uint256 remainingLiquidity = deployedLiquidity - liquidityToWithdraw;

        (uint256 feePool0, uint256 feePool1) = _mapPoolAmounts(token0, token1, fee0, fee1);
        positionManager.addFees(adapter.tokenId(), uint128(feePool0), uint128(feePool1));

        (uint256 poolAmount0Out, uint256 poolAmount1Out) = _mapPoolAmounts(token0, token1, principal0Out, principal1Out);
        positionManager.setNextDecreaseResult(poolAmount0Out, poolAmount1Out);

        vm.prank(alice);
        (uint256 aliceAmount0Out, uint256 aliceAmount1Out) = vault.redeem(aliceShares, alice, alice, _emptyWithdrawalParams(), 0, 0);

        assertEq(aliceAmount0Out, principal0Out + aliceFee0);
        assertEq(aliceAmount1Out, principal1Out + aliceFee1);

        assertEq(token0.balanceOf(address(vault)), fee0 - aliceFee0);
        assertEq(token1.balanceOf(address(vault)), fee1 - aliceFee1);

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(bob), bobShares);
        assertEq(vault.totalSupply(), bobShares + vault.MINIMUM_LOCKED_SHARES());
        assertEq(vault.venueLiquidity(V3_LOW_VENUE_ID), remainingLiquidity);
        assertEq(vault.totalLiquidity(),  remainingLiquidity);
        assertTrue(adapter.hasPosition());
        assertEq(adapter.tokenId(), 1);

        (,,,,,,, uint128 positionLiquidity,,,,) = positionManager.positions(adapter.tokenId());
        assertEq(uint256(positionLiquidity), remainingLiquidity);
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

    /// @notice Verifies harvesting transfers V3 fees to vault idle balances without removing the active position.
    function test_HarvestVenueFees_CollectsFeesWithoutRemovingPosition() public {
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

        (uint256 collected0, uint256 collected1) = vault.harvestVenueFees(V3_LOW_VENUE_ID);
        assertEq(collected0, fee0);
        assertEq(collected1, fee1);

        assertEq(token0.balanceOf(address(vault)), vault0Before + fee0);
        assertEq(token1.balanceOf(address(vault)), vault1Before + fee1);
        
        assertEq(vault.totalLiquidity(), liquidity);
        assertTrue(adapter.hasPosition());
    }

    /// @notice Verifies compounding V3 fees increases the existing position without changing share supply.
    function test_CompoundVenueFees_IncreasesExistingV3Position() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 2000e6;
        uint256 fee0 = 0.1 ether;
        uint256 fee1 = 200e6;
        uint128 liquidityAdded = 1234;

        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);

        _deployVaultToV3(vault, token0, token1, pool, positionManager, V3_LOW_VENUE_ID, tickLower, tickUpper, amount0, amount1);

        uint256 tokenIdBefore = adapter.tokenId();
        uint256 venueLiquidityBefore = vault.venueLiquidity(V3_LOW_VENUE_ID);
        uint256 totalSupplyBefore = vault.totalSupply();

        (uint256 feePool0, uint256 feePool1) = _mapPoolAmounts(token0, token1, fee0, fee1);
        positionManager.addFees(adapter.tokenId(), uint128(feePool0), uint128(feePool1));
        positionManager.setNextIncreaseResult(liquidityAdded, feePool0, feePool1);

        uint256 amount0Min = fee0 / 2;
        uint256 amount1Min = fee1 / 2;
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory params = _v3Params(amount0Min, amount1Min, deadline, tickLower, tickUpper);
        (uint256 poolAmount0Min, uint256 poolAmount1Min) = _mapPoolAmounts(token0, token1, amount0Min, amount1Min);

        (uint256 collected0, uint256 collected1, uint256 actualLiquidityAdded) = vault.compoundVenueFees(V3_LOW_VENUE_ID, params);

        assertEq(collected0, fee0);
        assertEq(collected1, fee1);
        assertEq(actualLiquidityAdded, liquidityAdded);

        assertEq(vault.venueLiquidity(V3_LOW_VENUE_ID), venueLiquidityBefore + liquidityAdded);
        assertEq(vault.totalLiquidity(), venueLiquidityBefore + liquidityAdded);
        assertEq(vault.totalSupply(), totalSupplyBefore);

        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token1.balanceOf(address(vault)), 0);

        assertEq(positionManager.lastIncreaseAmount0Min(), poolAmount0Min);
        assertEq(positionManager.lastIncreaseAmount1Min(), poolAmount1Min);
        assertEq(positionManager.lastIncreaseDeadline(), deadline);

        (,,,,,,, uint128 positionLiquidity,,,,) = positionManager.positions(tokenIdBefore);
        assertEq(uint256(positionLiquidity), venueLiquidityBefore + liquidityAdded);
    }
}
