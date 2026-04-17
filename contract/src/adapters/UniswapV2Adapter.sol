// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IUniswapV2Pair.sol";
import "../interfaces/IUniswapV2Router.sol";
import "../AdaptiveLPVault.sol";

contract UniswapV2Adapter {
    using SafeERC20 for IERC20;

    // ============================================
    // State Variables
    // ============================================

    /// @dev Uniswap V2 Pair
    IUniswapV2Pair public immutable pair;
    
    /// @dev Uniswap V2 Router
    IUniswapV2Router public immutable router;

    AdaptiveLPVault public immutable vault;

    IERC20 public immutable token0;
    IERC20 public immutable token1;

    // ============================================
    // Events
    // ============================================
    event AddLiquidity(address indexed caller, uint256 amount0, uint256 amount1);
    event RemoveLiquidity(address indexed caller, uint256 liquidity);

    // ============================================
    // Custom Errors
    // ============================================
    error NotVault();
    error ZeroAddress();
    error ZeroAmounts();
    error ZeroLiquidity();
    error InvalidPair();
    error InsufficientLiquidity();
    error UnsupportedOperation();

    // ============================================
    // Modifiers
    // ============================================
    modifier onlyVault() {
        if (msg.sender != address(vault)) revert NotVault();
        _;
    }

    // ============================================
    // Constructor
    // ============================================
    constructor(
        address _vault,
        address _token0,
        address _token1,
        address _router,
        address _pair
    ) {
        if (_vault == address(0) || _router == address(0) || _pair == address(0) 
            || _token0 == address(0) || _token1 == address(0)) {
            revert ZeroAddress();
        }

        vault = AdaptiveLPVault(_vault);
        token0 = IERC20(_token0);
        token1 = IERC20(_token1);
        router = IUniswapV2Router(_router);
        pair = IUniswapV2Pair(_pair);

        bool directOrder = (pair.token0() == address(token0) && pair.token1() == address(token1));
        bool reverseOrder = (pair.token0() == address(token1) && pair.token1() == address(token0));
        if (!(directOrder || reverseOrder)) {
            revert InvalidPair();
        }
    }

    // ============================================
    // Functions
    // ============================================
    /// @notice Add liquidity to the venue
    /// @param amount0 Raw token0 amount to deploy
    /// @param amount1 Raw token1 amount to deploy
    /// @param params Venue-specific encoded parameters for future extensibility
    /// @return liquidity Amount of liquidity added (LP tokens or position size)
    function addLiquidity(
        uint256 amount0,
        uint256 amount1,
        bytes calldata params
    ) external onlyVault returns (uint256 liquidity) {
        if (params.length != 0) revert UnsupportedOperation();
        
        // Reject if both token amounts are zero.
        if (amount0 == 0 && amount1 == 0) {
            revert ZeroAmounts();
        }

        // 是否需要先check token0 和 token1 的顺序？

        // Pull `token0` and `token1` from the vault.
        IERC20(token0).safeTransferFrom(address(vault), address(this), amount0);
        IERC20(token1).safeTransferFrom(address(vault), address(this), amount1);

        // Approve the router for token usage.
        IERC20(token0).forceApprove(address(router), amount0);
        IERC20(token1).forceApprove(address(router), amount1);

        // Call the V2 router to add liquidity.
        uint256 amount0Min = 0;
        uint256 amount1Min = 0;
        uint256 deadline = block.timestamp;
        uint256 amount0Used;
        uint256 amount1Used;
        (amount0Used, amount1Used, liquidity) = router.addLiquidity(
            address(token0), address(token1), 
            amount0, amount1, 
            amount0Min, amount1Min, 
            address(this), 
            deadline
        );
        
        // Record or infer the minted LP tokens.
        // Keep LP tokens in the adapter.
        // Return any unused token dust to the vault.
        uint256 dust0 = amount0 - amount0Used;
        uint256 dust1 = amount1 - amount1Used;
        if (dust0 > 0) {
            IERC20(token0).safeTransfer(address(vault), dust0);
        }
        if (dust1 > 0) {
            IERC20(token1).safeTransfer(address(vault), dust1);
        }

        emit AddLiquidity(msg.sender, amount0, amount1);
    }

    /// @notice Remove liquidity from the venue
    /// @param liquidity Amount of LP tokens or position liquidity to remove
    /// @return amount0 Token0 received
    /// @return amount1 Token1 received
    function removeLiquidity(uint256 liquidity) external onlyVault returns (uint256 amount0, uint256 amount1) {
        // Reject if liquidity is zero.
        if (liquidity == 0) {
            revert ZeroLiquidity();
        }

        // Reject if liquidity exceeds the adapter's LP balance.
        uint256 lpBalance = pair.balanceOf(address(this)); //为啥这里不是address(pair)
        if (liquidity > lpBalance) {
            revert InsufficientLiquidity();
        }

        // Approve the router to spend LP tokens.
        IERC20(address(pair)).forceApprove(address(router), liquidity);

        // Call the V2 router to remove liquidity.
        uint256 amount0Min = 0;
        uint256 amount1Min = 0;
        uint256 deadline = block.timestamp;
        (amount0, amount1) = router.removeLiquidity(
            address(token0), address(token1), 
            liquidity, 
            amount0Min, amount1Min, 
            address(this), 
            deadline
        );

        // Receive `token0` and `token1` back from the pair.
        // Transfer withdrawn `token0` and `token1` back to the vault (adpater -> vault).
        if (amount0 > 0) {
            IERC20(token0).safeTransfer(address(vault), amount0);
        }
        if (amount1 > 0) {
            IERC20(token1).safeTransfer(address(vault), amount1);
        }

        emit RemoveLiquidity(msg.sender, liquidity);
    }

    /// @notice Collect any accumulated fees if the venue supports explicit fee collection
    function collectFees() external returns (uint256 fees0, uint256 fees1) {
        revert UnsupportedOperation();
    }

    /// @notice Get the underlying token balances represented by the current position
    function getPositionValue() external onlyVault view returns (uint256 amount0, uint256 amount1) {
        // Read the adapter's LP token balance.
        uint256 lpBalance = pair.balanceOf(address(this));
        if (lpBalance == 0) {
            return (0, 0); 
        }

        // Read the pair reserves and total LP supply.
        (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();
        uint256 totalLpBalance = pair.totalSupply();
        
        // Compute the adapter's proportional share of reserve0 and reserve1.
        uint256 proportional0 = reserve0 * lpBalance / totalLpBalance;
        uint256 proportional1 = reserve1 * lpBalance / totalLpBalance;
        
        // Return the underlying token amounts.
        if (address(token0) == pair.token0()) {
            amount0 = proportional0;
            amount1 = proportional1;
        } else {
            amount0 = proportional1;
            amount1 = proportional0;
        }
    }

    /// @notice Check if venue has active position
    function hasPosition() external view returns (bool) {
        return pair.balanceOf(address(this)) > 0;
    }
}