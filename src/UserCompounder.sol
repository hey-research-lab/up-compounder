// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {CompounderRegistry} from "./CompounderRegistry.sol";
import {IUserCompounder} from "./interfaces/IUserCompounder.sol";
import {ICLPool} from "./interfaces/up33/ICLPool.sol";
import {ICLFactory} from "./interfaces/up33/ICLFactory.sol";
import {ICLGauge} from "./interfaces/up33/ICLGauge.sol";
import {IVoter} from "./interfaces/up33/IVoter.sol";
import {INonfungiblePositionManager} from "./interfaces/up33/INonfungiblePositionManager.sol";
import {ISwapRouter} from "./interfaces/up33/ISwapRouter.sol";
import {PositionMath} from "./libraries/PositionMath.sol";
import {TwapLib} from "./libraries/TwapLib.sol";

/// @title UserCompounder
/// @notice Per-user minimal proxy that holds the user's up33 CL position NFTs, keeps them staked
///         in their gauges, and compounds claimed UP back into the same positions.
///         The user stays in full control of range and liquidity; the protocol only claims,
///         takes a fee, swaps and re-adds. A delegated keeper can compound and is reimbursed
///         for gas from ETH the user deposits here.
contract UserCompounder is IUserCompounder, IERC721Receiver {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Initialized(address indexed owner);
    event Deposited(uint256 indexed tokenId, address indexed pool);
    event Withdrawn(uint256 indexed tokenId, address indexed to, uint256 upPaid);
    event Claimed(uint256 indexed tokenId, uint256 up, uint256 fee);
    event Compounded(
        uint256 indexed tokenId, uint256 up, uint256 fee, uint256 amount0, uint256 amount1, uint128 liquidity
    );
    event LiquidityIncreased(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    event LiquidityDecreased(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    event Staked(uint256 indexed tokenId);
    event Unstaked(uint256 indexed tokenId);
    event KeeperSet(address indexed keeper);
    event MinUpToCompoundSet(uint256 amount);
    event GasFunded(address indexed from, uint256 amount);
    event GasWithdrawn(address indexed to, uint256 amount);
    event GasReimbursed(address indexed keeper, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error AlreadyInitialized();
    error NotRegistry();
    error NotOwner();
    error NotOwnerOrKeeper();
    error Reentrancy();
    error Paused();
    error VersionDisabled();
    error PoolNotEnabled(address pool);
    error UnknownPosition(uint256 tokenId);
    error AlreadyTracked(uint256 tokenId);
    error UnexpectedNFT();
    error NotStaked();
    error AlreadyStaked();
    error GaugeNotAlive();
    error PriceDeviation(int24 spot, int24 twap);
    error RouteMissing(address tokenIn, address tokenOut);
    error InsufficientGas(uint256 required, uint256 available);
    error TransferFailed();
    error ZeroAddress();

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    CompounderRegistry public immutable registry;
    uint16 public immutable version;
    INonfungiblePositionManager public immutable nft;
    ISwapRouter public immutable router;
    IVoter public immutable voter;
    ICLFactory public immutable clFactory;
    IERC20 public immutable UP;

    uint256 internal constant BPS = 10_000;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    address public owner;
    address public keeper;
    uint256 public minUpToCompound;
    uint40 public lastCompoundAt;
    uint256 public totalUpClaimed;
    uint256 public totalFeesPaid;
    uint256 public totalGasReimbursed;

    EnumerableSet.UintSet private _positions;
    mapping(uint256 => PositionInfo) private _positionInfo;

    uint256 private _lock;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _registry, uint16 _version) {
        registry = CompounderRegistry(_registry);
        version = _version;
        nft = INonfungiblePositionManager(registry.positionManager());
        router = ISwapRouter(registry.swapRouter());
        voter = registry.voter();
        clFactory = registry.clFactory();
        UP = IERC20(registry.rewardToken());
        // Lock the implementation itself.
        owner = address(0xdead);
    }

    /// @notice Called once by the registry right after cloning.
    function initialize(address owner_) external {
        if (msg.sender != address(registry)) revert NotRegistry();
        if (owner != address(0)) revert AlreadyInitialized();
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
        emit Initialized(owner_);
    }

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyOwnerOrKeeper() {
        if (msg.sender != owner && (msg.sender != keeper || keeper == address(0))) revert NotOwnerOrKeeper();
        _;
    }

    modifier nonReentrant() {
        if (_lock == 1) revert Reentrancy();
        _lock = 1;
        _;
        _lock = 0;
    }

    /*//////////////////////////////////////////////////////////////
                             USER: POSITIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit a position NFT (requires prior approval to this contract) and stake it.
    function deposit(uint256 tokenId) external onlyOwner nonReentrant {
        _requireActive();
        nft.transferFrom(msg.sender, address(this), tokenId);
        _register(tokenId);
    }

    /// @notice Accepts NFTs sent with `safeTransferFrom`. A transfer from the owner of an
    ///         untracked token is treated as a deposit. Transfers back from a gauge are accepted.
    function onERC721Received(address, address from, uint256 tokenId, bytes calldata)
        external
        override
        returns (bytes4)
    {
        if (msg.sender != address(nft)) revert UnexpectedNFT();
        if (!_positions.contains(tokenId)) {
            if (from != owner) revert UnexpectedNFT();
            _requireActive();
            _register(tokenId);
        }
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Unstake a position, pay out its pending UP (net of fee) and send the NFT to `to`.
    function withdraw(uint256 tokenId, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        PositionInfo storage p = _position(tokenId);
        CompounderRegistry.PoolInfo memory info = registry.getPoolInfo(p.pool);

        uint256 bal0 = IERC20(info.token0).balanceOf(address(this));
        uint256 bal1 = IERC20(info.token1).balanceOf(address(this));

        uint256 paid;
        if (p.staked) {
            uint256 up = _unstake(tokenId, p, info.gauge);
            paid = _payoutUp(tokenId, up);
        }
        _forwardDelta(info.token0, bal0);
        _forwardDelta(info.token1, bal1);

        _positions.remove(tokenId);
        delete _positionInfo[tokenId];
        nft.safeTransferFrom(address(this), to, tokenId);
        emit Withdrawn(tokenId, to, paid);
    }

    /// @notice Claim pending UP for a staked position without compounding. Fee applies.
    function claim(uint256 tokenId) external onlyOwner nonReentrant {
        PositionInfo storage p = _position(tokenId);
        if (!p.staked) revert NotStaked();
        CompounderRegistry.PoolInfo memory info = registry.getPoolInfo(p.pool);
        uint256 up = _claimRewards(tokenId, p, info.gauge);
        _payoutUp(tokenId, up);
    }

    /// @notice Add liquidity to a tracked position using tokens pulled from the owner.
    function increaseLiquidity(
        uint256 tokenId,
        uint256 amount0,
        uint256 amount1,
        uint256 amount0Min,
        uint256 amount1Min
    ) external onlyOwner nonReentrant {
        PositionInfo storage p = _position(tokenId);
        CompounderRegistry.PoolInfo memory info = registry.getPoolInfo(p.pool);

        uint256 bal0 = IERC20(info.token0).balanceOf(address(this));
        uint256 bal1 = IERC20(info.token1).balanceOf(address(this));
        if (amount0 > 0) IERC20(info.token0).safeTransferFrom(msg.sender, address(this), amount0);
        if (amount1 > 0) IERC20(info.token1).safeTransferFrom(msg.sender, address(this), amount1);

        if (p.staked) _unstakeAndPayout(tokenId, p, info.gauge);

        (uint128 liquidity, uint256 used0, uint256 used1) =
            _increase(tokenId, info.token0, info.token1, amount0, amount1, amount0Min, amount1Min);
        emit LiquidityIncreased(tokenId, liquidity, used0, used1);

        // Refund whatever was not used.
        _forwardDelta(info.token0, bal0);
        _forwardDelta(info.token1, bal1);

        _restake(tokenId, p, info.gauge);
    }

    /// @notice Remove liquidity from a tracked position and send the tokens to the owner.
    function decreaseLiquidity(uint256 tokenId, uint128 liquidity, uint256 amount0Min, uint256 amount1Min)
        external
        onlyOwner
        nonReentrant
    {
        PositionInfo storage p = _position(tokenId);
        CompounderRegistry.PoolInfo memory info = registry.getPoolInfo(p.pool);

        if (p.staked) _unstakeAndPayout(tokenId, p, info.gauge);

        (uint256 amount0, uint256 amount1) = nft.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidity,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline: block.timestamp
            })
        );
        nft.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId, recipient: owner, amount0Max: type(uint128).max, amount1Max: type(uint128).max
            })
        );
        emit LiquidityDecreased(tokenId, liquidity, amount0, amount1);

        (,,,,,,, uint128 remaining,,,,) = nft.positions(tokenId);
        if (remaining > 0) _restake(tokenId, p, info.gauge);
    }

    /// @notice Unstake a position without restaking. Pending UP is paid out net of fee.
    function emergencyUnstake(uint256 tokenId) external onlyOwner nonReentrant {
        PositionInfo storage p = _position(tokenId);
        if (!p.staked) revert NotStaked();
        CompounderRegistry.PoolInfo memory info = registry.getPoolInfo(p.pool);
        uint256 bal0 = IERC20(info.token0).balanceOf(address(this));
        uint256 bal1 = IERC20(info.token1).balanceOf(address(this));
        _unstakeAndPayout(tokenId, p, info.gauge);
        _forwardDelta(info.token0, bal0);
        _forwardDelta(info.token1, bal1);
    }

    /// @notice Stake a tracked position that is currently held unstaked.
    function restake(uint256 tokenId) external onlyOwner nonReentrant {
        PositionInfo storage p = _position(tokenId);
        if (p.staked) revert AlreadyStaked();
        CompounderRegistry.PoolInfo memory info = registry.getPoolInfo(p.pool);
        if (!voter.isAlive(info.gauge)) revert GaugeNotAlive();
        uint256 bal0 = IERC20(info.token0).balanceOf(address(this));
        uint256 bal1 = IERC20(info.token1).balanceOf(address(this));
        _stake(tokenId, p, info.gauge);
        _forwardDelta(info.token0, bal0);
        _forwardDelta(info.token1, bal1);
    }

    /*//////////////////////////////////////////////////////////////
                               COMPOUNDING
    //////////////////////////////////////////////////////////////*/

    /// @notice Compound specific positions. Callable by the owner or the delegated keeper.
    function compound(uint256[] calldata tokenIds) external onlyOwnerOrKeeper nonReentrant {
        uint256 gasStart = gasleft();
        _requireActive();
        for (uint256 i = 0; i < tokenIds.length; i++) {
            _compound(tokenIds[i], false);
        }
        lastCompoundAt = uint40(block.timestamp);
        _reimburse(gasStart);
    }

    /// @notice Compound every tracked position whose pending UP is at least `minUpToCompound`.
    function compoundAll() external onlyOwnerOrKeeper nonReentrant {
        uint256 gasStart = gasleft();
        _requireActive();
        uint256[] memory ids = _positions.values();
        for (uint256 i = 0; i < ids.length; i++) {
            _compound(ids[i], true);
        }
        lastCompoundAt = uint40(block.timestamp);
        _reimburse(gasStart);
    }

    struct CompoundCtx {
        uint256 tokenId;
        address gauge;
        address token0;
        address token1;
        uint160 sqrtPriceX96;
        int24 tickLower;
        int24 tickUpper;
        uint16 slippageBps;
    }

    function _compound(uint256 tokenId, bool skipBelowMin) internal returns (bool) {
        PositionInfo storage p = _position(tokenId);
        CompounderRegistry.PoolInfo memory info = registry.getPoolInfo(p.pool);
        if (!info.enabled) {
            if (skipBelowMin) return false;
            revert PoolNotEnabled(p.pool);
        }
        if (skipBelowMin && p.staked && ICLGauge(info.gauge).earned(address(this), tokenId) < minUpToCompound) {
            return false;
        }

        CompounderRegistry.Config memory cfg = registry.config();

        // 1. Claim and take the protocol fee.
        uint256 up;
        uint256 fee;
        if (p.staked) {
            up = _claimRewards(tokenId, p, info.gauge);
            fee = _takeFee(up, cfg);
        }

        // 2. Price sanity: spot must be close to TWAP before we swap or add liquidity.
        CompoundCtx memory ctx = _context(tokenId, p.pool, info, cfg);

        // 3. Swap every UP we hold into the pool tokens in the ratio the range needs.
        _swapRewards(ctx, cfg);

        // 4. Add everything we hold of the pool tokens back into the position.
        (uint128 added, uint256 used0, uint256 used1) = _addLiquidity(ctx, p);

        p.lastCompoundedAt = uint40(block.timestamp);
        p.compoundCount++;
        emit Compounded(tokenId, up, fee, used0, used1, added);
        return true;
    }

    function _context(
        uint256 tokenId,
        address pool,
        CompounderRegistry.PoolInfo memory info,
        CompounderRegistry.Config memory cfg
    ) internal view returns (CompoundCtx memory ctx) {
        (uint160 sqrtPriceX96, int24 spotTick,,,,) = ICLPool(pool).slot0();
        int24 twap = TwapLib.twapTick(pool, cfg.twapWindow);
        if (TwapLib.tickDeviation(spotTick, twap) > cfg.maxTickDeviation) revert PriceDeviation(spotTick, twap);

        ctx.tokenId = tokenId;
        ctx.gauge = info.gauge;
        ctx.token0 = info.token0;
        ctx.token1 = info.token1;
        ctx.sqrtPriceX96 = sqrtPriceX96;
        ctx.slippageBps = cfg.slippageBps;
        (,,,,, ctx.tickLower, ctx.tickUpper,,,,,) = nft.positions(tokenId);
    }

    function _swapRewards(CompoundCtx memory ctx, CompounderRegistry.Config memory cfg) internal {
        uint256 upBalance = UP.balanceOf(address(this));
        if (upBalance == 0) return;
        uint256 to0 = _amountForToken0(ctx, upBalance);
        _swap(ctx.token0, to0, cfg);
        _swap(ctx.token1, upBalance - to0, cfg);
    }

    /// @dev Split `amount` of UP so that, after swap fees, the resulting token values match the
    ///      range's required ratio. x = (1-w)(1-f1) A / ((1-f0) w + (1-w)(1-f1)).
    function _amountForToken0(CompoundCtx memory ctx, uint256 amount) internal view returns (uint256) {
        uint256 wad = PositionMath.WAD;
        uint256 w1 = PositionMath.token1Weight(ctx.sqrtPriceX96, ctx.tickLower, ctx.tickUpper);
        if (w1 == 0) return amount;
        if (w1 == wad) return 0;
        uint256 keep0 = wad - _routeFeeWad(ctx.token0);
        uint256 keep1 = wad - _routeFeeWad(ctx.token1);
        uint256 num = (wad - w1) * keep1;
        uint256 den = (keep0 * w1 + num) / wad;
        return (amount * (num / wad)) / den;
    }

    function _routeFeeWad(address tokenOut) internal view returns (uint256) {
        if (tokenOut == address(UP)) return 0;
        bytes memory path = registry.getRoute(address(UP), tokenOut);
        if (path.length == 0) revert RouteMissing(address(UP), tokenOut);
        return TwapLib.pathFeeWad(path, address(clFactory));
    }

    function _addLiquidity(CompoundCtx memory ctx, PositionInfo storage p)
        internal
        returns (uint128 added, uint256 used0, uint256 used1)
    {
        uint256 bal0 = IERC20(ctx.token0).balanceOf(address(this));
        uint256 bal1 = IERC20(ctx.token1).balanceOf(address(this));
        uint128 expected = PositionMath.liquidityForAmounts(ctx.sqrtPriceX96, ctx.tickLower, ctx.tickUpper, bal0, bal1);
        if (expected == 0) return (0, 0, 0);

        if (p.staked) _unstake(ctx.tokenId, p, ctx.gauge);
        (added, used0, used1) = _increaseWithSlippage(ctx, expected, bal0, bal1);
        _restake(ctx.tokenId, p, ctx.gauge);
    }

    function _increaseWithSlippage(CompoundCtx memory ctx, uint128 expected, uint256 bal0, uint256 bal1)
        internal
        returns (uint128, uint256, uint256)
    {
        (uint256 min0, uint256 min1) =
            PositionMath.amountsForLiquidity(ctx.sqrtPriceX96, ctx.tickLower, ctx.tickUpper, expected);
        min0 = (min0 * (BPS - ctx.slippageBps)) / BPS;
        min1 = (min1 * (BPS - ctx.slippageBps)) / BPS;
        return _increase(ctx.tokenId, ctx.token0, ctx.token1, bal0, bal1, min0, min1);
    }

    function _swap(address tokenOut, uint256 amountIn, CompounderRegistry.Config memory cfg) internal {
        if (amountIn == 0 || tokenOut == address(UP)) return;
        bytes memory path = registry.getRoute(address(UP), tokenOut);
        if (path.length == 0) revert RouteMissing(address(UP), tokenOut);

        uint256 quote = TwapLib.quotePath(path, amountIn, address(clFactory), cfg.twapWindow);
        uint256 minOut = (quote * (BPS - cfg.slippageBps)) / BPS;

        UP.forceApprove(address(router), amountIn);
        router.exactInput(
            ISwapRouter.ExactInputParams({
                path: path,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: minOut
            })
        );
    }

    function _reimburse(uint256 gasStart) internal {
        if (msg.sender == owner || msg.sender != keeper) return;
        CompounderRegistry.Config memory cfg = registry.config();
        uint256 gasUsed = gasStart - gasleft() + cfg.gasOverhead;
        uint256 price = tx.gasprice > cfg.maxGasPrice ? cfg.maxGasPrice : tx.gasprice;
        uint256 cost = (gasUsed * price * (BPS + cfg.gasPremiumBps)) / BPS;
        if (cost == 0) return;
        if (address(this).balance < cost) revert InsufficientGas(cost, address(this).balance);
        totalGasReimbursed += cost;
        (bool ok,) = msg.sender.call{value: cost}("");
        if (!ok) revert TransferFailed();
        emit GasReimbursed(msg.sender, cost);
    }

    /*//////////////////////////////////////////////////////////////
                             USER: SETTINGS
    //////////////////////////////////////////////////////////////*/

    function setKeeper(address keeper_) external onlyOwner {
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    function setMinUpToCompound(uint256 amount) external onlyOwner {
        minUpToCompound = amount;
        emit MinUpToCompoundSet(amount);
    }

    function fundGas() external payable {
        emit GasFunded(msg.sender, msg.value);
    }

    receive() external payable {
        emit GasFunded(msg.sender, msg.value);
    }

    function withdrawGas(uint256 amount, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit GasWithdrawn(to, amount);
    }

    /// @notice Send the full balance of any ERC20 held here to `to`.
    function sweep(address token, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, IERC20(token).balanceOf(address(this)));
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    function positions() external view returns (uint256[] memory) {
        return _positions.values();
    }

    function positionCount() external view returns (uint256) {
        return _positions.length();
    }

    function getPositionInfo(uint256 tokenId) external view returns (PositionInfo memory) {
        return _positionInfo[tokenId];
    }

    function earned(uint256 tokenId) public view returns (uint256) {
        PositionInfo storage p = _positionInfo[tokenId];
        if (p.pool == address(0) || !p.staked) return 0;
        return ICLGauge(registry.getPoolInfo(p.pool).gauge).earned(address(this), tokenId);
    }

    function gasBalance() external view returns (uint256) {
        return address(this).balance;
    }

    function isActive() public view returns (bool) {
        return !registry.config().paused && registry.implementationEnabled(version);
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNALS
    //////////////////////////////////////////////////////////////*/

    function _requireActive() internal view {
        if (registry.config().paused) revert Paused();
        if (!registry.implementationEnabled(version)) revert VersionDisabled();
    }

    function _position(uint256 tokenId) internal view returns (PositionInfo storage p) {
        p = _positionInfo[tokenId];
        if (p.pool == address(0)) revert UnknownPosition(tokenId);
    }

    function _register(uint256 tokenId) internal {
        if (_positions.contains(tokenId)) revert AlreadyTracked(tokenId);
        (,, address token0, address token1, int24 tickSpacing,,,,,,,) = nft.positions(tokenId);
        address pool = clFactory.getPool(token0, token1, tickSpacing);
        CompounderRegistry.PoolInfo memory info = registry.getPoolInfo(pool);
        if (!info.enabled) revert PoolNotEnabled(pool);
        if (!voter.isAlive(info.gauge)) revert GaugeNotAlive();

        _positions.add(tokenId);
        PositionInfo storage p = _positionInfo[tokenId];
        p.pool = pool;
        p.depositedAt = uint40(block.timestamp);

        // Staking collects any fees owed on the position; forward them to the owner.
        uint256 bal0 = IERC20(token0).balanceOf(address(this));
        uint256 bal1 = IERC20(token1).balanceOf(address(this));
        _stake(tokenId, p, info.gauge);
        _forwardDelta(token0, bal0);
        _forwardDelta(token1, bal1);

        emit Deposited(tokenId, pool);
    }

    function _stake(uint256 tokenId, PositionInfo storage p, address gauge) internal {
        nft.approve(gauge, tokenId);
        ICLGauge(gauge).deposit(tokenId);
        p.staked = true;
        emit Staked(tokenId);
    }

    /// @dev Restake after a liquidity change if the gauge is still alive, else hold unstaked.
    function _restake(uint256 tokenId, PositionInfo storage p, address gauge) internal {
        if (voter.isAlive(gauge)) {
            _stake(tokenId, p, gauge);
        } else {
            p.staked = false;
        }
    }

    /// @dev Withdraw from the gauge. Returns the UP that was auto-claimed by the gauge.
    function _unstake(uint256 tokenId, PositionInfo storage p, address gauge) internal returns (uint256 up) {
        uint256 before = UP.balanceOf(address(this));
        ICLGauge(gauge).withdraw(tokenId);
        up = UP.balanceOf(address(this)) - before;
        p.staked = false;
        _recordClaim(p, up);
        emit Unstaked(tokenId);
    }

    function _unstakeAndPayout(uint256 tokenId, PositionInfo storage p, address gauge) internal {
        uint256 up = _unstake(tokenId, p, gauge);
        _payoutUp(tokenId, up);
    }

    function _claimRewards(uint256 tokenId, PositionInfo storage p, address gauge) internal returns (uint256 up) {
        uint256 before = UP.balanceOf(address(this));
        ICLGauge(gauge).getReward(tokenId);
        up = UP.balanceOf(address(this)) - before;
        _recordClaim(p, up);
    }

    function _recordClaim(PositionInfo storage p, uint256 up) internal {
        if (up == 0) return;
        p.upClaimed += up;
        totalUpClaimed += up;
    }

    function _takeFee(uint256 up, CompounderRegistry.Config memory cfg) internal returns (uint256 fee) {
        if (up == 0) return 0;
        fee = (up * cfg.feeBps) / BPS;
        if (fee > 0) {
            totalFeesPaid += fee;
            UP.safeTransfer(cfg.treasury, fee);
        }
    }

    /// @dev Take the fee on `up` and send the remainder to the owner.
    function _payoutUp(uint256 tokenId, uint256 up) internal returns (uint256 net) {
        if (up == 0) return 0;
        uint256 fee = _takeFee(up, registry.config());
        net = up - fee;
        UP.safeTransfer(owner, net);
        emit Claimed(tokenId, up, fee);
    }

    function _increase(
        uint256 tokenId,
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1,
        uint256 amount0Min,
        uint256 amount1Min
    ) internal returns (uint128 liquidity, uint256 used0, uint256 used1) {
        if (amount0 > 0) IERC20(token0).forceApprove(address(nft), amount0);
        if (amount1 > 0) IERC20(token1).forceApprove(address(nft), amount1);
        (liquidity, used0, used1) = nft.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline: block.timestamp
            })
        );
        if (amount0 > used0) IERC20(token0).forceApprove(address(nft), 0);
        if (amount1 > used1) IERC20(token1).forceApprove(address(nft), 0);
    }

    /// @dev Send any balance of `token` above `before` to the owner.
    function _forwardDelta(address token, uint256 before) internal {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > before) IERC20(token).safeTransfer(owner, bal - before);
    }
}
