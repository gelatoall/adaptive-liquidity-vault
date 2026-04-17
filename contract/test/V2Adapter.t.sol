// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/adapters/UniswapV2Adapter.sol";

/// @title MockERC20
/// @dev Minimal ERC20 mock with configurable decimals and unrestricted minting for tests.
contract MockERC20 is ERC20 {
    uint8 private immutable _customDecimals;

    /// @param name Token name used by the ERC20 metadata extension.
    /// @param symbol Token symbol used by the ERC20 metadata extension.
    /// @param _decimals Token decimals returned by {decimals}.
    constructor(
        string memory name, 
        string memory symbol,
        uint8 _decimals
    ) ERC20(name, symbol) {
        _customDecimals = _decimals;
    }

    /// @notice Returns the configured token decimals for this mock.
    function decimals() public view override returns (uint8) {
        return _customDecimals;
    }

    /// @notice Mints tokens to the target account.
    /// @param to Recipient of the minted tokens.
    /// @param amount Raw token amount to mint.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Burns tokens from the target account.
    /// @param from Account whose balance is reduced.
    /// @param amount Raw token amount to burn.
    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/// @title MockUniswapV2Pair
/// @notice Minimal LP token and reserve container used to emulate a Uniswap V2 pair.
contract MockUniswapV2Pair is ERC20, IUniswapV2Pair {
    address public token0;
    address public token1;

    uint112 public reserve0;
    uint112 public reserve1;
    uint32 public blockTimeStampLast;

    /// @param _token0 Address exposed as pair token0.
    /// @param _token1 Address exposed as pair token1.
    constructor(address _token0, address _token1) ERC20("Mock V2 LP", "MV2LP"){
        token0 = _token0;
        token1 = _token1;
    }

    /// @notice Returns the LP token balance for an account.
    /// @param account Address whose LP balance is queried.
    function balanceOf(address account) public view override(ERC20, IUniswapV2Pair) returns (uint256) {
        return super.balanceOf(account);
    }

    /// @notice Returns the total LP supply.
    function totalSupply() public view override(ERC20, IUniswapV2Pair) returns (uint256) {
        return super.totalSupply();
    }

    /// @notice Sets mocked pair reserves.
    /// @param _reserve0 Mock reserve for pair token0.
    /// @param _reserve1 Mock reserve for pair token1.
    function setReserves(uint112 _reserve0, uint112 _reserve1) external {
        reserve0 = _reserve0;
        reserve1 = _reserve1;
        blockTimeStampLast = uint32(block.timestamp);
    }

    /// @notice Returns the mocked pair reserves and last update timestamp.
    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, blockTimeStampLast);
    }

    /// @notice Mints LP tokens to the target account.
    /// @param to Recipient of the LP tokens.
    /// @param amount Raw LP amount to mint.
    function mintLp(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Burns LP tokens from the target account.
    /// @param from Account whose LP balance is reduced.
    /// @param amount Raw LP amount to burn.
    function burnLp(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/// @title BrokenUniswapV2Pair
/// @notice Intentionally inconsistent pair mock used to exercise adapter guards for invalid LP supply state.
contract BrokenUniswapV2Pair is IUniswapV2Pair {
    address public token0;
    address public token1;

    uint112 public reserve0;
    uint112 public reserve1;
    uint32 public blockTimeStampLast;

    mapping(address => uint256) internal _balances;

    /// @param _token0 Address exposed as pair token0.
    /// @param _token1 Address exposed as pair token1.
    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
    }

    /// @notice Sets mocked reserves without changing the reported LP total supply.
    /// @param _reserve0 Mock reserve for pair token0.
    /// @param _reserve1 Mock reserve for pair token1.
    function setReserves(uint112 _reserve0, uint112 _reserve1) external {
        reserve0 = _reserve0;
        reserve1 = _reserve1;
        blockTimeStampLast = uint32(block.timestamp);
    }

    /// @notice Sets an arbitrary LP balance for an account.
    /// @param account Account whose LP balance is assigned.
    /// @param amount Mock LP balance to report.
    function setBalance(address account, uint256 amount) external {
        _balances[account] = amount;
    }

    /// @notice Returns the mocked LP balance for an account.
    /// @param account Address whose balance is queried.
    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    /// @notice Always reports zero total supply to simulate an invalid pair state.
    function totalSupply() external pure returns (uint256) {
        return 0;
    }

    /// @notice Returns the mocked reserves and last update timestamp.
    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, blockTimeStampLast);
    }
}

/// @title MockUniswapV2Router
/// @notice Configurable router mock used to script add/remove liquidity results.
contract MockUniswapV2Router is IUniswapV2Router {
    MockUniswapV2Pair private immutable pair;

    uint256 public nextAmountAUsed;
    uint256 public nextAmountBUsed;
    uint256 public nextLiquidityMinted;

    uint256 public nextAmountAOut;
    uint256 public nextAmountBOut;

    /// @param _pair LP token contract minted and burned by the router mock.
    constructor(MockUniswapV2Pair _pair) {
        pair = _pair;
    }

    /// @notice Configures the next `addLiquidity` return values.
    /// @param amountAUsed Amount of tokenA reported as used.
    /// @param amountBUsed Amount of tokenB reported as used.
    /// @param liquidityMinted LP tokens reported as minted.
    function setNextAddLiquidityResult (
        uint256 amountAUsed,
        uint256 amountBUsed,
        uint256 liquidityMinted
    ) external {
        nextAmountAUsed = amountAUsed;
        nextAmountBUsed = amountBUsed;
        nextLiquidityMinted = liquidityMinted;
    }

    /// @notice Configures the next `removeLiquidity` return values.
    /// @param amountAOut Amount of tokenA reported as returned.
    /// @param amountBOut Amount of tokenB reported as returned.
    function setNextRemoveLiquidityResult(
        uint256 amountAOut,
        uint256 amountBOut
    ) external {
        nextAmountAOut = amountAOut;
        nextAmountBOut = amountBOut;
    }

    /// @inheritdoc IUniswapV2Router
    function addLiquidity(
        address,
        address,
        uint256,
        uint256,
        uint256,
        uint256,
        address to,
        uint256
    ) external override returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        amountA = nextAmountAUsed;
        amountB = nextAmountBUsed;
        liquidity = nextLiquidityMinted;
        if (liquidity > 0) {
            pair.mintLp(to, liquidity);
        }
    }

    /// @inheritdoc IUniswapV2Router
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256,
        uint256,
        address to,
        uint256
    ) external override returns (uint256 amountA, uint256 amountB) {
        if (liquidity > 0) {
            pair.burnLp(msg.sender, liquidity);
        }

        amountA = nextAmountAOut;
        amountB = nextAmountBOut;

        if (amountA > 0) {
            MockERC20(tokenA).mint(to, amountA);
        }

        if (amountB > 0) {
            MockERC20(tokenB).mint(to, amountB);
        }
    }
}

/// @title V2AdapterTest
/// @notice Unit tests for `UniswapV2Adapter`.
contract V2AdapterTest is Test {
    UniswapV2Adapter public adapter;
    MockERC20 public token0;
    MockERC20 public token1;
    MockUniswapV2Pair pair;
    MockUniswapV2Router router;

    address vault = address(0xBEEF); // 这里怎么来的？

    /// @notice Deploys the mock tokens, pair, router, and adapter used by each test.
    function setUp() public {
        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("token1", "TK1", 6);

        pair = new MockUniswapV2Pair(address(token0), address(token1));
        router = new MockUniswapV2Router(pair);
        adapter = new UniswapV2Adapter(
            vault,
            address(token0),
            address(token1),
            address(router),
            address(pair)
        );
    }

    /// @notice Verifies the constructor persists the configured addresses.
    function test_Constructor_SetsImmutableAddresses() public {
        // Check if the addresses stored in the adapter match what we passed in setUp
        assertEq(address(adapter.vault()), vault, "Vault address mismatch");
        assertEq(address(adapter.token0()), address(token0), "Token0 address mismatch");
        assertEq(address(adapter.token1()), address(token1), "Token1 address mismatch");
        assertEq(address(adapter.router()), address(router), "Router address mismatch");
        assertEq(address(adapter.pair()), address(pair), "Pair address mismatch");
    }
    
    /// @notice Verifies constructor input validation rejects zero addresses.
    function test_Constructor_RevertsWhenAddressIsZero() public {
        vm.expectRevert(UniswapV2Adapter.ZeroAddress.selector);
        new UniswapV2Adapter(
            address(0),
            address(token0),
            address(token1),
            address(router),
            address(pair)
        );
    }

    /// @notice Verifies constructor input validation rejects pairs with mismatched tokens.
    function test_Constructor_RevertsWhenPairTokensDoNotMatch() public {
        // Create a "wrong" token
        MockERC20 wrongToken = new MockERC20("Wrong", "WRG", 18);
        
        // Create a pair that doesn't match our token0/token1
        MockUniswapV2Pair wrongPair = new MockUniswapV2Pair(address(token0), address(wrongToken));

        // Expect revert because the adapter's token1 and the pair's token1 won't match
        vm.expectRevert(UniswapV2Adapter.InvalidPair.selector);
        new UniswapV2Adapter(
            vault,
            address(token0),
            address(token1), // Adapter expects token1
            address(router),
            address(wrongPair) // But pair provides wrongToken
        );
    }

    /// @notice Verifies explicit fee collection is unsupported for V2 LP positions.
    function test_CollectFees_RevertsAsUnsupported() public {
        vm.expectRevert(UniswapV2Adapter.UnsupportedOperation.selector);
        adapter.collectFees();
    }
  
    /// @notice Verifies `hasPosition` returns false when the adapter holds no LP tokens.
    function test_HasPosition_ReturnsFalseWhenLpBalanceIsZero() public {
        bool hasPos = adapter.hasPosition();
        assertFalse(hasPos, "Should not have position when LP balance is 0");
    }
    
    /// @notice Verifies `hasPosition` returns true when the adapter holds LP tokens.
    function test_HasPosition_ReturnsTrueWhenLpBalanceIsNonZero() public {
        pair.mintLp(address(adapter), 100 ether);
        bool hasPos = adapter.hasPosition();
        assertTrue(hasPos, "Should have position when LP balance is > 0");
    }

    /// @notice Verifies `getPositionValue` returns zeroes when the adapter has no LP balance.
    function test_GetPositionValue_ReturnsZeroWhenNoLpBalance() public {
        (uint256 value0, uint256 value1) = adapter.getPositionValue();
        assertEq(value0, 0, "Token0 value should be 0");
        assertEq(value1, 0, "Token1 value should be 0");
    }

    /// @notice Verifies `getPositionValue` returns the adapter's proportional reserve share.
    function test_GetPositionValue_ReturnsProportionalUnderlyingAmounts() public {
        // --- LP Token Distribution ---
        // Mint 150 LP tokens to an external address to dilute the pool's total supply
        pair.mintLp(address(0x123), 150 ether);
        
        // Mint 50 LP tokens to the adapter. 
        // Total Supply = 150 + 50 = 200. Adapter share = 50/200 = 25%.
        uint256 adapterLp = 50 ether;
        pair.mintLp(address(adapter), adapterLp);

        // --- State Setup ---
        // Define mock reserves for the pair (100 Token0 : 50 Token1)
        uint112 res0 = 100 ether;
        uint112 res1 = 50 ether;
        pair.setReserves(res0, res1);

        // Manual calculation following the formula: (reserve * lpBalance) / totalSupply
        uint256 expected0 = uint256(res0) * adapterLp / pair.totalSupply();
        uint256 expected1 = uint256(res1) * adapterLp / pair.totalSupply();

        (uint256 prop0, uint256 prop1) = adapter.getPositionValue();

        assertEq(prop0, expected0);
        assertEq(prop1, expected1);

        // Hardcoded check for sanity: 25% of 100 is 25, 25% of 50 is 12.5
        assertEq(prop0, 25 ether);
        assertEq(prop1, 12.5 ether);
    }

    /// @notice Verifies `getPositionValue` remaps reserves correctly when adapter token order differs from pair token order.
    function test_GetPositionValue_ReturnsCorrectAmountsWhenPairTokenOrderIsReversed() public {
        // Force a specific address order
        // We want our "token1" to have a SMALLER address than "token0"
        // In Foundry, deploying tokens in a certain order or using vm.addr() can achieve this
        MockERC20 tokenA = new MockERC20("TokenA", "TKA", 18);
        MockERC20 tokenB = new MockERC20("TokenB", "TKB", 18);
        
        MockERC20 tLow;  // The one with the smaller address
        MockERC20 tHigh; // The one with the larger address
        
        if (address(tokenA) < address(tokenB)) {
            tLow = tokenA;
            tHigh = tokenB;
        } else {
            tLow = tokenB;
            tHigh = tokenA;
        }

        // Setup the "Reversed" Adapter
        // Tell the adapter: our primary token0 is tHigh, and token1 is tLow
        // But the Uniswap Pair will internally treat tLow as token0 (because it's smaller)
        MockUniswapV2Pair reversedPair = new MockUniswapV2Pair(address(tLow), address(tHigh));
        
        UniswapV2Adapter reversedAdapter = new UniswapV2Adapter(
            vault,
            address(tHigh), // Adapter's token0
            address(tLow),  // Adapter's token1
            address(router),
            address(reversedPair)
        );

        // Set Reserves in the Pair
        // Pair: token0(tLow)=100, token1(tHigh)=50
        uint112 resLow = 100 ether;
        uint112 resHigh = 50 ether;
        reversedPair.setReserves(resLow, resHigh);

        // Give the adapter 100% of the LP supply for simplicity
        uint256 lpAmount = 10 ether;
        reversedPair.mintLp(address(reversedAdapter), lpAmount);

        (uint256 amount0, uint256 amount1) = reversedAdapter.getPositionValue();

        // amount0 (Adapter's tHigh) should be 50
        // amount1 (Adapter's tLow) should be 100
        assertEq(amount0, uint256(resHigh), "Token0 should map to Pair's reserve1");
        assertEq(amount1, uint256(resLow), "Token1 should map to Pair's reserve0");
    }

    /// @notice Verifies `getPositionValue` reverts when the pair reports LP balances with zero total supply.
    function test_GetPositionValue_RevertsWhenTotalSupplyIsZero() public {
        BrokenUniswapV2Pair brokenPair = new BrokenUniswapV2Pair(address(token0), address(token1));
        UniswapV2Adapter brokenAdapter = new UniswapV2Adapter(
            vault,
            address(token0),
            address(token1),
            address(router),
            address(brokenPair)
        );

        brokenPair.setBalance(address(brokenAdapter), 1 ether);
        brokenPair.setReserves(100 ether, 50 ether);

        vm.expectRevert(UniswapV2Adapter.InvalidTotalSupply.selector);
        brokenAdapter.getPositionValue();
    }

    /// @notice Verifies `getPositionValue` is intentionally readable by non-vault callers.
    function test_GetPositionValue_CanBeReadByNonVaultCaller() public {
        pair.mintLp(address(adapter), 10 ether);
        pair.setReserves(100 ether, 50 ether);

        vm.prank(address(0xCAFE));
        (uint256 amount0, uint256 amount1) = adapter.getPositionValue();

        assertEq(amount0, 100 ether);
        assertEq(amount1, 50 ether);
    }

    /// @notice Verifies only the vault can add liquidity through the adapter.
    function test_AddLiquidity_RevertsWhenCallerIsNotVault() public {
        vm.expectRevert(UniswapV2Adapter.NotVault.selector);
        adapter.addLiquidity(10 ether, 5 ether, "");
    }

    /// @notice Verifies zero-value liquidity additions are rejected.
    function test_AddLiquidity_RevertsWhenBothAmountsAreZero() public {
        vm.prank(vault);
        vm.expectRevert(UniswapV2Adapter.ZeroAmounts.selector);
        adapter.addLiquidity(0, 0, "");
    }

    /// @notice Verifies venue-specific params are currently unsupported.
    function test_AddLiquidity_RevertsWhenParamsAreNonEmpty() public {
        bytes memory fakeParams = abi.encodePacked("Some extra data");
        vm.expectRevert(UniswapV2Adapter.UnsupportedOperation.selector);
        vm.prank(vault);
        adapter.addLiquidity(0, 50 ether, fakeParams);
    }

    /// @notice Verifies only the vault can remove liquidity through the adapter.
    function test_RemoveLiquidity_RevertsWhenCallerIsNotVault() public {
        vm.expectRevert(UniswapV2Adapter.NotVault.selector);
        adapter.removeLiquidity(5 ether);
    }

    /// @notice Verifies zero-liquidity removals are rejected.
    function test_RemoveLiquidity_RevertsWhenLiquidityIsZero() public {
        vm.expectRevert(UniswapV2Adapter.ZeroLiquidity.selector);
        vm.prank(vault);
        adapter.removeLiquidity(0);
    }

    /// @notice Verifies liquidity removal cannot exceed the adapter's LP balance.
    function test_RemoveLiquidity_RevertsWhenLiquidityExceedsLpBalance() public {
        uint256 adapterLp = 10 ether; 
        uint256 liquidity = 50 ether;
        pair.mintLp(address(adapter), adapterLp);
        vm.expectRevert(UniswapV2Adapter.InsufficientLpBalance.selector);
        vm.prank(vault);
        adapter.removeLiquidity(liquidity);
    }

    /// @notice Verifies successful adds leave the minted LP tokens on the adapter.
    function test_AddLiquidity_MintsLpTokensToAdapter() public {
        uint256 expectedLiquidity = 5 ether;
        // Mint tokens to vault
        uint256 amount0 = 10 ether;
        uint256 amount1 = 10 ether;
        token0.mint(vault, amount0);
        token1.mint(vault, amount1);

        vm.startPrank(vault);
        token0.approve(address(adapter), amount0);
        token1.approve(address(adapter), amount1);

        uint256 adapterLpBefore = pair.balanceOf(address(adapter));
        assertEq(adapterLpBefore, 0, "Adapter should start with 0 LP tokens");

        router.setNextAddLiquidityResult(amount0, amount1, expectedLiquidity);
        adapter.addLiquidity(amount0, amount1, "");
        vm.stopPrank();

        uint256 adapterLpAfter = pair.balanceOf(address(adapter));
        assertEq(adapterLpAfter, expectedLiquidity, "Adapter failed to receive the correct amount of LP tokens");
    }

    /// @notice Verifies the adapter pulls the requested tokens from the vault and only unused dust remains there.
    function test_AddLiquidity_PullsTokensFromVault() public {
        // Input token amounts
        uint256 amount0 = 10e18;
        uint256 amount1 = 20e6;

        // token amounts used by router
        uint256 amount0Used = 8e18;
        uint256 amount1Used = 15e6;
        uint256 liquidityMinted = 5e18;

        token0.mint(vault, amount0);
        token1.mint(vault, amount1);

        vm.startPrank(vault);
        token0.approve(address(adapter), amount0);
        token1.approve(address(adapter), amount1);

        router.setNextAddLiquidityResult(amount0Used, amount1Used, liquidityMinted);
        adapter.addLiquidity(amount0, amount1, "");
        vm.stopPrank();

        assertEq(token0.balanceOf(address(vault)), amount0 - amount0Used);
        assertEq(token1.balanceOf(address(vault)), amount1 - amount1Used);
    }


    /// @notice Verifies any token amounts not consumed by the router are returned to the vault.
    function test_AddLiquidity_ReturnsUnusedDustToVault() public {
        uint256 initial0 = 100e18;
        uint256 initial1 = 200e6;

        uint256 amount0 = 10e18;
        uint256 amount1 = 20e6;

        // token amounts used by router
        uint256 used0 = 8e18;
        uint256 used1 = 15e6;
        uint256 liquidityMinted = 5e18;

        uint256 unused0 = amount0 - used0;
        uint256 unused1 = amount1 - used1;

        token0.mint(vault, initial0);
        token1.mint(vault, initial1);

        vm.startPrank(vault);
        token0.approve(address(adapter), amount0);
        token1.approve(address(adapter), amount1);

        router.setNextAddLiquidityResult(used0, used1, liquidityMinted);

        adapter.addLiquidity(amount0, amount1, "");
        vm.stopPrank();

        assertEq(token0.balanceOf(vault), initial0 - amount0 + unused0);
        assertEq(token1.balanceOf(vault), initial1 - amount1 + unused1);
    }

    /// @notice Verifies successful removals send the withdrawn underlying tokens back to the vault.
    function test_RemoveLiquidity_ReturnsUnderlyingTokensToVault() public {
        uint256 initialLp = 10e18;
        uint256 liquidityToRemove = 4e18;
        uint256 amount0Out = 3e18;
        uint256 amount1Out = 7e6;

        assertEq(token0.balanceOf(vault), 0);
        assertEq(token1.balanceOf(vault), 0);

        pair.mintLp(address(adapter), initialLp);
        router.setNextRemoveLiquidityResult(amount0Out, amount1Out);

        vm.prank(vault);
        (uint256 actual0, uint256 actual1) = adapter.removeLiquidity(liquidityToRemove);

        assertEq(actual0, amount0Out);
        assertEq(actual1, amount1Out);
        assertEq(token0.balanceOf(vault), amount0Out);
        assertEq(token1.balanceOf(vault), amount1Out);

        assertEq(pair.balanceOf(address(adapter)), initialLp - liquidityToRemove);
    }
}