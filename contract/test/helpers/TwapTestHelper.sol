// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../mocks/MockERC20.sol";
import "../mocks/MockUniswapV2Pair.sol";
import "../../src/TWAPOracle.sol";
import "../../src/AdaptiveLPVault.sol";

abstract contract TwapTestHelper is Test {
    /** @dev Deploys pair/oracle baseline & links to vault. Oracle remains uninitialized until first update. */
    function _deployTwapOracleButNotUpdate(
        MockERC20 token0,
        MockERC20 token1,
        AdaptiveLPVault vault,
        uint32 interval
    ) internal returns (MockUniswapV2Pair twapPair, TWAPOracle twapOracle) {
        twapPair = new MockUniswapV2Pair(address(token0), address(token1));
        
        // Set baseline values to ensure the Oracle constructor captures non-zero data for its initial snapshot
        twapPair.setReserves(1_000_000, 2_000_000);
        twapPair.setCumulativePrices(1_000_000e18, 2_000_000e18);

        twapOracle = new TWAPOracle(address(twapPair), address(token0), address(token1), interval);
        
        // Link the newly deployed oracle to the vault to override any existing mock oracles
        vault.setOracle(address(twapOracle));
    }

    /** @dev Advances time and primes oracle. Formula: CumNow = CumLast + (avgPriceX112 * dt) */
    function _primeTwap(
        MockUniswapV2Pair _twapPair,
        TWAPOracle _twapOracle,
        uint32 dt, 
        uint256 avg0X112, 
        uint256 avg1X112
    ) internal {
        // Fetch last snapshots from the oracle to calculate the required cumulative growth
        uint256 cum0Last = _twapOracle.price0CumulativeLast();
        uint256 cum1Last = _twapOracle.price1CumulativeLast();
        
        // Simulate Uniswap V2 price accumulation: New = Old + (Price * TimeElapsed)
        uint256 cum0Now = cum0Last + avg0X112 * uint256(dt);
        uint256 cum1Now = cum1Last + avg1X112 * uint256(dt);

        // Fast-forward blockchain time and sync the mock pair's state
        vm.warp(block.timestamp + dt);
        _twapPair.setReserves(1_100_000, 2_200_000);
        _twapPair.setCumulativePrices(cum0Now, cum1Now);

        // Finalize the observation window and trigger the oracle's internal price calculation
        _twapOracle.update();
    }
}