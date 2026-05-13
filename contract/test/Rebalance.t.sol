// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockUniswapV2Pair.sol";
import "./mocks/MockUniswapV2Router.sol";
import "./mocks/MockPriceOracle.sol";
import "../src/AdaptiveLPVault.sol";
import "../src/adapters/UniswapV2Adapter.sol";

/// @title RebalanceTest
/// @notice Rebalance-focused tests for the minimal single-venue vault strategy.
contract RebalanceTest is Test {
    MockERC20 public token0;
    MockERC20 public token1;
    uint8 public decimals0 = 18;
    uint8 public decimals1 = 6;
    AdaptiveLPVault public vault;
    MockPriceOracle public oracle;

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
        vault.setOracle(address(oracle));
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

        // set adapter into vault
        vault.setAdapter(address(adapter));
    }

    /// @notice Seeds the vault with a user deposit so rebalance tests can start from an idle position.
    /// @param user Address that performs the deposit.
    /// @param amount0 Raw token0 amount to deposit.
    /// @param amount1 Raw token1 amount to deposit.
    function _setupIdleVault(address user, uint256 amount0, uint256 amount1) internal {
        token0.mint(user, amount0);
        token1.mint(user, amount1);

        vm.startPrank(user);
        token0.approve(address(vault), amount0);
        token1.approve(address(vault), amount1);
        vault.deposit(amount0, amount1);
        vm.stopPrank();
    }

    /// @notice Verifies rebalance remains owner-only.
    function test_Rebalance_RevertsWhenCallerIsNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.rebalance(AdaptiveLPVault.Venue.DEPLOYED_V2);
    }

    /// @notice Verifies rebalance moves all idle balances into the single supported V2 venue.
    function test_Rebalance_IdleToV2_DeploysAllIdleBalances() public {
        uint256 amount0 = 10 ether;
        uint256 amount1 = 20e6;
        uint256 liquidityMinted = 5 ether;
        _setupIdleVault(alice, amount0, amount1);

        router.setNextAddLiquidityResult(amount0, amount1, liquidityMinted);

        vault.rebalance(AdaptiveLPVault.Venue.DEPLOYED_V2);

        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token1.balanceOf(address(vault)), 0);
        assertEq(token0.balanceOf(address(pair)), amount0);
        assertEq(token1.balanceOf(address(pair)), amount1);

        assertEq(pair.balanceOf(address(adapter)), liquidityMinted);
        assertEq(vault.totalLiquidity(), liquidityMinted);

        assertTrue(adapter.hasPosition());
    }

    /// @notice Verifies rebalance to V2 reverts when the vault has no idle balances left to deploy.
    function test_Rebalance_DepositedToV2_RevertsWhenNoIdleFunds() public {
        uint256 amount0 = 10 ether;
        uint256 amount1 = 20e6;
        uint256 liquidityMinted = 5 ether;
        _setupIdleVault(alice, amount0, amount1);

        router.setNextAddLiquidityResult(amount0, amount1, liquidityMinted);

        vault.rebalance(AdaptiveLPVault.Venue.DEPLOYED_V2);
        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(vault.totalLiquidity(), liquidityMinted);

        vm.expectRevert(AdaptiveLPVault.NoRebalanceNeeded.selector);
        vault.rebalance(AdaptiveLPVault.Venue.DEPLOYED_V2);
    }

    /// @notice Verifies rebalance to IDLE withdraws all deployed liquidity from the adapter.
    function test_Rebalance_V2ToIdle_WithdrawsAllLiquidity() public {
        uint256 amount0 = 10 ether;
        uint256 amount1 = 20e6;
        uint256 liquidityMinted = 5 ether;
        _setupIdleVault(alice, amount0, amount1);

        router.setNextAddLiquidityResult(amount0, amount1, liquidityMinted);

        vault.rebalance(AdaptiveLPVault.Venue.DEPLOYED_V2);
        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(vault.totalLiquidity(), liquidityMinted);

        router.setNextRemoveLiquidityResult(amount0, amount1);
        vault.rebalance(AdaptiveLPVault.Venue.IDLE);
        assertEq(token0.balanceOf(address(vault)), amount0);
        assertEq(token1.balanceOf(address(vault)), amount1);
        assertEq(vault.totalLiquidity(), 0);
        assertFalse(adapter.hasPosition());
    }

    /// @notice Verifies rebalance to IDLE reverts when there is no deployed liquidity to withdraw.
    function test_Rebalance_Idle_RevertsWhenNoLiquidity() public {
        vm.expectRevert(AdaptiveLPVault.NoRebalanceNeeded.selector);
        vault.rebalance(AdaptiveLPVault.Venue.IDLE);
    }

    /// @notice Verifies adapter changes are blocked while deployed liquidity is still active.
    function test_SetAdapter_RevertsWhenThereIsActiveLiquidity() public {
        uint256 amount0 = 10 ether;
        uint256 amount1 = 20e6;
        uint256 liquidityMinted = 5 ether;
        _setupIdleVault(alice, amount0, amount1);

        router.setNextAddLiquidityResult(amount0, amount1, liquidityMinted);

        vault.rebalance(AdaptiveLPVault.Venue.DEPLOYED_V2);
        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(vault.totalLiquidity(), liquidityMinted);

        address newAdapter = address(0xDEAD);
        vm.expectRevert(AdaptiveLPVault.ActivePositionExists.selector);
        vault.setAdapter(newAdapter);
    }
}
