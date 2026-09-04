// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ICLPool} from "./interfaces/up33/ICLPool.sol";
import {ICLFactory} from "./interfaces/up33/ICLFactory.sol";
import {ICLGauge} from "./interfaces/up33/ICLGauge.sol";
import {IVoter} from "./interfaces/up33/IVoter.sol";
import {IUserCompounder} from "./interfaces/IUserCompounder.sol";
import {TwapLib} from "./libraries/TwapLib.sol";

/// @title CompounderRegistry
/// @notice Single source of truth for the up33 position compounder protocol:
///         protocol configuration, enabled pools, implementation versions and the user directory.
///         Everything is stored and enumerable on-chain so keepers and UIs can run stateless.
contract CompounderRegistry is Ownable2Step {
    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    struct PoolInfo {
        address pool;
        address gauge;
        address token0;
        address token1;
        int24 tickSpacing;
        bool enabled;
        uint40 enabledAt;
        uint16 enabledAtVersion;
        uint32 index;
    }

    struct Config {
        address treasury;
        uint16 feeBps;
        uint16 slippageBps;
        uint32 twapWindow;
        uint24 maxTickDeviation;
        uint16 gasPremiumBps;
        uint32 gasOverhead;
        uint128 maxGasPrice;
        address protocolKeeper;
        bool paused;
    }

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event ConfigUpdated();
    event RouteSet(address indexed tokenIn, address indexed tokenOut, bytes path);
    event ImplementationAdded(uint16 indexed version, address implementation);
    event ImplementationEnabled(uint16 indexed version, bool enabled);
    event PoolEnabled(address indexed pool, address indexed gauge, uint16 version);
    event PoolDisabled(address indexed pool);
    event CompounderCreated(address indexed user, address indexed compounder, uint16 version);
    event CompounderUpgraded(address indexed user, address indexed previous, address indexed current, uint16 version);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error FeeTooHigh();
    error InvalidBps();
    error InvalidWindow();
    error PoolAlreadyEnabled();
    error PoolNotEnabled();
    error NotCLPool();
    error GaugeNotAlive();
    error RouteMissing(address tokenIn, address tokenOut);
    error RouteEndpointMismatch();
    error NoImplementation();
    error UnknownVersion();
    error AlreadyHasCompounder();
    error NoCompounder();
    error AlreadyLatestVersion();
    error VersionMismatch(uint16 expected);

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    IVoter public immutable voter;
    ICLFactory public immutable clFactory;
    address public immutable positionManager;
    address public immutable swapRouter;
    address public immutable rewardToken;

    uint16 public constant MAX_FEE_BPS = 2_000;
    uint16 public constant BPS = 10_000;

    /*//////////////////////////////////////////////////////////////
                              PROTOCOL CONFIG
    //////////////////////////////////////////////////////////////*/

    Config internal _config;

    /// @notice tokenIn => tokenOut => packed Slipstream path
    mapping(address => mapping(address => bytes)) public routes;

    /*//////////////////////////////////////////////////////////////
                             IMPLEMENTATIONS
    //////////////////////////////////////////////////////////////*/

    mapping(uint16 => address) public implementations;
    mapping(uint16 => bool) public implementationEnabled;
    uint16 public latestVersion;

    /*//////////////////////////////////////////////////////////////
                                  POOLS
    //////////////////////////////////////////////////////////////*/

    mapping(address => PoolInfo) internal _poolInfo;
    address[] public poolList;

    /*//////////////////////////////////////////////////////////////
                                  USERS
    //////////////////////////////////////////////////////////////*/

    mapping(address => address) public compounderOf;
    mapping(address => address) public ownerOfCompounder;
    mapping(address => uint16) public versionOfCompounder;
    mapping(address => address[]) internal _previousCompounders;
    address[] public compounderList;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        address _voter,
        address _clFactory,
        address _positionManager,
        address _swapRouter,
        address _rewardToken,
        address _treasury,
        address _owner
    ) {
        if (
            _voter == address(0) || _clFactory == address(0) || _positionManager == address(0)
                || _swapRouter == address(0) || _rewardToken == address(0) || _treasury == address(0)
                || _owner == address(0)
        ) revert ZeroAddress();
        voter = IVoter(_voter);
        clFactory = ICLFactory(_clFactory);
        positionManager = _positionManager;
        swapRouter = _swapRouter;
        rewardToken = _rewardToken;

        _config = Config({
            treasury: _treasury,
            feeBps: 1_000,
            slippageBps: 100,
            twapWindow: 600,
            maxTickDeviation: 100,
            gasPremiumBps: 1_000,
            gasOverhead: 60_000,
            maxGasPrice: 1 gwei,
            protocolKeeper: address(0),
            paused: false
        });

        _transferOwnership(_owner);
    }

    /*//////////////////////////////////////////////////////////////
                             CONFIG SETTERS
    //////////////////////////////////////////////////////////////*/

    function config() external view returns (Config memory) {
        return _config;
    }

    function setTreasury(address treasury) external onlyOwner {
        if (treasury == address(0)) revert ZeroAddress();
        _config.treasury = treasury;
        emit ConfigUpdated();
    }

    function setFeeBps(uint16 feeBps) external onlyOwner {
        if (feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        _config.feeBps = feeBps;
        emit ConfigUpdated();
    }

    function setSwapParams(uint16 slippageBps, uint32 twapWindow, uint24 maxTickDeviation) external onlyOwner {
        if (slippageBps > BPS) revert InvalidBps();
        if (twapWindow == 0) revert InvalidWindow();
        _config.slippageBps = slippageBps;
        _config.twapWindow = twapWindow;
        _config.maxTickDeviation = maxTickDeviation;
        emit ConfigUpdated();
    }

    function setGasParams(uint16 gasPremiumBps, uint32 gasOverhead, uint128 maxGasPrice) external onlyOwner {
        if (gasPremiumBps > BPS) revert InvalidBps();
        _config.gasPremiumBps = gasPremiumBps;
        _config.gasOverhead = gasOverhead;
        _config.maxGasPrice = maxGasPrice;
        emit ConfigUpdated();
    }

    function setProtocolKeeper(address protocolKeeper) external onlyOwner {
        _config.protocolKeeper = protocolKeeper;
        emit ConfigUpdated();
    }

    function setPaused(bool paused) external onlyOwner {
        _config.paused = paused;
        emit ConfigUpdated();
    }

    /// @notice Set the swap path used to convert `tokenIn` into `tokenOut`.
    /// @dev Path is Slipstream packed: token, int24 tickSpacing, token, ... Every hop pool must exist.
    function setRoute(address tokenIn, address tokenOut, bytes calldata path) external onlyOwner {
        if (path.length == 0) {
            delete routes[tokenIn][tokenOut];
            emit RouteSet(tokenIn, tokenOut, path);
            return;
        }
        (address first, address last) = TwapLib.pathEndpoints(path, address(clFactory));
        if (first != tokenIn || last != tokenOut) revert RouteEndpointMismatch();
        routes[tokenIn][tokenOut] = path;
        emit RouteSet(tokenIn, tokenOut, path);
    }

    function getRoute(address tokenIn, address tokenOut) external view returns (bytes memory) {
        return routes[tokenIn][tokenOut];
    }

    /*//////////////////////////////////////////////////////////////
                             IMPLEMENTATIONS
    //////////////////////////////////////////////////////////////*/

    function addImplementation(address implementation) external onlyOwner returns (uint16 version) {
        if (implementation == address(0)) revert ZeroAddress();
        version = latestVersion + 1;
        if (IUserCompounder(implementation).version() != version) revert VersionMismatch(version);
        latestVersion = version;
        implementations[version] = implementation;
        implementationEnabled[version] = true;
        emit ImplementationAdded(version, implementation);
    }

    function setImplementationEnabled(uint16 version, bool enabled) external onlyOwner {
        if (implementations[version] == address(0)) revert UnknownVersion();
        implementationEnabled[version] = enabled;
        emit ImplementationEnabled(version, enabled);
    }

    /*//////////////////////////////////////////////////////////////
                                  POOLS
    //////////////////////////////////////////////////////////////*/

    /// @notice Enable an up33 CL pool for compounding. Requires a live gauge and swap routes
    ///         from the reward token into both pool tokens.
    function enablePool(address pool) external onlyOwner {
        PoolInfo storage info = _poolInfo[pool];
        if (info.enabled) revert PoolAlreadyEnabled();
        if (!clFactory.isPool(pool)) revert NotCLPool();

        address gauge = voter.gauges(pool);
        if (gauge == address(0) || !voter.isAlive(gauge)) revert GaugeNotAlive();

        address token0 = ICLPool(pool).token0();
        address token1 = ICLPool(pool).token1();
        if (token0 != rewardToken && routes[rewardToken][token0].length == 0) revert RouteMissing(rewardToken, token0);
        if (token1 != rewardToken && routes[rewardToken][token1].length == 0) revert RouteMissing(rewardToken, token1);

        if (info.pool == address(0)) {
            info.pool = pool;
            info.index = uint32(poolList.length);
            poolList.push(pool);
        }
        info.gauge = gauge;
        info.token0 = token0;
        info.token1 = token1;
        info.tickSpacing = ICLPool(pool).tickSpacing();
        info.enabled = true;
        info.enabledAt = uint40(block.timestamp);
        info.enabledAtVersion = latestVersion;

        emit PoolEnabled(pool, gauge, latestVersion);
    }

    /// @notice Disable a pool. Blocks new deposits and compounding; withdrawals are unaffected.
    function disablePool(address pool) external onlyOwner {
        PoolInfo storage info = _poolInfo[pool];
        if (!info.enabled) revert PoolNotEnabled();
        info.enabled = false;
        emit PoolDisabled(pool);
    }

    function getPoolInfo(address pool) external view returns (PoolInfo memory) {
        return _poolInfo[pool];
    }

    function isPoolEnabled(address pool) external view returns (bool) {
        return _poolInfo[pool].enabled;
    }

    function poolCount() external view returns (uint256) {
        return poolList.length;
    }

    function pools(uint256 offset, uint256 limit) external view returns (PoolInfo[] memory page) {
        uint256 len = poolList.length;
        if (offset >= len) return page;
        uint256 end = offset + limit > len ? len : offset + limit;
        page = new PoolInfo[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            page[i - offset] = _poolInfo[poolList[i]];
        }
    }

    function enabledPools() external view returns (PoolInfo[] memory list) {
        uint256 len = poolList.length;
        uint256 count;
        for (uint256 i = 0; i < len; i++) {
            if (_poolInfo[poolList[i]].enabled) count++;
        }
        list = new PoolInfo[](count);
        uint256 j;
        for (uint256 i = 0; i < len; i++) {
            PoolInfo memory info = _poolInfo[poolList[i]];
            if (info.enabled) list[j++] = info;
        }
    }

    /*//////////////////////////////////////////////////////////////
                                  USERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploy a personal compounder (minimal proxy of the latest implementation).
    function createCompounder() external returns (address compounder) {
        if (compounderOf[msg.sender] != address(0)) revert AlreadyHasCompounder();
        compounder = _deploy(msg.sender);
        emit CompounderCreated(msg.sender, compounder, latestVersion);
    }

    /// @notice Deploy a fresh compounder at the latest version. The previous one stays owned by
    ///         the user and is recorded in history; positions must be moved manually.
    function upgradeCompounder() external returns (address compounder) {
        address previous = compounderOf[msg.sender];
        if (previous == address(0)) revert NoCompounder();
        if (versionOfCompounder[previous] == latestVersion) revert AlreadyLatestVersion();
        _previousCompounders[msg.sender].push(previous);
        compounder = _deploy(msg.sender);
        emit CompounderUpgraded(msg.sender, previous, compounder, latestVersion);
    }

    function _deploy(address user) internal returns (address compounder) {
        uint16 version = latestVersion;
        address implementation = implementations[version];
        if (implementation == address(0) || !implementationEnabled[version]) revert NoImplementation();

        compounder = Clones.clone(implementation);
        IUserCompounder(compounder).initialize(user);

        compounderOf[user] = compounder;
        ownerOfCompounder[compounder] = user;
        versionOfCompounder[compounder] = version;
        compounderList.push(compounder);
    }

    function isCompounder(address compounder) external view returns (bool) {
        return ownerOfCompounder[compounder] != address(0);
    }

    function compounderCount() external view returns (uint256) {
        return compounderList.length;
    }

    function compounders(uint256 offset, uint256 limit) external view returns (address[] memory page) {
        uint256 len = compounderList.length;
        if (offset >= len) return page;
        uint256 end = offset + limit > len ? len : offset + limit;
        page = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            page[i - offset] = compounderList[i];
        }
    }

    function previousCompounders(address user) external view returns (address[] memory) {
        return _previousCompounders[user];
    }
}
