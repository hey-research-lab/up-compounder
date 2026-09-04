// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CompounderRegistry} from "./CompounderRegistry.sol";
import {IUserCompounder} from "./interfaces/IUserCompounder.sol";
import {ICLPool} from "./interfaces/up33/ICLPool.sol";
import {ICLGauge} from "./interfaces/up33/ICLGauge.sol";
import {INonfungiblePositionManager} from "./interfaces/up33/INonfungiblePositionManager.sol";
import {PositionMath} from "./libraries/PositionMath.sol";

/// @title CompounderLens
/// @notice Read-only aggregation over user compounders for UIs and keepers. Everything here is
///         derived from on-chain state; no events or history are required.
contract CompounderLens {
    CompounderRegistry public immutable registry;
    INonfungiblePositionManager public immutable nft;

    constructor(address _registry) {
        registry = CompounderRegistry(_registry);
        nft = INonfungiblePositionManager(registry.positionManager());
    }

    /*//////////////////////////////////////////////////////////////
                             SINGLE COMPOUNDER
    //////////////////////////////////////////////////////////////*/

    function pendingUp(address compounder) public view returns (uint256 total) {
        IUserCompounder c = IUserCompounder(compounder);
        uint256[] memory ids = c.positions();
        for (uint256 i = 0; i < ids.length; i++) {
            total += c.earned(ids[i]);
        }
    }

    function positionsByPool(address compounder, address pool) external view returns (uint256[] memory list) {
        IUserCompounder c = IUserCompounder(compounder);
        uint256[] memory ids = c.positions();
        uint256 count;
        for (uint256 i = 0; i < ids.length; i++) {
            if (c.getPositionInfo(ids[i]).pool == pool) count++;
        }
        list = new uint256[](count);
        uint256 j;
        for (uint256 i = 0; i < ids.length; i++) {
            if (c.getPositionInfo(ids[i]).pool == pool) list[j++] = ids[i];
        }
    }

    function snapshot(address compounder) public view returns (IUserCompounder.CompounderSnapshot memory s) {
        IUserCompounder c = IUserCompounder(compounder);
        s.compounder = compounder;
        s.owner = c.owner();
        s.version = c.version();
        s.keeper = c.keeper();
        s.active = c.isActive();
        s.gasBalance = compounder.balance;
        s.minUpToCompound = c.minUpToCompound();
        s.lastCompoundAt = c.lastCompoundAt();
        s.totalUpClaimed = c.totalUpClaimed();
        s.totalFeesPaid = c.totalFeesPaid();
        s.totalGasReimbursed = c.totalGasReimbursed();
        s.positionCount = c.positionCount();
        s.pendingUp = pendingUp(compounder);
    }

    function positionSnapshots(address compounder)
        public
        view
        returns (IUserCompounder.PositionSnapshot[] memory list)
    {
        IUserCompounder c = IUserCompounder(compounder);
        uint256[] memory ids = c.positions();
        list = new IUserCompounder.PositionSnapshot[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            list[i] = positionSnapshot(compounder, ids[i]);
        }
    }

    function positionSnapshot(address compounder, uint256 tokenId)
        public
        view
        returns (IUserCompounder.PositionSnapshot memory s)
    {
        IUserCompounder c = IUserCompounder(compounder);
        IUserCompounder.PositionInfo memory p = c.getPositionInfo(tokenId);
        CompounderRegistry.PoolInfo memory info = registry.getPoolInfo(p.pool);
        s.tokenId = tokenId;
        s.pool = p.pool;
        s.gauge = info.gauge;
        s.token0 = info.token0;
        s.token1 = info.token1;
        s.tickSpacing = info.tickSpacing;
        s.poolEnabled = info.enabled;
        s.staked = p.staked;
        s.depositedAt = p.depositedAt;
        s.lastCompoundedAt = p.lastCompoundedAt;
        s.compoundCount = p.compoundCount;
        s.upClaimed = p.upClaimed;
        (,,,,, s.tickLower, s.tickUpper, s.liquidity,,,,) = nft.positions(tokenId);
        if (p.pool != address(0)) {
            (, s.currentTick,,,,) = ICLPool(p.pool).slot0();
            s.inRange = PositionMath.inRange(s.currentTick, s.tickLower, s.tickUpper);
            if (p.staked) s.earned = ICLGauge(info.gauge).earned(compounder, tokenId);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                  BATCH
    //////////////////////////////////////////////////////////////*/

    function snapshots(address[] calldata compounders)
        external
        view
        returns (IUserCompounder.CompounderSnapshot[] memory list)
    {
        list = new IUserCompounder.CompounderSnapshot[](compounders.length);
        for (uint256 i = 0; i < compounders.length; i++) {
            list[i] = snapshot(compounders[i]);
        }
    }

    /// @notice Page through the registry and return snapshots. Stateless bots start here.
    function scan(uint256 offset, uint256 limit)
        external
        view
        returns (IUserCompounder.CompounderSnapshot[] memory list, uint256 total)
    {
        total = registry.compounderCount();
        address[] memory page = registry.compounders(offset, limit);
        list = new IUserCompounder.CompounderSnapshot[](page.length);
        for (uint256 i = 0; i < page.length; i++) {
            list[i] = snapshot(page[i]);
        }
    }

    /// @notice Everything a UI needs for one user in a single call.
    function userView(address user)
        external
        view
        returns (
            address compounder,
            IUserCompounder.CompounderSnapshot memory s,
            IUserCompounder.PositionSnapshot[] memory positions,
            address[] memory previous
        )
    {
        compounder = registry.compounderOf(user);
        previous = registry.previousCompounders(user);
        if (compounder != address(0)) {
            s = snapshot(compounder);
            positions = positionSnapshots(compounder);
        }
    }
}
