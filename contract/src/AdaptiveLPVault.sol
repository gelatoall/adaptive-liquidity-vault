// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;


import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./libraries/VaultMath.sol";

/// @title AdaptiveLPVault
/// @notice Minimal idle two-asset vault that mints ERC20 shares against deposited assets.
contract AdaptiveLPVault is ERC20 {
    using SafeERC20 for IERC20;

    IERC20 public immutable token0;
    IERC20 public immutable token1;

    uint8 public immutable decimals0;
    uint8 public immutable decimals1;

    uint256 public price0;
    uint256 public price1;

    // ============================================
    // Events
    // ============================================
    event Deposit(address indexed user, uint256 amount0, uint256 amount1);
    event Redeem(address indexed user, uint256 shares);

    // ============================================
    // Custom Errors
    // ============================================
    error ZeroAddress();
    error ZeroDecimals();
    error ZeroPrice();
    error ZeroAmounts();
    error ZeroShares();
    error InsufficientShares();

    // ============================================
    // Constructor
    // ============================================
    /// @param _name Share token name.
    /// @param _symbol Share token symbol.
    /// @param _token0 Address of the first underlying token.
    /// @param _token1 Address of the second underlying token.
    /// @param _decimals0 Decimals used by token0 amounts.
    /// @param _decimals1 Decimals used by token1 amounts.
    constructor(
        string memory _name,
        string memory _symbol,
        address _token0, 
        address _token1, 
        uint8 _decimals0, 
        uint8 _decimals1
    ) ERC20(_name, _symbol) {
        if (_token0 == address(0) || _token1 == address(0)) {
            revert ZeroAddress();
        }

        if (_decimals0 == 0 || _decimals1 == 0) {
            revert ZeroDecimals();
        }

        token0 = IERC20(_token0);
        token1 = IERC20(_token1);
        decimals0 = _decimals0;
        decimals1 = _decimals1;
    }

    /// @notice Sets mock prices for token0 and token1.
    /// @dev Prices are denominated in the base asset and use 1e18 precision.
    /// @param _price0 Price of one whole token0.
    /// @param _price1 Price of one whole token1.
    function setPrice(uint256 _price0, uint256 _price1) external {
        if (_price0 == 0 || _price1 == 0) {
            revert ZeroPrice();
        }
        price0 = _price0;
        price1 = _price1;
    }

    /// @notice Deposits token0 and token1 and mints vault shares to the caller.
    /// @dev Deposit flow is token amounts -> normalized asset value -> shares.
    /// @param amount0 Raw token0 amount in token0's smallest unit.
    /// @param amount1 Raw token1 amount in token1's smallest unit.
    /// @return shares Amount of vault shares minted to the depositor.
    function deposit(uint256 amount0, uint256 amount1) external returns (uint256 shares) {
        // Reject if both deposit amounts are zero.
        if (amount0 == 0 && amount1 == 0) {
            revert ZeroAmounts();
        }

        // Read totalAssets() before the deposit.
        // Read totalSupply() before the deposit.
        uint256 totalAssetsBefore = totalAssets();
        uint256 totalShares = totalSupply();

        // Convert the deposit amounts into a single base-denominated value using VaultMath.
        uint256 assetsToDeposit = VaultMath.getAssetsTotalValue(
            amount0, price0, decimals0, 
            amount1, price1, decimals1
        );

        // Calculate shares to mint using VaultMath.calculateShares.
        shares = VaultMath.calculateShares(assetsToDeposit, totalAssetsBefore, totalShares);
        
        // Transfer token0 and token1 from the user into the vault.
        IERC20(token0).safeTransferFrom(msg.sender, address(this), amount0);
        IERC20(token1).safeTransferFrom(msg.sender, address(this), amount1);

        // Mint shares to the depositor.
        _mint(msg.sender, shares);

        emit Deposit(msg.sender, amount0, amount1);
    } 

    /// @notice Redeems vault shares for the proportional underlying token balances.
    /// @dev Redeem flow is shares -> ownership ratio -> token amounts.
    /// @param shareToRedeem Amount of vault shares to redeem.
    /// @return amount0Out Raw token0 amount returned to the caller.
    /// @return amount1Out Raw token1 amount returned to the caller.
    function redeem(uint256 shareToRedeem) external returns (uint256 amount0Out, uint256 amount1Out) {
        // Reject if shares is zero.
        if (shareToRedeem == 0) {
            revert ZeroShares();
        }

        // Revert if the share to redeem exceeds the caller's balance.
        if (shareToRedeem > balanceOf(msg.sender)) {
            revert InsufficientShares();
        }
        
        // Read totalSupply() before burning.
        uint256 totalSharesBefore = totalSupply();

        // Read the current token0 and token1 balances held by the vault.
        uint256 vaultToken0Amount = IERC20(token0).balanceOf(address(this));
        uint256 vaultToken1Amount = IERC20(token1).balanceOf(address(this));
        
        // Compute the proportional token amounts owed to the user.
        amount0Out = shareToRedeem * vaultToken0Amount / totalSharesBefore;
        amount1Out = shareToRedeem * vaultToken1Amount / totalSharesBefore;

        // Burn the user's share-to-redeem.
        _burn(msg.sender, shareToRedeem);

        // Transfer token0 and token1 to the user.
        IERC20(token0).safeTransfer(msg.sender, amount0Out);
        IERC20(token1).safeTransfer(msg.sender, amount1Out);

        emit Redeem(msg.sender, shareToRedeem);
    }

    // ============================================
    // View Functions
    // ============================================
    /// @notice Returns the current total value of the vault's holdings.
    /// @dev The returned value is denominated in the base asset and uses 1e18 precision.
    function totalAssets() public view returns (uint256) {
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        return VaultMath.getAssetsTotalValue(
            balance0, price0, decimals0, 
            balance1, price1, decimals1
        );
    }
}
