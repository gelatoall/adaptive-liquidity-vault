// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockUniswapV2Pair.sol";
import "./mocks/MockUniswapV2Router.sol";
import "./mocks/MockPriceOracle.sol";
import "../src/AdaptiveLPVault.sol";
import "../src/adapters/UniswapV2Adapter.sol";
import "../src/valuators/V2FairValueValuator.sol";
import "./helpers/VaultTestHelper.sol";
import "./helpers/VenueTestHelper.sol";
import "./helpers/RebalanceTestHelper.sol";

/// @title RebalanceV2Test
/// @notice Rebalance-focused tests for the minimal single-venue V2 vault strategy.
contract RebalanceV2Test is Test, VaultTestHelper, VenueTestHelper, RebalanceTestHelper {
    MockERC20 public token0;
    MockERC20 public token1;
    uint8 public decimals0 = 18;
    uint8 public decimals1 = 6;
    AdaptiveLPVault public vault;
    MockPriceOracle public oracle;
    V2FairValueValuator public valuator;

    MockUniswapV2Pair public pair;
    MockUniswapV2Router public router;
    UniswapV2Adapter public adapter;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    /// @notice Deploys the mock tokens, vault, oracle, pair, router, and adapter used by each test.
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

        oracle = new MockPriceOracle();
        _configureMirroredPriceOracles(vault, oracle);
        oracle.setPrices(1e18, 1e18);

        // deploy pair/router/adapter
        pair = new MockUniswapV2Pair(address(token0), address(token1));
        router = new MockUniswapV2Router(pair);
        adapter = new UniswapV2Adapter(
            address(vault),
            address(token0),
            address(token1),
            address(router),
            address(pair)
        );

        // set venue into vault
        vault.setVenue(V2_VENUE_ID, address(adapter), V2_LABEL, true);

        valuator = new V2FairValueValuator(address(adapter));
        vault.setVenueValuator(V2_VENUE_ID, address(valuator));
    }

    /// @notice Verifies rebalance remains owner-only.
    function test_Rebalance_RevertsWhenCallerIsNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        _rebalanceToVenue(vault, V2_VENUE_ID, 10 ether, 5 ether, "");
    }

    /// @notice Verifies manual rebalance is disabled while the vault is paused.
    function test_Rebalance_RevertsWhenPaused() public {
        vault.pause();

        RebalanceTypes.RebalanceTarget[] memory targets = new RebalanceTypes.RebalanceTarget[](0);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.rebalance(targets, _emptyWithdrawalParams());
    }

    /// @notice Verifies rebalance moves all idle balances into the single supported V2 venue.
    function test_Rebalance_IdleToV2_DeploysAllIdleBalances() public {
        uint256 amount0 = 10 ether;
        uint256 amount1 = 20e6;
        uint256 liquidityMinted = 5 ether;
        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);

        router.setNextAddLiquidityResult(amount0, amount1, liquidityMinted);

        _rebalanceToVenue(vault, V2_VENUE_ID, amount0, amount1, "");

        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token1.balanceOf(address(vault)), 0);
        assertEq(token0.balanceOf(address(pair)), amount0);
        assertEq(token1.balanceOf(address(pair)), amount1);

        assertEq(pair.balanceOf(address(adapter)), liquidityMinted);

        assertTrue(adapter.hasPosition());
    }

    /// @notice Verifies rebalance to IDLE withdraws all DEPLOYED_V2 liquidity from the adapter.
    function test_Rebalance_V2ToIdle_WithdrawsAllLiquidity() public {
        uint256 amount0 = 10 ether;
        uint256 amount1 = 20e6;
        uint256 liquidityMinted = 5 ether;
        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);

        router.setNextAddLiquidityResult(amount0, amount1, liquidityMinted);

        _rebalanceToVenue(vault, V2_VENUE_ID, amount0, amount1, "");

        assertEq(token0.balanceOf(address(vault)), 0);

        uint256 amount0Min = amount0 / 2;
        uint256 amount1Min = amount1 / 2;
        uint256 deadline = block.timestamp + 1 hours;
        AdaptiveLPVault.VenueWithdrawalParams[] memory withdrawalParams = new AdaptiveLPVault.VenueWithdrawalParams[](1);
        withdrawalParams[0] = AdaptiveLPVault.VenueWithdrawalParams({
            venueId: V2_VENUE_ID,
            params: abi.encode(amount0Min, amount1Min, deadline)
        });

        router.setNextRemoveLiquidityResult(amount0, amount1);
        // Mock router mints LP but reserves are scripted separately for getPositionValue().
        pair.setReserves(uint112(amount0), uint112(amount1));
        vault.setMaxRebalanceValueLossBps(100);

        RebalanceTypes.RebalanceTarget[] memory targets = new RebalanceTypes.RebalanceTarget[](0);
        vault.rebalance(targets, withdrawalParams);

        assertEq(token0.balanceOf(address(vault)), amount0);
        assertEq(token1.balanceOf(address(vault)), amount1);
        assertFalse(adapter.hasPosition());

        assertEq(router.lastRemoveAmountAMin(), amount0Min);
        assertEq(router.lastRemoveAmountBMin(), amount1Min);
        assertEq(router.lastRemoveDeadline(), deadline);
    }

    function testFuzz_Rebalance_V2RoundTripPreservesSupply(uint256 amount0, uint256 amount1, uint256 liquidityMinted) public {
        amount0 = bound(amount0, 1e18, 10000e18);
        amount1 = bound(amount1, 1e6, 10000e6);
        liquidityMinted = bound(liquidityMinted, 1, 10000e18);

        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);
        uint256 totalSharesBefore = vault.totalSupply();

        router.setNextAddLiquidityResult(amount0, amount1, liquidityMinted);
        _rebalanceToVenue(vault, V2_VENUE_ID, amount0, amount1, "");

        pair.setReserves(uint112(amount0), uint112(amount1));

        router.setNextRemoveLiquidityResult(amount0, amount1);
        _rebalanceToIdle(vault);

        assertEq(vault.totalSupply(), totalSharesBefore);
        assertEq(token0.balanceOf(address(vault)), amount0);
        assertEq(token1.balanceOf(address(vault)), amount1);
        assertEq(vault.venueLiquidity(V2_VENUE_ID), 0);
    }

    /// @notice Verifies rebalance to IDLE reverts when there is no DEPLOYED_V2 liquidity to withdraw.
    function test_Rebalance_Idle_RevertsWhenNoLiquidity() public {
        vm.expectRevert(AdaptiveLPVault.NoRebalanceNeeded.selector);
        _rebalanceToIdle(vault);
    }

    /// @notice Verifies the value-loss guard reverts when a rebalance returns materially less value.
    function test_Rebalance_RevertsWhenValueLossExceedsLimit() public {
        uint256 amount0 = 10 ether;
        uint256 amount1 = 20e6;
        uint256 liquidityMinted = 5 ether;
        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);

        router.setNextAddLiquidityResult(amount0, amount1, liquidityMinted);

        _rebalanceToVenue(vault, V2_VENUE_ID, amount0, amount1, "");

        assertEq(token0.balanceOf(address(vault)), 0);

        // Mock router mints LP but reserves are scripted separately for getPositionValue().
        pair.setReserves(uint112(amount0), uint112(amount1));

        vault.setMaxRebalanceValueLossBps(100);
        router.setNextRemoveLiquidityResult(amount0 / 2, amount1 / 2);
        vm.expectRevert(AdaptiveLPVault.ExcessiveRebalanceValueLoss.selector);
        _rebalanceToIdle(vault);
    }
}
