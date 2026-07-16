// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../libraries/v3/TickMath.sol";
import "../libraries/v3/LiquidityAmounts.sol";
import "../interfaces/IVenueAdapter.sol";
import "../interfaces/INonfungiblePositionManager.sol";
import "../interfaces/IUniswapV3Pool.sol";

/// @title Uniswap V3 adapter
/// @notice Minimal venue adapter that manages a single Uniswap V3 position for one vault.
/// @dev The adapter assumes a fixed token pair and fee tier. Constructor ticks are defaults that add-liquidity params can override when minting.
contract UniswapV3Adapter is IVenueAdapter {
    using SafeERC20 for IERC20;

    // ============================================
    // State Variables
    // ============================================
    /// @notice Vault that is allowed to manage this adapter.
    address public immutable vault;

    /// @notice Vault token 0.
    IERC20 public immutable token0;
    /// @notice Vault token 1.
    IERC20 public immutable token1;

    /// @notice Uniswap V3 position manager used to mint, increase, decrease, collect, and burn the NFT position.
    INonfungiblePositionManager public immutable positionManager; 
    /// @notice Target Uniswap V3 pool for this adapter.
    IUniswapV3Pool public immutable pool;

    /// @notice Default lower tick bound used when add-liquidity params do not override the range.
    int24 public immutable defaultTickLower;
    /// @notice Default upper tick bound used when add-liquidity params do not override the range.
    int24 public immutable defaultTickUpper;

    /// @notice Current active position tokenId, or zero when no position is active.
    uint256 public tokenId;

    /// @notice Slippage and deadline controls for V3 add/remove liquidity execution.
    /// @dev Minimum amounts are expressed in vault token order and mapped into pool token order internally.
    struct LiquidityParams {
        /// @notice Minimum amount of vault token 0 that may be used.
        uint256 amount0Min;
        /// @notice Minimum amount of vault token 1 that may be used.
        uint256 amount1Min;
        /// @notice Deadline for the mint/increase call.
        uint256 deadline;
        /// @notice Lower tick bound used when minting a new position.
        int24 tickLower;
        /// @notice Upper tick bound used when minting a new position.
        int24 tickUpper;
    }

    /// @notice Internal execution context for add-liquidity operations.
    /// @dev Holds the pool-ordered tokens and amounts so the orchestration layer stays thin.
    struct AddLiquidityContext {
        /// @notice Pool-ordered token 0.
        address poolToken0;
        /// @notice Pool-ordered token 1.
        address poolToken1;
        /// @notice Desired amount of pool token 0.
        uint256 poolAmount0Desired;
        /// @notice Desired amount of pool token 1.
        uint256 poolAmount1Desired;
        /// @notice Minimum amount of pool token 0.
        uint256 poolAmount0Min;
        /// @notice Minimum amount of pool token 1.
        uint256 poolAmount1Min;
        /// @notice Deadline for the position manager call.
        uint256 deadline;
        /// @notice Lower tick bound for a newly minted position.
        int24 tickLower;
        /// @notice Upper tick bound for a newly minted position.
        int24 tickUpper;
    }

    // ============================================
    // Events
    // ============================================
    /// @notice Emitted after liquidity is added to the managed position.
    event LiquidityAdded(address indexed caller, uint256 amount0, uint256 amount1, uint256 liquidity, uint256 tokenId);

    /// @notice Emitted after liquidity is removed from the managed position.
    event LiquidityRemoved(address indexed caller, uint256 liquidity, uint256 amount0, uint256 amount1);

    /// @notice Emitted after collectable fees or owed amounts are collected.
    event FeesCollected(address indexed caller, uint256 fees0, uint256 fees1);

    // ============================================
    // Custom Errors
    // ============================================
    /// @notice Thrown when a non-vault caller attempts to mutate state.
    error NotVault();
    /// @notice Thrown when an address parameter is zero.
    error ZeroAddress();
    /// @notice Thrown when both liquidity add amounts are zero.
    error ZeroAmounts();
    /// @notice Thrown when liquidity removal amount is zero.
    error ZeroLiquidity();
    /// @notice Thrown when the configured tick range is invalid.
    error InvalidTicks();
    /// @notice Thrown when a tick is not aligned to the pool tick spacing.
    error InvalidTickSpacing();
    /// @notice Thrown when the configured pool does not match the configured tokens.
    error InvalidPool();
    /// @notice Thrown when no active or stale position exists for the requested operation.
    error NoPosition();
    /// @notice Thrown when a liquidity removal is requested but the position has no removable liquidity.
    error NoLiquidityToRemove();
    /// @notice Thrown when attempting to remove more liquidity than the position holds.
    error InsufficientPositionLiquidity();
    /// @notice Thrown when increasing an existing position with a different tick range.
    error TickRangeMismatch();

    // ============================================
    // Modifiers
    // ============================================
    /// @notice Restricts a function to the configured vault.
    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

    // ============================================
    // Constructor
    // ============================================
    /// @notice Deploys a new Uniswap V3 adapter for a fixed token pair and tick range.
    /// @param _vault Vault that will control the adapter.
    /// @param _token0 Vault token 0.
    /// @param _token1 Vault token 1.
    /// @param _positionManager Uniswap V3 position manager used for NFT position lifecycle operations.
    /// @param _pool Uniswap V3 pool associated with the configured token pair.
    /// @param _tickLower Default lower tick bound used when params do not override the range.
    /// @param _tickUpper Default upper tick bound used when params do not override the range.
    /// @dev Reverts if any address is zero, if tick bounds are invalid or not spacing-aligned, or if the pool token set does not match the configured tokens.
    constructor(
        address _vault,
        address _token0,
        address _token1,
        address _positionManager,
        address _pool,
        int24 _tickLower,
        int24 _tickUpper
    ) {
        // zero address checks
        if (_vault == address(0) || _token0 == address(0) || _token1 == address(0) ||
            _positionManager == address(0) || _pool == address(0)) {
            revert ZeroAddress();
        }

        // assign immutables 
        vault = _vault;
        token0 = IERC20(_token0);
        token1 = IERC20(_token1);
        positionManager = INonfungiblePositionManager(_positionManager);
        pool = IUniswapV3Pool(_pool);

        // Validate the default range after `pool` is assigned because spacing is read from the pool.
        _validateTicks(_tickLower, _tickUpper);

        defaultTickLower = _tickLower;
        defaultTickUpper = _tickUpper;

        // validate pool token set matches vault tokens
        // allow direct order or reverse order
        bool directOrder = (pool.token0() == _token0 && pool.token1() == _token1);
        bool reverseOrder = (pool.token0() == _token1 && pool.token1() == _token0);
        if (!directOrder && !reverseOrder) revert InvalidPool();

        tokenId = 0; // No active position
    }

    // ============================================
    // Functions
    // ============================================
    /// @notice Adds liquidity to the managed Uniswap V3 position.
    /// @param amount0 Vault token 0 amount supplied by the vault.
    /// @param amount1 Vault token 1 amount supplied by the vault.
    /// @param params ABI-encoded {@link LiquidityParams} used to set minimums and deadline.
    /// @return liquidity Liquidity minted or added to the current position.
    /// @dev Pulls tokens from the vault, maps vault ordering to pool ordering, then mints or increases the active position.
    function addLiquidity(
        uint256 amount0,
        uint256 amount1,
        bytes calldata params
    ) external override onlyVault returns (uint256 liquidity) {
        // zero amount check
        if (amount0 == 0 && amount1 == 0) revert ZeroAmounts();
        // decode params
        LiquidityParams memory p = _decodeLiquidityParams(params);

        liquidity = _addLiquidity(amount0, amount1, p);

        // emit event
        emit LiquidityAdded(msg.sender, amount0, amount1, liquidity, tokenId);
    }

    /// @notice Removes liquidity from the managed Uniswap V3 position and returns withdrawn tokens to the vault.
    /// @param liquidity Amount of liquidity to remove.
    /// @param params ABI-encoded {@link LiquidityParams} used to set minimums and deadline.
    /// @return amount0 Vault token 0 withdrawn from the position.
    /// @return amount1 Vault token 1 withdrawn from the position.
    /// @dev Decreases liquidity first, then collects owed amounts, then cleans up an empty position if possible.
    function removeLiquidity(
        uint256 liquidity, 
        bytes calldata params
    ) external override onlyVault returns (uint256 amount0, uint256 amount1) {
        if (liquidity == 0) revert ZeroLiquidity();
        
        if (tokenId == 0) revert NoPosition();

        (,, uint128 currentLiquidity,,) = _getPositionMetadata(tokenId);
        if (currentLiquidity == 0) {
            revert NoLiquidityToRemove();
        }
        if (liquidity > currentLiquidity) revert InsufficientPositionLiquidity();

        LiquidityParams memory p = _decodeLiquidityParams(params);
        (uint256 poolAmount0Min, uint256 poolAmount1Min) = _mapTokenAmounts(
            address(token0), 
            address(token1), 
            p.amount0Min, 
            p.amount1Min
        );
        INonfungiblePositionManager.DecreaseLiquidityParams memory decreaseLqParams = INonfungiblePositionManager.DecreaseLiquidityParams({
            tokenId: tokenId,
            liquidity: uint128(liquidity),
            amount0Min: poolAmount0Min,
            amount1Min: poolAmount1Min,
            deadline: p.deadline
        });

        positionManager.decreaseLiquidity(decreaseLqParams);
        
        (amount0, amount1) = _collectAndTransfer();

        _cleanupEmptyPosition();
    
        emit LiquidityRemoved(msg.sender, liquidity, amount0, amount1);
    }

    /// @notice Collects any currently owed tokens from the active V3 position and transfers them to the vault.
    /// @return fees0 Vault token 0 amount collected from the position.
    /// @return fees1 Vault token 1 amount collected from the position.
    /// @dev This satisfies the generic `collectFees` adapter interface. In Uniswap V3, fees are exposed
    ///      through the position manager's owed-token accounting and are collected via `collect`.
    function collectFees() external override onlyVault returns (uint256 fees0, uint256 fees1) {
        if (!_hasActivePosition(tokenId)) revert NoPosition();

        (fees0, fees1) = _collectAndTransfer();
        
        _cleanupEmptyPosition();

        emit FeesCollected(msg.sender, fees0, fees1);
    }

    /// @notice Returns the current estimated value of the managed position in vault token terms.
    /// @return amount0 Estimated amount of vault token 0.
    /// @return amount1 Estimated amount of vault token 1.
    /// @dev This is a minimal estimate based on current principal plus position-manager-tracked owed amounts.
    function getPositionValue() external override view returns (uint256 amount0, uint256 amount1) {
        if (!_hasActivePosition(tokenId)) return (0, 0);

        (int24 positionTickLower, int24 positionTickUpper, uint128 liquidity,
            uint128 tokensOwed0, uint128 tokensOwed1) = _getPositionMetadata(tokenId);
        uint256 poolAmount0 = uint256(tokensOwed0);
        uint256 poolAmount1 = uint256(tokensOwed1);
        if (liquidity > 0) {
            (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
            uint160 sqrtRatioLowerX96 = TickMath.getSqrtRatioAtTick(positionTickLower);
            uint160 sqrtRatioUpperX96 = TickMath.getSqrtRatioAtTick(positionTickUpper);
            (uint256 principal0, uint256 principal1) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtPriceX96,
                sqrtRatioLowerX96,
                sqrtRatioUpperX96,
                liquidity
            );
            poolAmount0 += principal0;
            poolAmount1 += principal1;
        }

        (amount0, amount1) = _mapTokenAmounts(address(token0), address(token1), poolAmount0, poolAmount1);
    }

    /// @notice Returns true when the adapter currently has an active or owed position.
    function hasPosition() external override view returns (bool) {
        return _hasActivePosition(tokenId);
    }

    // ============================================
    // Internal Functions
    // ============================================
    // helper functions
    /// @notice Reverts if tick bounds are invalid or not aligned to the pool tick spacing.
    function _validateTicks(int24 positionTickLower, int24 positionTickUpper) internal view {
        if (positionTickLower >= positionTickUpper) revert InvalidTicks();

        int24 spacing = pool.tickSpacing();
        if ((positionTickLower % spacing != 0) || (positionTickUpper % spacing != 0)) revert InvalidTickSpacing();
    }

    /// @notice Decodes optional V3 liquidity execution parameters.
    function _decodeLiquidityParams(bytes calldata params) internal view returns (LiquidityParams memory p) {
        if (params.length == 0) {
            return LiquidityParams({
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: defaultTickLower,
                tickUpper: defaultTickUpper
            });
        }
        p = abi.decode(params, (LiquidityParams));
        _validateTicks(p.tickLower, p.tickUpper);
    }

    /// @notice Maps vault token order and amounts into pool token order and amounts.
    /// @param vaultToken0 Vault token 0 address.
    /// @param vaultToken1 Vault token 1 address.
    /// @param vaultAmount0 Amount for vault token 0.
    /// @param vaultAmount1 Amount for vault token 1.
    /// @param vaultMin0 Minimum for vault token 0.
    /// @param vaultMin1 Minimum for vault token 1.
    /// @return poolToken0 Pool-ordered token 0.
    /// @return poolToken1 Pool-ordered token 1.
    /// @return poolAmount0Desired Desired amount for pool token 0.
    /// @return poolAmount1Desired Desired amount for pool token 1.
    /// @return poolAmount0Min Minimum amount for pool token 0.
    /// @return poolAmount1Min Minimum amount for pool token 1.
    function _mapVaultToPool(
        address vaultToken0,
        address vaultToken1,
        uint256 vaultAmount0,
        uint256 vaultAmount1,
        uint256 vaultMin0,
        uint256 vaultMin1
    ) internal pure returns (
        address poolToken0,
        address poolToken1,
        uint256 poolAmount0Desired,
        uint256 poolAmount1Desired,
        uint256 poolAmount0Min,
        uint256 poolAmount1Min
    ){
        if (vaultToken0 < vaultToken1) {
          return (vaultToken0, vaultToken1, vaultAmount0, vaultAmount1, vaultMin0, vaultMin1);
        } else {
          return (vaultToken1, vaultToken0, vaultAmount1, vaultAmount0, vaultMin1, vaultMin0);
        }
    }

    /// @notice Maps amounts between two token addresses using canonical address ordering.
    /// @param tokenA First token address.
    /// @param tokenB Second token address.
    /// @param amountA Amount associated with tokenA.
    /// @param amountB Amount associated with tokenB.
    /// @return amount0 Amount mapped to the lower-address token.
    /// @return amount1 Amount mapped to the higher-address token.
    function _mapTokenAmounts(
        address tokenA, address tokenB, 
        uint256 amountA, uint256 amountB 
    ) internal pure returns(
        uint256 amount0, uint256 amount1
    ) {
        if (tokenA < tokenB) {
            return (amountA, amountB);
        } else {
            return (amountB, amountA);
        }
    }

    /// @notice Reads the minimal position metadata required by this adapter.
    /// @param _tokenId Uniswap V3 position tokenId.
    /// @return positionTickLower Lower tick bound stored on the position NFT.
    /// @return positionTickUpper Upper tick bound stored on the position NFT.
    /// @return liquidity Current position liquidity.
    /// @return tokensOwed0 Amount of token 0 currently owed by the position manager.
    /// @return tokensOwed1 Amount of token 1 currently owed by the position manager.
    function _getPositionMetadata(uint256 _tokenId) internal view returns (
        int24 positionTickLower,
        int24 positionTickUpper,
        uint128 liquidity, 
        uint128 tokensOwed0, 
        uint128 tokensOwed1
    ) {
        (,,,,, positionTickLower, positionTickUpper, liquidity,,, tokensOwed0, tokensOwed1) = positionManager.positions(_tokenId);
    }

    /// @notice Returns true if the position has liquidity or any owed token amounts.
    /// @param _tokenId Uniswap V3 position tokenId.
    /// @return Whether the position is active or still contains owed amounts.
    function _hasActivePosition(uint256 _tokenId) internal view returns (bool) {
        if (_tokenId == 0) return false;

        (,, uint128 liquidity, uint128 tokensOwed0, uint128 tokensOwed1) = _getPositionMetadata(_tokenId);
        return (liquidity > 0 || tokensOwed0 > 0 || tokensOwed1 > 0);
    }

    /// @notice Burns the current position NFT if it has been fully emptied.
    /// @dev Clears tokenId back to zero after a successful burn.
    function  _cleanupEmptyPosition() internal {
        if (tokenId == 0) return;

        (,, uint128 liquidity, uint128 tokensOwed0, uint128 tokensOwed1) = _getPositionMetadata(tokenId);
        if (liquidity == 0 && tokensOwed0 == 0 && tokensOwed1 == 0) {
            positionManager.burn(tokenId);
            tokenId = 0;    
        }
    }

    /// @notice Collects all owed amounts from the position into the adapter and forwards them to the vault.
    /// @return amount0 Vault token 0 collected.
    /// @return amount1 Vault token 1 collected.
    function _collectAndTransfer() internal returns(uint256 amount0, uint256 amount1){
        // position -> adapter
        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
            tokenId: tokenId,
            recipient: address(this),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });
        (uint256 collected0, uint256 collected1) = positionManager.collect(collectParams);

        (amount0, amount1) = _mapTokenAmounts(address(token0), address(token1), collected0, collected1);
        
        // adapter -> vault
        if (amount0 > 0) {
            token0.safeTransfer(vault, amount0);
        }
        if (amount1 > 0) {
            token1.safeTransfer(vault, amount1);
        }
    }

    // stage functions
    // ============================================
    // addLiquidity Operations
    // ============================================
    /// @notice Pulls vault funds, prepares pool-ordered execution context, executes mint/increase, and refunds unused dust.
    /// @param amount0 Vault token 0 amount supplied by the vault.
    /// @param amount1 Vault token 1 amount supplied by the vault.
    /// @param p Decoded add-liquidity parameters containing min amounts and deadline.
    /// @return liquidity Liquidity minted or added to the active position.
    function _addLiquidity(uint256 amount0, uint256 amount1, LiquidityParams memory p) internal returns (uint256 liquidity){
        // pull token0/token1 from vault to adapter
        token0.safeTransferFrom(vault, address(this), amount0);
        token1.safeTransferFrom(vault, address(this), amount1);

        // map vault token order -> pool token order
        AddLiquidityContext memory ctx = _buildAddLiquidityContext(
            amount0, amount1, 
            p.amount0Min, p.amount1Min, 
            p.deadline,
            p.tickLower, p.tickUpper
        );
        
        // approve positionManager using pool-ordered tokens and amounts
        IERC20 poolToken0 = IERC20(ctx.poolToken0);
        IERC20 poolToken1 = IERC20(ctx.poolToken1);
        poolToken0.forceApprove(address(positionManager), ctx.poolAmount0Desired);
        poolToken1.forceApprove(address(positionManager), ctx.poolAmount1Desired);

        uint256 poolAmount0Used;
        uint256 poolAmount1Used;       
        (liquidity, poolAmount0Used, poolAmount1Used) = _executeAddLiquidity(ctx);

        (uint256 vaultAmount0Used, uint256 vaultAmount1Used) = _mapTokenAmounts(
            address(token0), address(token1), poolAmount0Used, poolAmount1Used); 

        _refundDust(amount0, amount1, vaultAmount0Used, vaultAmount1Used);

        // clear approvals
        poolToken0.forceApprove(address(positionManager), 0);
        poolToken1.forceApprove(address(positionManager), 0);
    }

    /// @notice Builds the execution context for add-liquidity operations.
    /// @param vaultAmount0 Vault token 0 amount.
    /// @param vaultAmount1 Vault token 1 amount.
    /// @param vaultMin0 Minimum vault token 0 amount.
    /// @param vaultMin1 Minimum vault token 1 amount.
    /// @param deadline Deadline for the position manager call.
    /// @return ctx Populated add-liquidity execution context.
    function _buildAddLiquidityContext(
        uint256 vaultAmount0,
        uint256 vaultAmount1,
        uint256 vaultMin0,
        uint256 vaultMin1,
        uint256 deadline,
        int24 positionTickLower,
        int24 positionTickUpper
    ) internal view returns (AddLiquidityContext memory ctx) {
        (
            ctx.poolToken0,
            ctx.poolToken1,
            ctx.poolAmount0Desired,
            ctx.poolAmount1Desired,
            ctx.poolAmount0Min,
            ctx.poolAmount1Min
        ) = _mapVaultToPool(
            address(token0),
            address(token1),
            vaultAmount0,
            vaultAmount1,
            vaultMin0,
            vaultMin1
        );

        ctx.deadline = deadline;
        ctx.tickLower = positionTickLower;
        ctx.tickUpper = positionTickUpper;
    }

    /// @notice Dispatches to mint or increase depending on whether a current tokenId exists.
    /// @param ctx Prepared add-liquidity execution context.
    /// @return liquidity Liquidity minted or added.
    /// @return poolAmount0Used Amount of pool token 0 consumed.
    /// @return poolAmount1Used Amount of pool token 1 consumed.
    function _executeAddLiquidity(AddLiquidityContext memory ctx) internal returns (
        uint256 liquidity,
        uint256 poolAmount0Used,
        uint256 poolAmount1Used
    ) {
        if (tokenId == 0) {
            (liquidity, poolAmount0Used, poolAmount1Used) = _mintPosition(ctx);
        } else {
            _validateCurrentPositionTicks(ctx.tickLower, ctx.tickUpper);
            (liquidity, poolAmount0Used, poolAmount1Used) = _increasePosition(tokenId, ctx);
        }
    }

    /// @notice Mints a new Uniswap V3 position NFT with the prepared execution context.
    /// @param ctx Prepared add-liquidity execution context.
    /// @return liquidity Liquidity minted into the new NFT.
    /// @return amount0Used Amount of pool token 0 used.
    /// @return amount1Used Amount of pool token 1 used.
    function _mintPosition(AddLiquidityContext memory ctx) internal returns (
        uint256 liquidity, 
        uint256 amount0Used, 
        uint256 amount1Used
    ){
        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            token0: ctx.poolToken0,
            token1: ctx.poolToken1,
            fee: pool.fee(),
            tickLower: ctx.tickLower,
            tickUpper: ctx.tickUpper,
            amount0Desired: ctx.poolAmount0Desired,
            amount1Desired: ctx.poolAmount1Desired,
            amount0Min: ctx.poolAmount0Min,
            amount1Min: ctx.poolAmount1Min,
            recipient: address(this),
            deadline: ctx.deadline
        });
        (tokenId, liquidity, amount0Used, amount1Used) = positionManager.mint(mintParams);         
    }

    function _validateCurrentPositionTicks(int24 expectedTickLower, int24 expectedTickUpper) internal view {
        (int24 currentTickLower, int24 currentTickUpper,,,) = _getPositionMetadata(tokenId);
        if (expectedTickLower != currentTickLower || expectedTickUpper != currentTickUpper) revert TickRangeMismatch();
    }

    /// @notice Increases liquidity on the currently active Uniswap V3 position.
    /// @param _tokenId Active position tokenId.
    /// @param ctx Prepared add-liquidity execution context.
    /// @return liquidity Liquidity added to the existing NFT.
    /// @return amount0Used Amount of pool token 0 used.
    /// @return amount1Used Amount of pool token 1 used.
    function _increasePosition(uint256 _tokenId, AddLiquidityContext memory ctx) internal returns (
        uint256 liquidity, 
        uint256 amount0Used, 
        uint256 amount1Used
    ) {
        INonfungiblePositionManager.IncreaseLiquidityParams memory increaseLqPramas = INonfungiblePositionManager.IncreaseLiquidityParams({
            tokenId: _tokenId,
            amount0Desired: ctx.poolAmount0Desired,
            amount1Desired: ctx.poolAmount1Desired,
            amount0Min: ctx.poolAmount0Min,
            amount1Min: ctx.poolAmount1Min,
            deadline: ctx.deadline        
        });
        (liquidity, amount0Used, amount1Used) = positionManager.increaseLiquidity(increaseLqPramas);
    }

    /// @notice Refunds unused vault-token dust back to the vault.
    /// @param amount0 Total vault token 0 supplied.
    /// @param amount1 Total vault token 1 supplied.
    /// @param amount0Used Vault token 0 amount actually consumed.
    /// @param amount1Used Vault token 1 amount actually consumed.
    function _refundDust(
        uint256 amount0, uint256 amount1, 
        uint256 amount0Used, uint256 amount1Used
    ) internal {
        // compute dust
        uint256 dust0 = amount0 - amount0Used;
        uint256 dust1 = amount1 - amount1Used;
    
        // transfer dust back to vault
        if (dust0 > 0) {
            token0.safeTransfer(vault, dust0);
        }
        if (dust1 > 0) {
            token1.safeTransfer(vault, dust1);
        }
    }
}
