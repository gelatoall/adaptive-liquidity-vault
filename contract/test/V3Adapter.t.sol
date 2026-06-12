// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/adapters/UniswapV3Adapter.sol";
import "../src/libraries/v3/TickMath.sol";
import "../src/libraries/v3/LiquidityAmounts.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockUniswapV3Pool.sol";
import "./mocks/MockNonfungiblePositionManager.sol";
import "./helpers/VenueTestHelper.sol";

contract V3AdapterTest is Test, VenueTestHelper {
    UniswapV3Adapter public adapter;
    MockERC20 public token0;
    MockERC20 public token1;
    MockUniswapV3Pool public pool;
    MockNonfungiblePositionManager public positionManager;

    address public vault;
    uint24 public fee = 3000;
    int24 public tickLower = -600;
    int24 public tickUpper = 600;

    /// @notice Deploys the adapter test fixture with mock tokens, pool, and position manager.
    function setUp() public {
        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("token1", "TK1", 6);

        vault = makeAddr("vault");
        pool = new MockUniswapV3Pool(address(token0), address(token1), fee);
        pool.setSlot0FromTick(0);
        positionManager = new MockNonfungiblePositionManager();

        adapter = new UniswapV3Adapter(
            vault,
            address(token0),
            address(token1),
            address(positionManager),
            address(pool),
            tickLower,
            tickUpper
        );
    }

    /// @notice Mints vault funds and initializes a position through the adapter.
    function _initializePosition(
        uint256 mintAmount0,
        uint256 mintAmount1,
        uint128 mintLiquidity
    ) internal returns (uint256 liquidity){
        uint256 mintAmount0Used = mintAmount0;
        uint256 mintAmount1Used = mintAmount1;

        token0.mint(vault, mintAmount0);
        token1.mint(vault, mintAmount1);

        (uint256 mintPoolAmount0Used, uint256 mintPoolAmount1Used) = _mapPoolAmounts(
            token0,
            token1,
            mintAmount0Used, 
            mintAmount1Used
        );

        vm.startPrank(vault);
        token0.approve(address(adapter), mintAmount0);
        token1.approve(address(adapter), mintAmount1);

        positionManager.setNextMintResult(mintLiquidity, mintPoolAmount0Used, mintPoolAmount1Used);
        liquidity = adapter.addLiquidity(
            mintAmount0, 
            mintAmount1, 
            abi.encode(0, 0, block.timestamp + 1)
        );
        vm.stopPrank();
    }


    // unit tests
    function test_Constructor_SetsImmutableConfig() public {
        assertEq(adapter.vault(), vault);
        assertEq(address(adapter.token0()), address(token0));
        assertEq(address(adapter.token1()), address(token1));
        assertEq(address(adapter.positionManager()), address(positionManager));
        assertEq(address(adapter.pool()), address(pool));
        assertEq(adapter.tickLower(), tickLower);
        assertEq(adapter.tickUpper(), tickUpper);
        assertEq(adapter.tokenId(), 0);
    }

    function test_Constructor_RevertsWhenPoolTokensDoNotMatch() public {
        MockERC20 wrongToken = new MockERC20("Wrong", "WRG", 18);
        MockUniswapV3Pool wrongPool = new MockUniswapV3Pool(address(token0), address(wrongToken), fee);

        vm.expectRevert(UniswapV3Adapter.InvalidPool.selector);
        new UniswapV3Adapter(
            vault,
            address(token0),
            address(token1),
            address(positionManager),
            address(wrongPool),
            tickLower,
            tickUpper
        );
    }

    function test_Constructor_RevertsWhenTicksAreInvalid() public {
        vm.expectRevert(UniswapV3Adapter.InvalidTicks.selector);
        new UniswapV3Adapter(
            vault,
            address(token0),
            address(token1),
            address(positionManager),
            address(pool),
            tickUpper,
            tickLower
        );
    }

    function test_AddLiquidity_MintsAndRefundsDust() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 2000e6;
        uint256 amount0Used = 0.8 ether;
        uint256 amount1Used = 1500e6;
        uint128 liquidityMinted = 1234;

        token0.mint(vault, amount0);
        token1.mint(vault, amount1);

        uint256 vault0Before = token0.balanceOf(vault);
        uint256 vault1Before = token1.balanceOf(vault);

        (uint256 poolAmount0Used, uint256 poolAmount1Used) = _mapPoolAmounts(token0, token1, amount0Used, amount1Used);

        vm.startPrank(vault);
        token0.approve(address(adapter), amount0);
        token1.approve(address(adapter), amount1);

        positionManager.setNextMintResult(liquidityMinted, poolAmount0Used, poolAmount1Used);
        uint256 liquidity = adapter.addLiquidity(amount0, amount1, abi.encode(0, 0, block.timestamp + 1));
        vm.stopPrank();

        assertEq(liquidity, liquidityMinted);
        assertEq(adapter.tokenId(), 1);
        assertTrue(adapter.hasPosition());

        assertEq(token0.balanceOf(vault), vault0Before - amount0Used);
        assertEq(token1.balanceOf(vault), vault1Before - amount1Used);
        
        assertEq(token0.allowance(address(adapter), address(positionManager)), 0);
        assertEq(token1.allowance(address(adapter), address(positionManager)), 0);
    }

    function test_AddLiquidity_IncreasesWhenTokenIdExists() public {
        uint256 mintAmount0 = 1 ether;
        uint256 mintAmount1 = 2000e6;
        uint256 mintAmount0Used = 1 ether;
        uint256 mintAmount1Used = 2000e6;
        uint128 mintLiquidity = 1234;

        uint256 increaseAmount0 = 0.5 ether;
        uint256 increaseAmount1 = 1000e6;
        uint256 increaseAmount0Used = 0.4 ether;
        uint256 increaseAmount1Used = 800e6;
        uint128 increaseLiquidity = 5678;

        token0.mint(vault, mintAmount0 + increaseAmount0);
        token1.mint(vault, mintAmount1 + increaseAmount1);

        (uint256 mintPoolAmount0Used, uint256 mintPoolAmount1Used) = _mapPoolAmounts(
            token0, 
            token1, 
            mintAmount0Used, 
            mintAmount1Used
        );
        (uint256 increasePoolAmount0Used, uint256 increasePoolAmount1Used) = _mapPoolAmounts(
            token0, 
            token1, 
            increaseAmount0Used, 
            increaseAmount1Used
        );

        vm.startPrank(vault);
        token0.approve(address(adapter), mintAmount0 + increaseAmount0);
        token1.approve(address(adapter), mintAmount1 + increaseAmount1);

        positionManager.setNextMintResult(mintLiquidity, mintPoolAmount0Used, mintPoolAmount1Used);
        uint256 firstLiquidity = adapter.addLiquidity(
            mintAmount0, 
            mintAmount1, 
            abi.encode(0, 0, block.timestamp + 1)
        );
        uint256 tokenIdBefore = adapter.tokenId();
        uint256 vault0Before = token0.balanceOf(vault);
        uint256 vault1Before = token1.balanceOf(vault);

        positionManager.setNextIncreaseResult(increaseLiquidity, increasePoolAmount0Used, increasePoolAmount1Used);
        uint256 secondLiquidity = adapter.addLiquidity(
            increaseAmount0, 
            increaseAmount1, 
            abi.encode(0, 0, block.timestamp + 1)
        );
        uint256 tokenIdAfter = adapter.tokenId();
        vm.stopPrank();

        assertEq(tokenIdAfter, 1);
        assertEq(tokenIdBefore, tokenIdAfter);
        assertTrue(adapter.hasPosition());

        assertEq(token0.balanceOf(vault), vault0Before - increaseAmount0Used);
        assertEq(token1.balanceOf(vault), vault1Before - increaseAmount1Used);
        assertEq(firstLiquidity, mintLiquidity);
        assertEq(secondLiquidity, increaseLiquidity);
    }

    function test_RemoveLiquidity_DecreasesAndCollectsToVault() public {
        uint256 mintAmount0 = 1 ether;
        uint256 mintAmount1 = 2000e6;
        uint128 mintLiquidity = 1234;
        uint256 removeLiquidityAmount = mintLiquidity;

        uint256 expectedVaultAmount0Out = 0.25 ether;
        uint256 expectedVaultAmount1Out = 500e6;

        uint256 liquidity = _initializePosition(mintAmount0, mintAmount1, mintLiquidity);

        assertEq(liquidity, mintLiquidity);
        assertTrue(adapter.hasPosition());

        uint256 vault0BeforeDecrease = token0.balanceOf(vault);
        uint256 vault1BeforeDecrease = token1.balanceOf(vault);

        (uint256 decreasePoolAmount0Out, uint256 decreasePoolAmount1Out) = _mapPoolAmounts(
            token0, 
            token1, 
            expectedVaultAmount0Out,
            expectedVaultAmount1Out
        );

        positionManager.setNextDecreaseResult(decreasePoolAmount0Out, decreasePoolAmount1Out);

        vm.prank(vault);
        (uint256 amount0, uint256 amount1) = adapter.removeLiquidity(removeLiquidityAmount);

        assertEq(amount0, expectedVaultAmount0Out);
        assertEq(amount1, expectedVaultAmount1Out);
        assertEq(token0.balanceOf(vault), vault0BeforeDecrease + expectedVaultAmount0Out);
        assertEq(token1.balanceOf(vault), vault1BeforeDecrease + expectedVaultAmount1Out);
        assertEq(adapter.tokenId(), 0);
        assertFalse(adapter.hasPosition());
    }

    function test_RemoveLiquidity_PartialRemoveKeepsTokenId() public {
        uint256 mintAmount0 = 1 ether;
        uint256 mintAmount1 = 2000e6;
        uint128 mintLiquidity = 1234;
        
        uint256 removeLiquidityAmount = 400;
        uint256 expectedVaultAmount0Out = 0.1 ether;
        uint256 expectedVaultAmount1Out = 200e6;

        _initializePosition(mintAmount0, mintAmount1, mintLiquidity);

        uint256 vault0BeforeDecrease = token0.balanceOf(vault);
        uint256 vault1BeforeDecrease = token1.balanceOf(vault);

        (uint256 decreasePoolAmount0Out, uint256 decreasePoolAmount1Out) = _mapPoolAmounts(
            token0, 
            token1, 
            expectedVaultAmount0Out,
            expectedVaultAmount1Out
        );

        positionManager.setNextDecreaseResult(decreasePoolAmount0Out, decreasePoolAmount1Out);
        
        vm.prank(vault);
        (uint256 amount0, uint256 amount1) = adapter.removeLiquidity(removeLiquidityAmount);

        assertEq(amount0, expectedVaultAmount0Out);
        assertEq(amount1, expectedVaultAmount1Out);
        assertEq(token0.balanceOf(vault), vault0BeforeDecrease + expectedVaultAmount0Out);
        assertEq(token1.balanceOf(vault), vault1BeforeDecrease + expectedVaultAmount1Out);
        assertEq(adapter.tokenId(), 1);
        assertTrue(adapter.hasPosition());
    }

    function test_CollectFees_CollectsOwedAmountsToVault() public {
        uint256 fee0 = 0.1 ether;
        uint256 fee1 = 200e6;

        uint256 mintAmount0 = 1 ether;
        uint256 mintAmount1 = 2000e6;
        uint128 mintLiquidity = 1234;
        _initializePosition(mintAmount0, mintAmount1, mintLiquidity);

        uint256 vault0BeforeCollect = token0.balanceOf(vault);
        uint256 vault1BeforeCollect = token1.balanceOf(vault);

        (uint256 feePoolAmount0, uint256 feePoolAmount1) = _mapPoolAmounts(token0, token1, fee0, fee1);
        positionManager.addFees(adapter.tokenId(), uint128(feePoolAmount0), uint128(feePoolAmount1));
        
        vm.prank(vault);
        (uint256 collected0, uint256 collected1) = adapter.collectFees();

        assertEq(collected0, fee0);
        assertEq(collected1, fee1);
        assertEq(token0.balanceOf(vault), vault0BeforeCollect + fee0);
        assertEq(token1.balanceOf(vault), vault1BeforeCollect + fee1);
        assertEq(adapter.tokenId(), 1);
        assertTrue(adapter.hasPosition());
    }

    function test_CollectFees_CleansUpWhenPositionBecomesEmpty() public {
        uint256 mintAmount0 = 1 ether;
        uint256 mintAmount1 = 2000e6;
        uint128 mintLiquidity = 0;

        uint256 fee0 = 0.1 ether;
        uint256 fee1 = 200e6;

        _initializePosition(mintAmount0, mintAmount1, mintLiquidity);
        assertFalse(adapter.hasPosition());

        (uint256 feePoolAmount0, uint256 feePoolAmount1) = _mapPoolAmounts(token0, token1, fee0, fee1);
        positionManager.addFees(adapter.tokenId(), uint128(feePoolAmount0), uint128(feePoolAmount1));
        assertTrue(adapter.hasPosition());

        vm.prank(vault);
        (uint256 collected0, uint256 collected1) = adapter.collectFees();
        
        assertEq(collected0, fee0);
        assertEq(collected1, fee1);
        assertEq(token0.balanceOf(vault), fee0);
        assertEq(token1.balanceOf(vault), fee1);
        assertEq(adapter.tokenId(), 0);
        assertFalse(adapter.hasPosition());
    }

    function test_HasPosition_TracksLifecycle() public {
        uint256 mintAmount0 = 1 ether;
        uint256 mintAmount1 = 2000e6;
        uint128 mintLiquidity = 1234;

        assertFalse(adapter.hasPosition());

        _initializePosition(mintAmount0, mintAmount1, mintLiquidity);
        assertTrue(adapter.hasPosition());
        assertEq(adapter.tokenId(), 1);

        uint256 expectedVaultAmount0Out = 0.25 ether;
        uint256 expectedVaultAmount1Out = 500e6;

        (uint256 decreasePoolAmount0Out, uint256 decreasePoolAmount1Out) = _mapPoolAmounts(
            token0, 
            token1, 
            expectedVaultAmount0Out,
            expectedVaultAmount1Out
        );
        positionManager.setNextDecreaseResult(decreasePoolAmount0Out, decreasePoolAmount1Out);
        
        vm.prank(vault);
        adapter.removeLiquidity(mintLiquidity);

        assertFalse(adapter.hasPosition());
        assertEq(adapter.tokenId(), 0);
    }

    function test_GetPositionValue_ReturnsZeroWhenNoPosition() public {
        (uint256 amount0, uint256 amount1) = adapter.getPositionValue();
        assertEq(amount0, 0);
        assertEq(amount1, 0);
        assertFalse(adapter.hasPosition());
    }

    function test_GetPositionValue_ReturnsPrincipalInVaultOrder() public {
        uint256 mintAmount0 = 1 ether;
        uint256 mintAmount1 = 2000e6;
        uint128 mintLiquidity = 1234;

        _initializePosition(mintAmount0, mintAmount1, mintLiquidity);
        assertTrue(adapter.hasPosition());

        pool.setSlot0FromTick(0);
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        uint160 sqrtRatioLowerX96 = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioUpperX96 = TickMath.getSqrtRatioAtTick(tickUpper);

        (, , , , , , , uint128 positionLiquidity, , , , ) = positionManager.positions(adapter.tokenId());

        (uint256 poolAmount0, uint256 poolAmount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, 
            sqrtRatioLowerX96, 
            sqrtRatioUpperX96, 
            positionLiquidity
        );

        (uint256 expectedAmount0, uint256 expectedAmount1) = _mapPoolAmounts(token0, token1, poolAmount0, poolAmount1);

        (uint256 amount0, uint256 amount1) = adapter.getPositionValue();

        assertEq(amount0, expectedAmount0);
        assertEq(amount1, expectedAmount1);
    }

    function test_GetPositionValue_IncludesPrincipalAndOwed() public {
        uint256 mintAmount0 = 1 ether;
        uint256 mintAmount1 = 2000e6;
        uint128 mintLiquidity = 1234;

        uint256 fee0 = 0.1 ether;
        uint256 fee1 = 200e6;

        _initializePosition(mintAmount0, mintAmount1, mintLiquidity);
        assertTrue(adapter.hasPosition());

        pool.setSlot0FromTick(0);
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        uint160 sqrtRatioLowerX96 = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioUpperX96 = TickMath.getSqrtRatioAtTick(tickUpper);

        (, , , , , , , uint128 positionLiquidity, , , , ) = positionManager.positions(adapter.tokenId());

        (uint256 principalPool0, uint256 principalPool1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, 
            sqrtRatioLowerX96, 
            sqrtRatioUpperX96, 
            positionLiquidity
        );

        (uint256 feePool0, uint256 feePool1) = _mapPoolAmounts(token0, token1, fee0, fee1);
        positionManager.addFees(adapter.tokenId(), uint128(feePool0), uint128(feePool1));

        uint256 expectedPool0 = principalPool0 + feePool0;
        uint256 expectedPool1 = principalPool1 + feePool1;
        (uint256 expectedAmount0, uint256 expectedAmount1) = _mapPoolAmounts(token0, token1, expectedPool0, expectedPool1);

        (uint256 amount0, uint256 amount1) = adapter.getPositionValue();

        assertEq(amount0, expectedAmount0);
        assertEq(amount1, expectedAmount1);
    }


    function test_GetPositionValue_IncludesOwedWhenLiquidityIsZero() public {
        uint256 mintAmount0 = 1 ether;
        uint256 mintAmount1 = 2000e6;
        uint128 mintLiquidity = 0;

        uint256 fee0 = 0.1 ether;
        uint256 fee1 = 200e6;

        _initializePosition(mintAmount0, mintAmount1, mintLiquidity);
        assertFalse(adapter.hasPosition());

        (uint256 feePool0, uint256 feePool1) = _mapPoolAmounts(token0, token1, fee0, fee1);
        positionManager.addFees(adapter.tokenId(), uint128(feePool0), uint128(feePool1));

        assertTrue(adapter.hasPosition());

        (uint256 amount0, uint256 amount1) = adapter.getPositionValue();
        assertEq(amount0, fee0);
        assertEq(amount1, fee1);
    } 
}
