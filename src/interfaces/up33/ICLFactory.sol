// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ICLFactory {
    function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address pool);
    function isPool(address pool) external view returns (bool);
    function voter() external view returns (address);
    function tickSpacings() external view returns (int24[] memory);
    function tickSpacingToFee(int24 tickSpacing) external view returns (uint24);
    function getSwapFee(address pool) external view returns (uint24);
}
