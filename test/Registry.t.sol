// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Setup, UserCompounder, CompounderRegistry, IERC20} from "./utils/Setup.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract RegistryTest is Setup {
    address constant POOL_CASHCAT_WETH = 0x4E8649Be40aE67EBbcff99C291B92eE03015917b; // spacing 200, no routes

    function test_constructorDefaults() public view {
        CompounderRegistry.Config memory cfg = registry.config();
        assertEq(cfg.treasury, treasury);
        assertEq(cfg.feeBps, 1_000);
        assertEq(cfg.slippageBps, 100);
        assertEq(cfg.twapWindow, 600);
        assertEq(cfg.protocolKeeper, address(keeperMulticall));
        assertFalse(cfg.paused);
        assertEq(registry.owner(), admin);
        assertEq(registry.latestVersion(), 1);
        assertEq(registry.implementations(1), address(implementation));
        assertTrue(registry.implementationEnabled(1));
    }

    function test_onlyOwnerSetters() public {
        vm.expectRevert("Ownable: caller is not the owner");
        registry.setFeeBps(100);
        vm.expectRevert("Ownable: caller is not the owner");
        registry.enablePool(POOL_CASHCAT_WETH);
        vm.expectRevert("Ownable: caller is not the owner");
        registry.setRoute(UP, WETH, routeUpWeth);
        vm.expectRevert("Ownable: caller is not the owner");
        registry.addImplementation(address(implementation));
        vm.expectRevert("Ownable: caller is not the owner");
        registry.setPaused(true);
    }

    function test_feeCap() public {
        vm.prank(admin);
        vm.expectRevert(CompounderRegistry.FeeTooHigh.selector);
        registry.setFeeBps(2_001);
        vm.prank(admin);
        registry.setFeeBps(2_000);
        assertEq(registry.config().feeBps, 2_000);
    }

    function test_bpsValidation() public {
        vm.startPrank(admin);
        vm.expectRevert(CompounderRegistry.InvalidBps.selector);
        registry.setSwapParams(10_001, 600, 100);
        vm.expectRevert(CompounderRegistry.InvalidBps.selector);
        registry.setGasParams(10_001, 0, 0);
        registry.setSwapParams(50, 300, 50);
        registry.setGasParams(500, 30_000, 2 gwei);
        vm.stopPrank();
        CompounderRegistry.Config memory cfg = registry.config();
        assertEq(cfg.slippageBps, 50);
        assertEq(cfg.twapWindow, 300);
        assertEq(cfg.maxTickDeviation, 50);
        assertEq(cfg.gasPremiumBps, 500);
        assertEq(cfg.gasOverhead, 30_000);
        assertEq(cfg.maxGasPrice, 2 gwei);
    }

    function test_setRoute_validatesEndpoints() public {
        vm.startPrank(admin);
        vm.expectRevert(CompounderRegistry.RouteEndpointMismatch.selector);
        registry.setRoute(UP, USDG, routeUpWeth);
        // unknown pool on a hop
        bytes memory bad = abi.encodePacked(UP, int24(1), USDG);
        vm.expectRevert();
        registry.setRoute(UP, USDG, bad);
        // clearing a route
        registry.setRoute(UP, USDG, "");
        assertEq(registry.getRoute(UP, USDG).length, 0);
        vm.stopPrank();
    }

    function test_enablePool_requiresRoutes() public {
        vm.prank(admin);
        vm.expectRevert();
        registry.enablePool(POOL_CASHCAT_WETH);
    }

    function test_enablePool_rejectsNonPool() public {
        vm.prank(admin);
        vm.expectRevert(CompounderRegistry.NotCLPool.selector);
        registry.enablePool(address(0xBEEF));
    }

    function test_enablePool_twiceReverts() public {
        vm.prank(admin);
        vm.expectRevert(CompounderRegistry.PoolAlreadyEnabled.selector);
        registry.enablePool(POOL_WETH_USDG);
    }

    function test_enablePool_requiresLiveGauge() public {
        address gauge = address(gaugeOf(POOL_WETH_USDG));
        vm.prank(voter.emergencyCouncil());
        voter.killGauge(gauge);

        CompounderRegistry fresh = new CompounderRegistry(VOTER, CL_FACTORY, NPM, SWAP_ROUTER, UP, treasury, admin);
        vm.startPrank(admin);
        fresh.setRoute(UP, WETH, routeUpWeth);
        fresh.setRoute(UP, USDG, routeUpUsdg);
        vm.expectRevert(CompounderRegistry.GaugeNotAlive.selector);
        fresh.enablePool(POOL_WETH_USDG);
        vm.stopPrank();
    }

    function test_poolInfoAndPagination() public view {
        assertEq(registry.poolCount(), 2);
        CompounderRegistry.PoolInfo memory info = registry.getPoolInfo(POOL_WETH_USDG);
        assertEq(info.pool, POOL_WETH_USDG);
        assertEq(info.gauge, address(gaugeOf(POOL_WETH_USDG)));
        assertEq(info.token0, WETH);
        assertEq(info.token1, USDG);
        assertEq(info.tickSpacing, 10);
        assertTrue(info.enabled);
        assertEq(info.enabledAtVersion, 1);
        assertEq(info.index, 0);

        CompounderRegistry.PoolInfo[] memory page = registry.pools(0, 10);
        assertEq(page.length, 2);
        page = registry.pools(1, 1);
        assertEq(page.length, 1);
        assertEq(page[0].pool, POOL_WETH_UP);
        page = registry.pools(5, 1);
        assertEq(page.length, 0);
        assertEq(registry.enabledPools().length, 2);
    }

    function test_disableAndReenable() public {
        vm.prank(admin);
        registry.disablePool(POOL_WETH_USDG);
        assertFalse(registry.isPoolEnabled(POOL_WETH_USDG));
        assertEq(registry.enabledPools().length, 1);
        assertEq(registry.poolCount(), 2);

        vm.prank(admin);
        vm.expectRevert(CompounderRegistry.PoolNotEnabled.selector);
        registry.disablePool(POOL_WETH_USDG);

        vm.prank(admin);
        registry.enablePool(POOL_WETH_USDG);
        assertTrue(registry.isPoolEnabled(POOL_WETH_USDG));
        assertEq(registry.getPoolInfo(POOL_WETH_USDG).index, 0, "index stable");
        assertEq(registry.poolCount(), 2, "no duplicate list entry");
    }

    function test_createCompounder() public {
        UserCompounder c = createCompounder(user);
        assertEq(c.owner(), user);
        assertEq(c.version(), 1);
        assertEq(registry.compounderOf(user), address(c));
        assertEq(registry.ownerOfCompounder(address(c)), user);
        assertEq(registry.versionOfCompounder(address(c)), 1);
        assertTrue(registry.isCompounder(address(c)));
        assertFalse(registry.isCompounder(address(implementation)));
        assertEq(registry.compounderCount(), 1);
        assertEq(registry.compounders(0, 10)[0], address(c));

        vm.prank(user);
        vm.expectRevert(CompounderRegistry.AlreadyHasCompounder.selector);
        registry.createCompounder();

        vm.expectRevert(UserCompounder.AlreadyInitialized.selector);
        vm.prank(address(registry));
        c.initialize(user2);
        vm.expectRevert(UserCompounder.NotRegistry.selector);
        c.initialize(user2);
    }

    function test_addImplementation_versionMustMatch() public {
        UserCompounder wrong = new UserCompounder(address(registry), 5);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CompounderRegistry.VersionMismatch.selector, 2));
        registry.addImplementation(address(wrong));
    }

    function test_upgradeFlow() public {
        UserCompounder c1 = createCompounder(user);
        vm.prank(user);
        vm.expectRevert(CompounderRegistry.AlreadyLatestVersion.selector);
        registry.upgradeCompounder();

        UserCompounder v2 = new UserCompounder(address(registry), 2);
        vm.prank(admin);
        registry.addImplementation(address(v2));
        assertEq(registry.latestVersion(), 2);

        vm.prank(user);
        address c2 = registry.upgradeCompounder();
        assertEq(registry.compounderOf(user), c2);
        assertEq(UserCompounder(payable(c2)).version(), 2);
        assertEq(registry.previousCompounders(user).length, 1);
        assertEq(registry.previousCompounders(user)[0], address(c1));
        assertEq(registry.compounderCount(), 2);
        // old clone still owned and usable
        assertEq(c1.owner(), user);
        assertTrue(c1.isActive());

        // deprecating v1 blocks deposits on the old clone but not withdrawals
        vm.prank(admin);
        registry.setImplementationEnabled(1, false);
        assertFalse(c1.isActive());
        (uint256 tokenId,) = mintInRange(user, POOL_WETH_USDG, 20, 0.1 ether, 250e6);
        vm.startPrank(user);
        nft.approve(address(c1), tokenId);
        vm.expectRevert(UserCompounder.VersionDisabled.selector);
        c1.deposit(tokenId);
        vm.stopPrank();

        vm.prank(user2);
        vm.expectRevert(CompounderRegistry.NoCompounder.selector);
        registry.upgradeCompounder();
    }

    function test_noImplementationDisabledLatest() public {
        vm.prank(admin);
        registry.setImplementationEnabled(1, false);
        vm.prank(user);
        vm.expectRevert(CompounderRegistry.NoImplementation.selector);
        registry.createCompounder();
    }
}
