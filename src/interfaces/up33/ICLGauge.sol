// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Slipstream-style CL gauge. This fork has no increase/decreaseStakedLiquidity.
interface ICLGauge {
    function deposit(uint256 tokenId) external;
    function withdraw(uint256 tokenId) external;
    function getReward(uint256 tokenId) external;

    function earned(address account, uint256 tokenId) external view returns (uint256);
    function rewards(uint256 tokenId) external view returns (uint256);
    function rewardToken() external view returns (address);
    function rewardRate() external view returns (uint256);
    function periodFinish() external view returns (uint256);
    function pool() external view returns (address);
    function nft() external view returns (address);
    function voter() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function tickSpacing() external view returns (int24);

    function stakedValues(address depositor) external view returns (uint256[] memory);
    function stakedContains(address depositor, uint256 tokenId) external view returns (bool);
    function stakedLength(address depositor) external view returns (uint256);
}
