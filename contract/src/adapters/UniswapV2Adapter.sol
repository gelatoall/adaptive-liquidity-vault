// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IUniswapV2Pair.sol";
import "../interfaces/IUniswapV2Router.sol";
import "../interfaces/IVenueAdapter.sol";

/// @title UniswapV2Adapter
/// @notice Minimal venue adapter that manages one Uniswap V2 LP position for a vault.
/// @dev The adapter holds the LP tokens itself and returns underlying tokens back to the vault on withdrawal.
contract UniswapV2Adapter is IVenueAdapter {
    using SafeERC20 for IERC20;

    // ============================================
    // State Variables
    // ============================================

    /// @notice Uniswap V2 pair used for LP accounting and reserve reads.
    IUniswapV2Pair public immutable pair;
    
    /// @notice Uniswap V2 router used for add/remove liquidity execution.
    IUniswapV2Router public immutable router;

    /// @notice Trusted caller allowed to move capital through the adapter.
    /// @dev Stored as a plain address because the adapter only needs caller authentication and token transfers.
    address public immutable vault;

    /// @notice First vault asset configured for this adapter.
    IERC20 public immutable token0;

    /// @notice Second vault asset configured for this adapter.
    IERC20 public immutable token1;

    // ============================================
    // Events
    // ============================================
    /// @notice Emitted after liquidity is successfully added through the router.
    /// @param caller Address that initiated the call. In the intended flow this is the vault.
    /// @param requestedAmount0 Token0 amount requested by the vault.
    /// @param requestedAmount1 Token1 amount requested by the vault.
    /// @param usedAmount0 Token0 amount actually consumed by the router.
    /// @param usedAmount1 Token1 amount actually consumed by the router.
    /// @param mintedLiquidity LP amount minted to the adapter.
    event LiquidityAdded(
        address indexed caller,
        uint256 requestedAmount0,
        uint256 requestedAmount1,
        uint256 usedAmount0,
        uint256 usedAmount1,
        uint256 mintedLiquidity
    );

    /// @notice Emitted after liquidity is successfully removed through the router.
    /// @param caller Address that initiated the call. In the intended flow this is the vault.
    /// @param burnedLiquidity LP amount requested for removal and burned through the router.
    /// @param amount0Out Token0 amount returned by the router.
    /// @param amount1Out Token1 amount returned by the router.
    event LiquidityRemoved(
        address indexed caller,
        uint256 burnedLiquidity,
        uint256 amount0Out,
        uint256 amount1Out
    );

    // ============================================
    // Custom Errors
    // ============================================
    /// @notice Thrown when a non-vault caller attempts a vault-only action.
    error NotVault();

    /// @notice Thrown when a required constructor address is zero.
    error ZeroAddress();

    /// @notice Thrown when both token amounts are zero for an add-liquidity call.
    error ZeroAmounts();

    /// @notice Thrown when the requested LP amount to remove is zero.
    error ZeroLiquidity();

    /// @notice Thrown when the configured pair does not contain exactly the configured token set.
    error InvalidPair();

    /// @notice Thrown when the adapter observes LP balance but the pair reports zero total supply.
    error InvalidTotalSupply();

    /// @notice Thrown when a remove-liquidity request exceeds the adapter's LP balance.
    error InsufficientLpBalance();

    /// @notice Thrown when a function is intentionally unsupported in the minimal implementation.
    error UnsupportedOperation();

    // ============================================
    // Modifiers
    // ============================================
    /// @dev Restricts state-changing capital movement to the configured vault caller.
    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

    // ============================================
    // Constructor
    // ============================================
    /// @param _vault Trusted vault address allowed to move funds through the adapter.
    /// @param _token0 Address of the first configured asset.
    /// @param _token1 Address of the second configured asset.
    /// @param _router Address of the Uniswap V2 router used for execution.
    /// @param _pair Address of the Uniswap V2 pair used for reserve and LP accounting.
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

        vault = _vault;
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
    /// @inheritdoc IVenueAdapter
    /// @dev `params` is reserved for future venue-specific options and must be empty in this minimal version.
    function addLiquidity(
        uint256 amount0,
        uint256 amount1,
        bytes calldata params
    ) external override onlyVault returns (uint256 liquidity) {
        if (params.length != 0) revert UnsupportedOperation();
        
        // Reject if both token amounts are zero.
        if (amount0 == 0 && amount1 == 0) {
            revert ZeroAmounts();
        }

        // Adapter pulls `token0` and `token1` from the vault.
        token0.safeTransferFrom(vault, address(this), amount0);
        token1.safeTransferFrom(vault, address(this), amount1);

        // Adapter approves the router for token usage.
        token0.forceApprove(address(router), amount0);
        token1.forceApprove(address(router), amount1);

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
            token0.safeTransfer(vault, dust0);
        }
        if (dust1 > 0) {
            token1.safeTransfer(vault, dust1);
        }

        // Clear approval
        token0.forceApprove(address(router), 0);
        token1.forceApprove(address(router), 0);

        emit LiquidityAdded(msg.sender, amount0, amount1, amount0Used, amount1Used, liquidity);
    }

    /// @inheritdoc IVenueAdapter
    function removeLiquidity(uint256 liquidity) external override onlyVault returns (uint256 amount0, uint256 amount1) {
        // Reject if liquidity is zero.
        if (liquidity == 0) {
            revert ZeroLiquidity();
        }

        // Reject if liquidity exceeds the adapter's LP balance.
        uint256 lpBalance = pair.balanceOf(address(this));
        if (liquidity > lpBalance) {
            revert InsufficientLpBalance();
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
            token0.safeTransfer(vault, amount0);
        }
        if (amount1 > 0) {
            token1.safeTransfer(vault, amount1);
        }

        // Clear approval
        IERC20(address(pair)).forceApprove(address(router), 0);

        emit LiquidityRemoved(msg.sender, liquidity, amount0, amount1);
    }

    /// @inheritdoc IVenueAdapter
    /// @dev Uniswap V2 realizes fees inside LP position value rather than through a separate claim step.
    function collectFees() external pure override returns (uint256, uint256) {
        revert UnsupportedOperation();
    }

    /// @inheritdoc IVenueAdapter
    /// @dev This function is intentionally public because the returned information is already derivable from public on-chain pair state.
    function getPositionValue() external override view returns (uint256 amount0, uint256 amount1) {
        // Read the adapter's LP token balance.
        uint256 lpBalance = pair.balanceOf(address(this));
        if (lpBalance == 0) {
            return (0, 0); 
        }

        // Read the pair reserves and total LP supply.
        (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();
        uint256 totalLpBalance = pair.totalSupply();
        if (totalLpBalance == 0) {
            revert InvalidTotalSupply();
        }
        
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

    /// @inheritdoc IVenueAdapter
    function hasPosition() external override view returns (bool) {
        return pair.balanceOf(address(this)) > 0;
    }
}
