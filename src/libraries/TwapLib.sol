// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import {BytesLib} from "@uniswap/v3-periphery/contracts/libraries/BytesLib.sol";
import {ICLPool} from "../interfaces/up33/ICLPool.sol";
import {ICLFactory} from "../interfaces/up33/ICLFactory.sol";

/// @notice TWAP helpers for up33 CL pools and Slipstream packed swap paths.
library TwapLib {
    using BytesLib for bytes;

    uint256 private constant ADDR_SIZE = 20;
    uint256 private constant SPACING_SIZE = 3;
    uint256 private constant NEXT_OFFSET = ADDR_SIZE + SPACING_SIZE;
    uint256 private constant POP_OFFSET = NEXT_OFFSET + ADDR_SIZE;
    uint256 private constant FEE_DENOMINATOR = 1e6;

    error InvalidPath();
    error PoolNotFound(address tokenIn, address tokenOut, int24 tickSpacing);

    /// @notice Time weighted average tick over `window` seconds.
    function twapTick(address pool, uint32 window) internal view returns (int24 tick) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = window;
        secondsAgos[1] = 0;
        (int56[] memory cumulatives,) = ICLPool(pool).observe(secondsAgos);
        int56 delta = cumulatives[1] - cumulatives[0];
        tick = int24(delta / int56(uint56(window)));
        if (delta < 0 && (delta % int56(uint56(window)) != 0)) tick--;
    }

    /// @notice Spot tick and twap tick for a pool. Reverts if the observation window is not available.
    function spotAndTwap(address pool, uint32 window) internal view returns (int24 spot, int24 twap) {
        (, spot,,,,) = ICLPool(pool).slot0();
        twap = twapTick(pool, window);
    }

    /// @notice Absolute tick distance between spot and twap.
    function tickDeviation(int24 spot, int24 twap) internal pure returns (uint24) {
        int24 d = spot - twap;
        return uint24(d < 0 ? -d : d);
    }

    /// @notice Quote `baseAmount` of `baseToken` in `quoteToken` at `tick` (from Uniswap OracleLibrary).
    function quoteAtTick(int24 tick, uint256 baseAmount, address baseToken, address quoteToken)
        internal
        pure
        returns (uint256 quoteAmount)
    {
        uint160 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(tick);
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv(ratioX192, baseAmount, 1 << 192)
                : FullMath.mulDiv(1 << 192, baseAmount, ratioX192);
        } else {
            uint256 ratioX128 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv(ratioX128, baseAmount, 1 << 128)
                : FullMath.mulDiv(1 << 128, baseAmount, ratioX128);
        }
    }

    /// @notice TWAP based quote of `amountIn` through a packed Slipstream path, net of each
    ///         hop's current swap fee (fees are dynamic on up33).
    function quotePath(bytes memory path, uint256 amountIn, address factory, uint32 window)
        internal
        view
        returns (uint256 amountOut)
    {
        if (path.length < POP_OFFSET || (path.length - ADDR_SIZE) % NEXT_OFFSET != 0) revert InvalidPath();
        amountOut = amountIn;
        uint256 offset = 0;
        while (offset + POP_OFFSET <= path.length) {
            address tokenIn = path.toAddress(offset);
            int24 spacing = int24(path.toUint24(offset + ADDR_SIZE));
            address tokenOut = path.toAddress(offset + NEXT_OFFSET);
            address pool = ICLFactory(factory).getPool(tokenIn, tokenOut, spacing);
            if (pool == address(0)) revert PoolNotFound(tokenIn, tokenOut, spacing);
            uint256 fee = ICLFactory(factory).getSwapFee(pool);
            amountOut =
                quoteAtTick(twapTick(pool, window), amountOut - (amountOut * fee) / FEE_DENOMINATOR, tokenIn, tokenOut);
            offset += NEXT_OFFSET;
        }
    }

    /// @notice Effective fee of a packed path as a WAD fraction: 1 - prod(1 - fee_i).
    function pathFeeWad(bytes memory path, address factory) internal view returns (uint256 feeWad) {
        if (path.length < POP_OFFSET || (path.length - ADDR_SIZE) % NEXT_OFFSET != 0) revert InvalidPath();
        uint256 keep = 1e18;
        uint256 offset = 0;
        while (offset + POP_OFFSET <= path.length) {
            address tokenIn = path.toAddress(offset);
            int24 spacing = int24(path.toUint24(offset + ADDR_SIZE));
            address tokenOut = path.toAddress(offset + NEXT_OFFSET);
            address pool = ICLFactory(factory).getPool(tokenIn, tokenOut, spacing);
            if (pool == address(0)) revert PoolNotFound(tokenIn, tokenOut, spacing);
            uint256 fee = ICLFactory(factory).getSwapFee(pool);
            keep = (keep * (FEE_DENOMINATOR - fee)) / FEE_DENOMINATOR;
            offset += NEXT_OFFSET;
        }
        feeWad = 1e18 - keep;
    }

    /// @notice First and last token of a packed path, validating hop pools exist.
    function pathEndpoints(bytes memory path, address factory)
        internal
        view
        returns (address tokenIn, address tokenOut)
    {
        if (path.length < POP_OFFSET || (path.length - ADDR_SIZE) % NEXT_OFFSET != 0) revert InvalidPath();
        tokenIn = path.toAddress(0);
        uint256 offset = 0;
        while (offset + POP_OFFSET <= path.length) {
            address a = path.toAddress(offset);
            int24 spacing = int24(path.toUint24(offset + ADDR_SIZE));
            address b = path.toAddress(offset + NEXT_OFFSET);
            if (ICLFactory(factory).getPool(a, b, spacing) == address(0)) revert PoolNotFound(a, b, spacing);
            tokenOut = b;
            offset += NEXT_OFFSET;
        }
    }
}
