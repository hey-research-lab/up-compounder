// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IVoter {
    function gauges(address pool) external view returns (address);
    function poolForGauge(address gauge) external view returns (address);
    function isAlive(address gauge) external view returns (bool);
    function isGauge(address gauge) external view returns (bool);
    function emergencyCouncil() external view returns (address);
    function killGauge(address gauge) external;
    function reviveGauge(address gauge) external;
    function length() external view returns (uint256);
    function pools(uint256 index) external view returns (address);
}
