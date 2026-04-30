// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./libraries/VaultMath.sol";
import "./interfaces/IVenueAdapter.sol";
import "./interfaces/IPriceOracle.sol";

/// @title AdaptiveLPVault
/// @notice Minimal two-asset vault that mints ERC20 shares against deposited assets.
/// @dev The vault can keep assets idle or deploy them to a single venue adapter.
contract AdaptiveLPVault is ERC20, Ownable {
    using SafeERC20 for IERC20;

    /// @notice First underlying token accepted by the vault.
    IERC20 public immutable token0;
    /// @notice Second underlying token accepted by the vault.
    IERC20 public immutable token1;

    /// @notice Decimals used to interpret raw token0 amounts.
    uint8 public immutable decimals0;
    /// @notice Decimals used to interpret raw token1 amounts.
    uint8 public immutable decimals1;

    /// @notice Price oracle used to calculate the value of underlying holdings.
    /// @dev The vault depends on the IPriceOracle interface for price discovery.
    IPriceOracle public oracle;

    /// @notice Venue adapter used to deploy and withdraw liquidity.
    /// @dev The vault depends on the adapter interface, not a concrete adapter implementation.
    IVenueAdapter public adapter;

    // ============================================
    // Events
    // ============================================
    /// @notice Emitted when a user deposits token0 and token1 into the vault.
    /// @param user Depositor receiving newly minted vault shares.
    /// @param amount0 Raw token0 amount transferred into the vault.
    /// @param amount1 Raw token1 amount transferred into the vault.
    event Deposit(address indexed user, uint256 amount0, uint256 amount1);

    /// @notice Emitted when a user redeems vault shares for underlying tokens.
    /// @param user Redeemer whose vault shares are burned.
    /// @param shares Raw share amount burned during redemption.
    event Redeem(address indexed user, uint256 shares);

    /// @notice Emitted when the vault deploys idle funds into the configured venue adapter.
    /// @param amount0 Requested raw token0 amount sent to the adapter flow.
    /// @param amount1 Requested raw token1 amount sent to the adapter flow.
    /// @param liquidity Venue liquidity reported by the adapter.
    event DeployToVenue(uint256 amount0, uint256 amount1, uint256 liquidity);

    /// @notice Emitted when the vault withdraws venue liquidity back into idle balances.
    /// @param liquidity Raw venue liquidity removed by the adapter.
    /// @param amount0Out Raw token0 amount returned to the vault.
    /// @param amount1Out Raw token1 amount returned to the vault.
    event WithdrawFromVenue(uint256 liquidity, uint256 amount0Out, uint256 amount1Out);

    // ============================================
    // Custom Errors
    // ============================================
    /// @notice Thrown when an address argument is the zero address.
    error ZeroAddress();

    /// @notice Thrown when either configured token decimals value is zero.
    error ZeroDecimals();

    /// @notice Thrown when both token deposit amounts are zero.
    error ZeroAmounts();

    /// @notice Thrown when a caller tries to redeem zero shares.
    error ZeroShares();

    /// @notice Thrown when a caller tries to redeem more shares than they own.
    error InsufficientShares();

    /// @notice Thrown when a valuation or price-dependent operation is requested before an oracle is configured.
    error OracleNotSet();

    /// @notice Thrown when a venue operation is requested before an adapter is configured.
    error AdapterNotSet();

    /// @notice Thrown when redemption is attempted while funds remain deployed in the adapter.
    error ActivePositionExists();

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
    ) ERC20(_name, _symbol) Ownable(msg.sender) {
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

        // Reject if oracle is not configured.
        if (address(oracle) == address(0)) {
            revert OracleNotSet();
        }
        (uint256 price0, uint256 price1) = oracle.getPrices();

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
    /// @dev Redemption is blocked while the adapter still has an active deployed position.
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

        // Minimal integration rule:
        // if funds are currently deployed, force owner/admin to withdraw first.
        if (address(adapter) != address(0) && adapter.hasPosition()) {
            revert ActivePositionExists();
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
    /// @dev Includes both idle vault balances and adapter-reported deployed underlying amounts.
    /// The returned value is denominated in the base asset and uses 1e18 precision.
    /// @return Total vault asset value using the currently configured mock prices.
    function totalAssets() public view returns (uint256) {
        // Reject if oracle is not configured.
        if (address(oracle) == address(0)) {
            revert OracleNotSet();
        }
        (uint256 price0, uint256 price1) = oracle.getPrices();

        uint256 idle0 = IERC20(token0).balanceOf(address(this));
        uint256 idle1 = IERC20(token1).balanceOf(address(this));
        
        uint256 deployed0 = 0;
        uint256 deployed1 = 0;
        if (address(adapter) != address(0)) {
            (deployed0, deployed1) = adapter.getPositionValue();
        }

        uint256 total0 = idle0 + deployed0;
        uint256 total1 = idle1 + deployed1;
        
        return VaultMath.getAssetsTotalValue(
            total0, price0, decimals0, 
            total1, price1, decimals1
        );
    }

    // ============================================
    // Admin Functions
    // ============================================
    /// @notice Sets the price oracle used by the vault for asset valuation.
    /// @dev The input address is stored as an `IPriceOracle` interface reference.
    /// @param _oracle Address of the price oracle contract.
    function setOracle(address _oracle) external onlyOwner {
        if (_oracle == address(0)) {
            revert ZeroAddress();
        }
        oracle = IPriceOracle(_oracle);
    }

    /// @notice Sets the venue adapter used by the vault.
    /// @dev The input address is stored as an `IVenueAdapter` interface reference.
    /// @param _adapter Address of the adapter contract.
    function setAdapter(address _adapter) external onlyOwner {
        if (_adapter == address(0)) {
            revert ZeroAddress();
        }
        adapter = IVenueAdapter(_adapter);
    }

    /// @notice Deploys idle vault funds into the configured venue adapter.
    /// @dev The vault temporarily approves the adapter to pull the requested token amounts.
    /// @param amount0 Raw token0 amount the vault attempts to deploy.
    /// @param amount1 Raw token1 amount the vault attempts to deploy.
    /// @param params Venue-specific encoded parameters forwarded to the adapter.
    /// @return liquidity Venue liquidity amount reported by the adapter.
    function deployToVenue(
        uint256 amount0, 
        uint256 amount1,
        bytes calldata params
    ) external onlyOwner returns (uint256 liquidity) {
        if (address(adapter) == address(0)) {
            revert AdapterNotSet();
        }

        token0.forceApprove(address(adapter), amount0);
        token1.forceApprove(address(adapter), amount1);

        liquidity = adapter.addLiquidity(amount0, amount1, params);

        token0.forceApprove(address(adapter), 0);
        token1.forceApprove(address(adapter), 0);

        emit DeployToVenue(amount0, amount1, liquidity);
    }

    /// @notice Withdraws deployed liquidity from the configured venue adapter back into the vault.
    /// @param liquidity Raw venue liquidity amount to remove.
    /// @return amount0Out Raw token0 amount returned to the vault.
    /// @return amount1Out Raw token1 amount returned to the vault.
    function withdrawFromVenue(uint256 liquidity) external onlyOwner returns (uint256 amount0Out, uint256 amount1Out) {
        if (address(adapter) == address(0)) {
            revert AdapterNotSet();
        }

        (amount0Out, amount1Out) = adapter.removeLiquidity(liquidity);
        
        emit WithdrawFromVenue(liquidity, amount0Out, amount1Out);
    }
}
