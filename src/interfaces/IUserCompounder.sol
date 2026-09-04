// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IUserCompounder {
    struct PositionInfo {
        address pool;
        uint40 depositedAt;
        uint40 lastCompoundedAt;
        uint32 compoundCount;
        bool staked;
        uint256 upClaimed;
    }

    struct CompounderSnapshot {
        address compounder;
        address owner;
        uint16 version;
        address keeper;
        bool active;
        uint256 gasBalance;
        uint256 minUpToCompound;
        uint40 lastCompoundAt;
        uint256 totalUpClaimed;
        uint256 totalFeesPaid;
        uint256 totalGasReimbursed;
        uint256 positionCount;
        uint256 pendingUp;
    }

    struct PositionSnapshot {
        uint256 tokenId;
        address pool;
        address gauge;
        address token0;
        address token1;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
        int24 currentTick;
        uint128 liquidity;
        bool inRange;
        bool staked;
        bool poolEnabled;
        uint256 earned;
        uint40 depositedAt;
        uint40 lastCompoundedAt;
        uint32 compoundCount;
        uint256 upClaimed;
    }

    function initialize(address owner_) external;

    function owner() external view returns (address);
    function version() external view returns (uint16);
    function keeper() external view returns (address);
    function minUpToCompound() external view returns (uint256);
    function lastCompoundAt() external view returns (uint40);
    function totalUpClaimed() external view returns (uint256);
    function totalFeesPaid() external view returns (uint256);
    function totalGasReimbursed() external view returns (uint256);

    function positions() external view returns (uint256[] memory);
    function positionCount() external view returns (uint256);
    function getPositionInfo(uint256 tokenId) external view returns (PositionInfo memory);
    function earned(uint256 tokenId) external view returns (uint256);
    function gasBalance() external view returns (uint256);
    function isActive() external view returns (bool);

    function deposit(uint256 tokenId) external;
    function withdraw(uint256 tokenId, address to) external;
    function claim(uint256 tokenId) external;
    function compound(uint256[] calldata tokenIds) external;
    function compoundAll() external;
    function increaseLiquidity(
        uint256 tokenId,
        uint256 amount0,
        uint256 amount1,
        uint256 amount0Min,
        uint256 amount1Min
    ) external;
    function decreaseLiquidity(uint256 tokenId, uint128 liquidity, uint256 amount0Min, uint256 amount1Min) external;
    function emergencyUnstake(uint256 tokenId) external;
    function restake(uint256 tokenId) external;
    function setKeeper(address keeper_) external;
    function setMinUpToCompound(uint256 amount) external;
    function fundGas() external payable;
    function withdrawGas(uint256 amount, address to) external;
    function sweep(address token, address to) external;
}
