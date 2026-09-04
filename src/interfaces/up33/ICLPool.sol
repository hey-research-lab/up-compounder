// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal interface for an up33 (Slipstream fork) concentrated liquidity pool.
interface ICLPool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function tickSpacing() external view returns (int24);
    function fee() external view returns (uint24);
    function gauge() external view returns (address);
    function nft() external view returns (address);
    function liquidity() external view returns (uint128);
    function stakedLiquidity() external view returns (uint128);
    function rewardRate() external view returns (uint256);

    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            bool unlocked
        );

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);

    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external;

    function updateRewardsGrowthGlobal() external;
}
