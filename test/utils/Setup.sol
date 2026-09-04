// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CompounderRegistry} from "../../src/CompounderRegistry.sol";
import {UserCompounder} from "../../src/UserCompounder.sol";
import {KeeperMulticall} from "../../src/KeeperMulticall.sol";
import {CompounderLens} from "../../src/CompounderLens.sol";
import {IUserCompounder} from "../../src/interfaces/IUserCompounder.sol";
import {ICLPool} from "../../src/interfaces/up33/ICLPool.sol";
import {ICLGauge} from "../../src/interfaces/up33/ICLGauge.sol";
import {ICLFactory} from "../../src/interfaces/up33/ICLFactory.sol";
import {IVoter} from "../../src/interfaces/up33/IVoter.sol";
import {ISwapRouter} from "../../src/interfaces/up33/ISwapRouter.sol";
import {INonfungiblePositionManager} from "../../src/interfaces/up33/INonfungiblePositionManager.sol";

/// @notice Shared fork setup for Robinhood Chain (chain id 4663).
abstract contract Setup is Test {
    // up33 mainnet
    address constant VOTER = 0x7F749fDD351C1Ceed82d76d7699CB631Eb8332a7;
    address constant CL_FACTORY = 0x1ac9dB4a2608ba45D6127B1737949b51Bb54B7F3;
    address constant NPM = 0x07F44c47743A2f36414A82b9F558ECFCf0EEdCEf;
    address constant SWAP_ROUTER = 0xC062b870E813fcA720f1e002c234369Ab3aB9415;
    address constant UP = 0x57C0E45cB534413D1C20A4240955d6bB250BB4F1;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    address constant POOL_WETH_USDG = 0x16679e2ac1A798865eCf1c1639e67693ddB1C220; // spacing 10
    address constant POOL_WETH_UP = 0x23D641FeCcD207E8794c593e8240444A0674C4Ba; // spacing 200

    address constant ROUTE_USDG_POOL_ADDR = POOL_WETH_USDG;

    IVoter voter = IVoter(VOTER);
    ICLFactory clFactory = ICLFactory(CL_FACTORY);
    INonfungiblePositionManager nft = INonfungiblePositionManager(NPM);
    ISwapRouter router = ISwapRouter(SWAP_ROUTER);
    IERC20 up = IERC20(UP);
    IERC20 weth = IERC20(WETH);
    IERC20 usdg = IERC20(USDG);

    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");
    address operator = makeAddr("operator");
    address user = makeAddr("user");
    address user2 = makeAddr("user2");

    CompounderRegistry registry;
    UserCompounder implementation;
    KeeperMulticall keeperMulticall;
    CompounderLens lens;

    bytes routeUpWeth;
    bytes routeUpUsdg;

    function setUp() public virtual {
        string memory rpc = vm.envString("ROBINHOOD_RPC_URL");
        uint256 forkBlock = vm.envOr("FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);

        registry = new CompounderRegistry(VOTER, CL_FACTORY, NPM, SWAP_ROUTER, UP, treasury, admin);
        implementation = new UserCompounder(address(registry), 1);
        keeperMulticall = new KeeperMulticall(address(registry), admin);
        lens = CompounderLens(address(keeperMulticall));

        routeUpWeth = abi.encodePacked(UP, int24(200), WETH);
        routeUpUsdg = abi.encodePacked(UP, int24(200), WETH, int24(10), USDG);

        vm.startPrank(admin);
        registry.addImplementation(address(implementation));
        registry.setRoute(UP, WETH, routeUpWeth);
        registry.setRoute(UP, USDG, routeUpUsdg);
        registry.enablePool(POOL_WETH_USDG);
        registry.enablePool(POOL_WETH_UP);
        registry.setProtocolKeeper(address(keeperMulticall));
        keeperMulticall.setOperator(operator, true);
        vm.stopPrank();

        vm.label(VOTER, "voter");
        vm.label(NPM, "nft");
        vm.label(SWAP_ROUTER, "router");
        vm.label(UP, "UP");
        vm.label(WETH, "WETH");
        vm.label(USDG, "USDG");
        vm.label(POOL_WETH_USDG, "pool WETH/USDG");
        vm.label(POOL_WETH_UP, "pool WETH/UP");
        vm.label(address(registry), "registry");
        vm.label(address(keeperMulticall), "keeperMulticall");
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function createCompounder(address who) internal returns (UserCompounder c) {
        vm.prank(who);
        c = UserCompounder(payable(registry.createCompounder()));
        vm.label(address(c), string.concat("compounder:", vm.getLabel(who)));
    }

    function fund(address token, address to, uint256 amount) internal {
        deal(token, to, IERC20(token).balanceOf(to) + amount);
    }

    function currentTick(address pool) internal view returns (int24 tick) {
        (, tick,,,,) = ICLPool(pool).slot0();
    }

    /// @dev Round a tick down to the pool spacing.
    function floorTick(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 r = tick / spacing * spacing;
        if (tick < 0 && r != tick) r -= spacing;
        return r;
    }

    /// @notice Mint a position for `who` in `pool` spanning [tickLower, tickUpper] using up to
    ///         `amount0` / `amount1` of the pool tokens (dealt to `who`).
    function mintPosition(address who, address pool, int24 tickLower, int24 tickUpper, uint256 amount0, uint256 amount1)
        internal
        returns (uint256 tokenId, uint128 liquidity)
    {
        address token0 = ICLPool(pool).token0();
        address token1 = ICLPool(pool).token1();
        int24 spacing = ICLPool(pool).tickSpacing();
        if (amount0 > 0) fund(token0, who, amount0);
        if (amount1 > 0) fund(token1, who, amount1);

        vm.startPrank(who);
        IERC20(token0).approve(NPM, amount0);
        IERC20(token1).approve(NPM, amount1);
        (tokenId, liquidity,,) = nft.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                tickSpacing: spacing,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: who,
                deadline: block.timestamp,
                sqrtPriceX96: 0
            })
        );
        vm.stopPrank();
    }

    /// @notice In-range position around the current price, `width` spacings on each side.
    function mintInRange(address who, address pool, int24 width, uint256 amount0, uint256 amount1)
        internal
        returns (uint256 tokenId, uint128 liquidity)
    {
        int24 spacing = ICLPool(pool).tickSpacing();
        int24 base = floorTick(currentTick(pool), spacing);
        return mintPosition(who, pool, base - width * spacing, base + (width + 1) * spacing, amount0, amount1);
    }

    function depositPosition(UserCompounder c, address who, uint256 tokenId) internal {
        vm.startPrank(who);
        nft.approve(address(c), tokenId);
        c.deposit(tokenId);
        vm.stopPrank();
    }

    function gaugeOf(address pool) internal view returns (ICLGauge) {
        return ICLGauge(voter.gauges(pool));
    }

    function positionLiquidity(uint256 tokenId) internal view returns (uint128 liquidity) {
        (,,,,,,, liquidity,,,,) = nft.positions(tokenId);
    }

    function swapExactIn(address who, address tokenIn, address tokenOut, int24 spacing, uint256 amountIn)
        internal
        returns (uint256 out)
    {
        fund(tokenIn, who, amountIn);
        vm.startPrank(who);
        IERC20(tokenIn).approve(SWAP_ROUTER, amountIn);
        out = router.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                tickSpacing: spacing,
                recipient: who,
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        vm.stopPrank();
    }
}
