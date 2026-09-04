// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v3-core/contracts/libraries/FixedPoint96.sol";
import {LiquidityAmounts} from "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";

/// @notice Range math helpers for concentrated liquidity positions.
library PositionMath {
    uint256 internal constant WAD = 1e18;

    /// @notice Share of a position's value that should be held as token1 (1e18 = 100%)
    ///         for the range [tickLower, tickUpper] at the given sqrt price.
    function token1Weight(uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper) internal pure returns (uint256) {
        uint160 sqrtA = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtRatioAtTick(tickUpper);
        if (sqrtPriceX96 <= sqrtA) return 0;
        if (sqrtPriceX96 >= sqrtB) return WAD;

        uint128 unit = 1e18;
        uint256 amount0 = LiquidityAmounts.getAmount0ForLiquidity(sqrtPriceX96, sqrtB, unit);
        uint256 amount1 = LiquidityAmounts.getAmount1ForLiquidity(sqrtA, sqrtPriceX96, unit);

        // value of amount0 expressed in token1: amount0 * price, price = sqrtP^2 / 2^192
        uint256 value0 = FullMath.mulDiv(amount0, sqrtPriceX96, FixedPoint96.Q96);
        value0 = FullMath.mulDiv(value0, sqrtPriceX96, FixedPoint96.Q96);

        uint256 total = value0 + amount1;
        if (total == 0) return WAD / 2;
        return FullMath.mulDiv(amount1, WAD, total);
    }

    function amountsForLiquidity(uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        return LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, TickMath.getSqrtRatioAtTick(tickLower), TickMath.getSqrtRatioAtTick(tickUpper), liquidity
        );
    }

    function liquidityForAmounts(
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128) {
        return LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            amount0,
            amount1
        );
    }

    function inRange(int24 tick, int24 tickLower, int24 tickUpper) internal pure returns (bool) {
        return tick >= tickLower && tick < tickUpper;
    }
}
