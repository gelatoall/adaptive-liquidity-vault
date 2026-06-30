// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../src/interfaces/INonfungiblePositionManager.sol";
import "./MockERC20.sol";

/// @title MockNonfungiblePositionManager
/// @notice Minimal Uniswap V3 position manager mock for adapter tests.
/// @dev Stores a single position state per tokenId and uses preprogrammed return values for deterministic tests.
contract MockNonfungiblePositionManager is INonfungiblePositionManager {
    struct Position {
        uint96 nonce;
        address operator;
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
        bool exists;
    }

    uint256 public nextTokenId = 1;

    mapping(uint256 => Position) internal _positions;
    
    // Pre-programmed results for deterministic tests.
    uint128 public nextMintLiquidity;
    uint256 public nextMintAmount0Used;
    uint256 public nextMintAmount1Used;

    uint128 public nextIncreaseLiquidity;
    uint256 public nextIncreaseAmount0Used;
    uint256 public nextIncreaseAmount1Used;

    uint256 public nextDecreaseAmount0;
    uint256 public nextDecreaseAmount1;

    uint256 public lastMintAmount0Min;
    uint256 public lastMintAmount1Min;
    uint256 public lastMintDeadline;

    uint256 public lastIncreaseAmount0Min;
    uint256 public lastIncreaseAmount1Min;
    uint256 public lastIncreaseDeadline;

    uint256 public lastDecreaseAmount0Min;
    uint256 public lastDecreaseAmount1Min;
    uint256 public lastDecreaseDeadline;
    
    /// @notice Sets the next mint result returned by the mock.
    function setNextMintResult(
        uint128 liquidity_,
        uint256 amount0Used_,
        uint256 amount1Used_
    ) external {
        nextMintLiquidity = liquidity_;
        nextMintAmount0Used = amount0Used_;
        nextMintAmount1Used = amount1Used_;
    }

    /// @notice Sets the next increase-liquidity result returned by the mock.
    function setNextIncreaseResult(
        uint128 liquidity_,
        uint256 amount0Used_,
        uint256 amount1Used_
    ) external {
        nextIncreaseLiquidity = liquidity_;
        nextIncreaseAmount0Used = amount0Used_;
        nextIncreaseAmount1Used = amount1Used_;
    }

    /// @notice Sets the next decrease-liquidity result returned by the mock.
    function setNextDecreaseResult(
        uint256 amount0_,
        uint256 amount1_
    ) external {
        nextDecreaseAmount0 = amount0_;
        nextDecreaseAmount1 = amount1_;
    }

    /// @notice Overrides the owed amounts for a stored position.
    function setTokensOwed(
        uint256 tokenId,
        uint128 owed0,
        uint128 owed1
    ) external {
        Position storage p = _positions[tokenId];
        require(p.exists, "NO_POSITION");
        p.tokensOwed0 = owed0;
        p.tokensOwed1 = owed1;
    }

    /// @inheritdoc INonfungiblePositionManager
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
    ) {
        Position memory p = _positions[tokenId];
        return (
            p.nonce,
            p.operator,
            p.token0,
            p.token1,
            p.fee,
            p.tickLower,
            p.tickUpper,
            p.liquidity,
            p.feeGrowthInside0LastX128,
            p.feeGrowthInside1LastX128,
            p.tokensOwed0,
            p.tokensOwed1
        );
    }

    /// @inheritdoc INonfungiblePositionManager
    function mint(INonfungiblePositionManager.MintParams calldata params) 
        external payable returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        tokenId = nextTokenId++;
        lastMintAmount0Min = params.amount0Min;
        lastMintAmount1Min = params.amount1Min;
        lastMintDeadline = params.deadline;

        liquidity = nextMintLiquidity;
        amount0 = nextMintAmount0Used;
        amount1 = nextMintAmount1Used;

        MockERC20(params.token0).transferFrom(msg.sender, address(this), amount0);
        MockERC20(params.token1).transferFrom(msg.sender, address(this), amount1);

        _positions[tokenId] = Position({
            nonce: 0,
            operator: address(0),
            token0: params.token0,
            token1: params.token1,
            fee: params.fee,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            liquidity: liquidity,
            feeGrowthInside0LastX128: 0,
            feeGrowthInside1LastX128: 0,
            tokensOwed0: 0,
            tokensOwed1: 0,
            exists: true
        });

        _resetMintState();
    }

    /// @inheritdoc INonfungiblePositionManager
    function increaseLiquidity(INonfungiblePositionManager.IncreaseLiquidityParams calldata params)
        external payable returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        Position storage p = _positions[params.tokenId];
        require(p.exists, "NO_POSITION");

        lastIncreaseAmount0Min = params.amount0Min;
        lastIncreaseAmount1Min = params.amount1Min;
        lastIncreaseDeadline = params.deadline;

        liquidity = nextIncreaseLiquidity;
        amount0 = nextIncreaseAmount0Used;
        amount1 = nextIncreaseAmount1Used;

        MockERC20(p.token0).transferFrom(msg.sender, address(this), amount0);
        MockERC20(p.token1).transferFrom(msg.sender, address(this), amount1);

        p.liquidity += liquidity;

        _resetIncreaseState();
    }

    /// @inheritdoc INonfungiblePositionManager
    function decreaseLiquidity(INonfungiblePositionManager.DecreaseLiquidityParams calldata params)
        external payable returns (uint256 amount0, uint256 amount1)
    {
        Position storage p = _positions[params.tokenId];
        
        require(p.exists, "NO_POSITION");
        require(p.liquidity >= params.liquidity, "Insufficient liquidity");
        lastDecreaseAmount0Min = params.amount0Min;
        lastDecreaseAmount1Min = params.amount1Min;
        lastDecreaseDeadline = params.deadline;

        p.liquidity -= params.liquidity;

        amount0 = nextDecreaseAmount0;
        amount1 = nextDecreaseAmount1;
        p.tokensOwed0 += uint128(amount0);
        p.tokensOwed1 += uint128(amount1);

        _resetDecreaseState();
    }

    /// @inheritdoc INonfungiblePositionManager
    function collect(INonfungiblePositionManager.CollectParams calldata params)
        external payable returns (uint256 amount0, uint256 amount1)
    {
        Position storage p = _positions[params.tokenId];
        
        require(p.exists, "NO_POSITION");
        amount0 = p.tokensOwed0 > params.amount0Max ? params.amount0Max : p.tokensOwed0;
        amount1 = p.tokensOwed1 > params.amount1Max ? params.amount1Max : p.tokensOwed1;

        p.tokensOwed0 -= uint128(amount0);
        p.tokensOwed1 -= uint128(amount1);

        if (amount0 > 0) MockERC20(p.token0).transfer(params.recipient, amount0);
        if (amount1 > 0) MockERC20(p.token1).transfer(params.recipient, amount1);
    }

    /// @inheritdoc INonfungiblePositionManager
    function burn(uint256 tokenId) external payable {
        require(_positions[tokenId].exists, "NO_POSITION");
        require(_positions[tokenId].liquidity == 0, "Position not empty");
        require(_positions[tokenId].tokensOwed0 == 0 && _positions[tokenId].tokensOwed1 == 0, "Fees not collected");
        delete _positions[tokenId];
    }

    /// @notice Adds owed amounts to an existing test position.
    function addFees(uint256 tokenId, uint128 amount0, uint128 amount1) external {
        require(_positions[tokenId].exists, "NO_POSITION");
        _positions[tokenId].tokensOwed0 += amount0;
        _positions[tokenId].tokensOwed1 += amount1;
    }
    
    /// @notice Clears the preprogrammed mint result.
    function _resetMintState() internal {
        nextMintLiquidity = 0;
        nextMintAmount0Used = 0;
        nextMintAmount1Used = 0;
    }

    /// @notice Clears the preprogrammed increase result.
    function _resetIncreaseState() internal {
        nextIncreaseLiquidity = 0;
        nextIncreaseAmount0Used = 0;
        nextIncreaseAmount1Used = 0;
    }


    /// @notice Clears the preprogrammed decrease result.
    function _resetDecreaseState() internal {
        nextDecreaseAmount0 = 0;
        nextDecreaseAmount1 = 0;
    }
}
