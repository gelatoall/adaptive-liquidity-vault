// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title INonfungiblePositionManager
/// @notice Minimal interface for Uniswap V3 position management used by the adapter.
interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    /// @notice Mints a new V3 position NFT.
    /// @return tokenId Newly minted position token id.
    /// @return liquidity Liquidity minted for the position.
    /// @return amount0 Actual token0 used.
    /// @return amount1 Actual token1 used.
    function mint(MintParams calldata params)
        external payable returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    /// @notice Increases liquidity in an existing V3 position NFT.
    /// @return liquidity Liquidity added to the position.
    /// @return amount0 Actual token0 used.
    /// @return amount1 Actual token1 used.
    function increaseLiquidity(IncreaseLiquidityParams calldata params)
        external payable returns (uint128 liquidity, uint256 amount0, uint256 amount1);

    /// @notice Decreases liquidity from an existing position.
    /// @return amount0 Amount of token0 returned.
    /// @return amount1 Amount of token1 returned.
    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external payable returns (uint256 amount0, uint256 amount1);

    /// @notice Collects fees and/or principal from a position.
    /// @return amount0 Amount of token0 collected.
    /// @return amount1 Amount of token1 collected.
    function collect(CollectParams calldata params)
        external payable returns (uint256 amount0, uint256 amount1);

    /// @notice Returns the full position metadata for a token id.
    /// @return nonce Position nonce.
    /// @return operator Approved operator.
    /// @return token0 Underlying token0 address.
    /// @return token1 Underlying token1 address.
    /// @return fee Pool fee tier.
    /// @return tickLower Lower tick boundary.
    /// @return tickUpper Upper tick boundary.
    /// @return liquidity Current position liquidity.
    /// @return feeGrowthInside0LastX128 Fee growth snapshot for token0.
    /// @return feeGrowthInside1LastX128 Fee growth snapshot for token1.
    /// @return tokensOwed0 Uncollected token0 amount.
    /// @return tokensOwed1 Uncollected token1 amount.
    function positions(uint256 tokenId) external view returns (
        uint96 nonce,
        address operator,
        address token0,
        address token1,
        uint24 fee,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 feeGrowthInside0LastX128,
        uint256 feeGrowthInside1LastX128,
        uint128 tokensOwed0,
        uint128 tokensOwed1
    );

    /// @notice Burns a position NFT after all liquidity has been removed.
    function burn(uint256 tokenId) external payable;
}

  