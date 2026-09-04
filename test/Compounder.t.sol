// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    Setup,
    UserCompounder,
    CompounderRegistry,
    IUserCompounder,
    IERC20,
    ICLGauge,
    console2
} from "./utils/Setup.sol";

contract CompounderTest is Setup {
    UserCompounder c;
    uint256 tokenId;
    uint128 liq0;

    function setUp() public override {
        super.setUp();
        c = createCompounder(user);
        (tokenId, liq0) = mintInRange(user, POOL_WETH_USDG, 50, 1 ether, 2500e6);
    }

    function _ids(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }

    /*//////////////////////////////////////////////////////////////
                                DEPOSIT
    //////////////////////////////////////////////////////////////*/

    function test_deposit() public {
        depositPosition(c, user, tokenId);
        ICLGauge gauge = gaugeOf(POOL_WETH_USDG);
        assertEq(nft.ownerOf(tokenId), address(gauge));
        assertTrue(gauge.stakedContains(address(c), tokenId));
        assertEq(c.positionCount(), 1);
        assertEq(c.positions()[0], tokenId);
        IUserCompounder.PositionInfo memory p = c.getPositionInfo(tokenId);
        assertEq(p.pool, POOL_WETH_USDG);
        assertEq(p.depositedAt, block.timestamp);
        assertTrue(p.staked);
        assertEq(p.compoundCount, 0);
    }

    function test_deposit_viaSafeTransfer() public {
        vm.prank(user);
        nft.safeTransferFrom(user, address(c), tokenId);
        assertTrue(gaugeOf(POOL_WETH_USDG).stakedContains(address(c), tokenId));
        assertEq(c.positionCount(), 1);
    }

    function test_deposit_rejectsStrangers() public {
        (uint256 other,) = mintInRange(user2, POOL_WETH_USDG, 20, 0.1 ether, 250e6);
        vm.prank(user2);
        vm.expectRevert(UserCompounder.UnexpectedNFT.selector);
        nft.safeTransferFrom(user2, address(c), other);

        vm.startPrank(user2);
        nft.approve(address(c), other);
        vm.expectRevert(UserCompounder.NotOwner.selector);
        c.deposit(other);
        vm.stopPrank();
    }

    function test_deposit_rejectsDisabledPool() public {
        vm.prank(admin);
        registry.disablePool(POOL_WETH_USDG);
        vm.startPrank(user);
        nft.approve(address(c), tokenId);
        vm.expectRevert(abi.encodeWithSelector(UserCompounder.PoolNotEnabled.selector, POOL_WETH_USDG));
        c.deposit(tokenId);
        vm.stopPrank();
    }

    function test_deposit_rejectsWhenPaused() public {
        vm.prank(admin);
        registry.setPaused(true);
        vm.startPrank(user);
        nft.approve(address(c), tokenId);
        vm.expectRevert(UserCompounder.Paused.selector);
        c.deposit(tokenId);
        vm.stopPrank();
    }

    function test_deposit_forwardsOwedFees() public {
        // accrue fees on the unstaked position by trading through the pool, then deposit
        swapExactIn(user2, WETH, USDG, 10, 2 ether);
        swapExactIn(user2, USDG, WETH, 10, 4000e6);
        uint256 w = weth.balanceOf(user);
        uint256 u = usdg.balanceOf(user);
        depositPosition(c, user, tokenId);
        assertTrue(weth.balanceOf(user) > w || usdg.balanceOf(user) > u, "fees forwarded to owner");
        assertEq(weth.balanceOf(address(c)), 0);
        assertEq(usdg.balanceOf(address(c)), 0);
    }

    /*//////////////////////////////////////////////////////////////
                               COMPOUND
    //////////////////////////////////////////////////////////////*/

    function test_compound_increasesLiquidityAndPaysFee() public {
        depositPosition(c, user, tokenId);
        skip(1 days);
        uint256 earned = c.earned(tokenId);
        assertGt(earned, 0);

        vm.prank(user);
        c.compound(_ids(tokenId));

        uint128 liq1 = positionLiquidity(tokenId);
        assertGt(liq1, liq0, "liquidity grew");
        assertTrue(gaugeOf(POOL_WETH_USDG).stakedContains(address(c), tokenId), "restaked");

        IUserCompounder.PositionInfo memory p = c.getPositionInfo(tokenId);
        assertEq(p.compoundCount, 1);
        assertEq(p.lastCompoundedAt, block.timestamp);
        assertApproxEqRel(p.upClaimed, earned, 0.01e18);
        assertEq(c.totalUpClaimed(), p.upClaimed);
        assertEq(c.totalFeesPaid(), (p.upClaimed * 1_000) / 10_000);
        assertEq(up.balanceOf(treasury), c.totalFeesPaid());
        assertEq(c.lastCompoundAt(), block.timestamp);
        assertEq(up.balanceOf(address(c)), 0, "all UP converted");
        // dust should be tiny relative to what was added
        assertLt(usdg.balanceOf(address(c)), 1e4);
        assertLt(weth.balanceOf(address(c)), 1e13);
    }

    function test_compound_gasCost() public {
        depositPosition(c, user, tokenId);
        skip(1 days);
        vm.prank(user);
        uint256 g = gasleft();
        c.compound(_ids(tokenId));
        uint256 used = g - gasleft();
        console2.log("compound gas (1 position, 2 swaps)", used);
        assertLt(used, 1_500_000);
    }

    function test_compoundAll_respectsThreshold() public {
        depositPosition(c, user, tokenId);
        skip(1 hours);
        vm.prank(user);
        c.setMinUpToCompound(1_000_000 ether);
        vm.prank(user);
        c.compoundAll();
        assertEq(positionLiquidity(tokenId), liq0, "skipped");
        assertEq(c.getPositionInfo(tokenId).compoundCount, 0);

        vm.prank(user);
        c.setMinUpToCompound(0);
        vm.prank(user);
        c.compoundAll();
        assertGt(positionLiquidity(tokenId), liq0);
    }

    function test_compound_repeated() public {
        depositPosition(c, user, tokenId);
        uint128 prev = liq0;
        for (uint256 i = 0; i < 3; i++) {
            skip(12 hours);
            vm.prank(user);
            c.compoundAll();
            uint128 now_ = positionLiquidity(tokenId);
            assertGt(now_, prev);
            prev = now_;
        }
        assertEq(c.getPositionInfo(tokenId).compoundCount, 3);
    }

    function test_compound_multiplePoolsInOneCompounder() public {
        depositPosition(c, user, tokenId);
        (uint256 id2, uint128 l2) = mintInRange(user, POOL_WETH_UP, 5, 1 ether, 3000 ether);
        depositPosition(c, user, id2);
        assertEq(c.positionCount(), 2);
        skip(1 days);
        vm.prank(user);
        c.compoundAll();
        assertGt(positionLiquidity(tokenId), liq0);
        assertGt(positionLiquidity(id2), l2);
        assertEq(c.getPositionInfo(id2).compoundCount, 1);
        assertLt(up.balanceOf(address(c)), c.totalUpClaimed() / 200, "UP dust below 0.5% of claimed");
    }

    function test_compound_upIsPoolToken() public {
        // WETH/UP: only the WETH side needs a swap.
        (uint256 id2, uint128 l2) = mintInRange(user, POOL_WETH_UP, 5, 1 ether, 3000 ether);
        depositPosition(c, user, id2);
        skip(1 days);
        vm.prank(user);
        c.compound(_ids(id2));
        assertGt(positionLiquidity(id2), l2);
        console2.log("claimed", c.totalUpClaimed(), "UP dust", up.balanceOf(address(c)));
        assertLt(up.balanceOf(address(c)), c.totalUpClaimed() / 200, "UP dust below 0.5% of claimed");
    }

    function test_compound_outOfRangeSingleSided() public {
        // Range entirely above the current price: position is 100% WETH (token0).
        int24 base = floorTick(currentTick(POOL_WETH_USDG), 10);
        (uint256 id2, uint128 l2) = mintPosition(user, POOL_WETH_USDG, base + 1000, base + 2000, 1 ether, 0);
        depositPosition(c, user, id2);
        // out of range positions earn nothing; simulate idle UP arriving in the compounder
        fund(UP, address(c), 50 ether);
        vm.prank(user);
        c.compound(_ids(id2));
        assertGt(positionLiquidity(id2), l2);
        assertEq(up.balanceOf(address(c)), 0);
        assertEq(usdg.balanceOf(address(c)), 0, "no USDG bought for a token0-only range");
        assertLt(weth.balanceOf(address(c)), 1e12);
    }

    function test_compound_nothingToDoIsNoop() public {
        depositPosition(c, user, tokenId);
        vm.prank(user);
        c.compound(_ids(tokenId));
        assertEq(positionLiquidity(tokenId), liq0);
        assertEq(c.getPositionInfo(tokenId).compoundCount, 1);
        assertTrue(c.getPositionInfo(tokenId).staked);
    }

    function test_compound_deadGaugeLeavesUnstaked() public {
        depositPosition(c, user, tokenId);
        skip(1 days);
        address gauge = address(gaugeOf(POOL_WETH_USDG));
        vm.prank(voter.emergencyCouncil());
        voter.killGauge(gauge);

        vm.prank(user);
        c.compound(_ids(tokenId));
        assertGt(positionLiquidity(tokenId), liq0);
        assertFalse(c.getPositionInfo(tokenId).staked);
        assertEq(nft.ownerOf(tokenId), address(c));

        // compounding again while unstaked does nothing harmful
        vm.prank(user);
        c.compound(_ids(tokenId));
        assertFalse(c.getPositionInfo(tokenId).staked);

        vm.prank(user);
        vm.expectRevert(UserCompounder.GaugeNotAlive.selector);
        c.restake(tokenId);

        vm.prank(voter.emergencyCouncil());
        voter.reviveGauge(gauge);
        vm.prank(user);
        c.restake(tokenId);
        assertTrue(c.getPositionInfo(tokenId).staked);
        assertTrue(ICLGauge(gauge).stakedContains(address(c), tokenId));
    }

    function test_compound_revertsOnPriceDeviation() public {
        depositPosition(c, user, tokenId);
        skip(1 hours);
        // push spot far from the TWAP
        swapExactIn(user2, WETH, USDG, 10, 25 ether);
        vm.prank(user);
        vm.expectRevert();
        c.compound(_ids(tokenId));
        // once the TWAP catches up it works again
        skip(2 hours);
        vm.prank(user);
        c.compound(_ids(tokenId));
    }

    function test_compound_revertsWhenPausedOrDisabled() public {
        depositPosition(c, user, tokenId);
        skip(1 hours);
        vm.prank(admin);
        registry.setPaused(true);
        vm.prank(user);
        vm.expectRevert(UserCompounder.Paused.selector);
        c.compoundAll();
        vm.prank(admin);
        registry.setPaused(false);

        vm.prank(admin);
        registry.disablePool(POOL_WETH_USDG);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(UserCompounder.PoolNotEnabled.selector, POOL_WETH_USDG));
        c.compound(_ids(tokenId));
        vm.prank(user);
        c.compoundAll(); // silently skipped
        assertEq(c.getPositionInfo(tokenId).compoundCount, 0);
    }

    function test_compound_permissions() public {
        depositPosition(c, user, tokenId);
        vm.prank(user2);
        vm.expectRevert(UserCompounder.NotOwnerOrKeeper.selector);
        c.compoundAll();

        vm.prank(user);
        c.setKeeper(user2);
        vm.prank(user2);
        c.compoundAll();

        vm.prank(user);
        c.setKeeper(address(0));
        vm.prank(user2);
        vm.expectRevert(UserCompounder.NotOwnerOrKeeper.selector);
        c.compoundAll();
    }

    function test_compound_unknownPosition() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(UserCompounder.UnknownPosition.selector, 1));
        c.compound(_ids(1));
    }

    /*//////////////////////////////////////////////////////////////
                            CLAIM / WITHDRAW
    //////////////////////////////////////////////////////////////*/

    function test_claim() public {
        depositPosition(c, user, tokenId);
        skip(1 days);
        uint256 earned = c.earned(tokenId);
        vm.prank(user);
        c.claim(tokenId);
        uint256 got = up.balanceOf(user);
        assertApproxEqRel(got + up.balanceOf(treasury), earned, 0.01e18);
        assertEq(up.balanceOf(treasury), (got + up.balanceOf(treasury)) / 10);
        assertTrue(c.getPositionInfo(tokenId).staked);
        assertEq(c.earned(tokenId), 0);
    }

    function test_withdraw_paysPendingAndReturnsNft() public {
        depositPosition(c, user, tokenId);
        skip(1 days);
        uint256 earned = c.earned(tokenId);
        vm.prank(user);
        c.withdraw(tokenId, user);
        assertEq(nft.ownerOf(tokenId), user);
        assertEq(c.positionCount(), 0);
        assertEq(c.getPositionInfo(tokenId).pool, address(0));
        assertApproxEqRel(up.balanceOf(user) + up.balanceOf(treasury), earned, 0.01e18);
        assertGt(up.balanceOf(treasury), 0);
        assertEq(c.totalUpClaimed(), up.balanceOf(user) + up.balanceOf(treasury));
    }

    function test_withdraw_worksWhilePausedAndDisabled() public {
        depositPosition(c, user, tokenId);
        vm.startPrank(admin);
        registry.setPaused(true);
        registry.disablePool(POOL_WETH_USDG);
        registry.setImplementationEnabled(1, false);
        vm.stopPrank();
        vm.prank(user);
        c.withdraw(tokenId, user2);
        assertEq(nft.ownerOf(tokenId), user2);
    }

    function test_withdraw_onlyOwner() public {
        depositPosition(c, user, tokenId);
        vm.prank(user2);
        vm.expectRevert(UserCompounder.NotOwner.selector);
        c.withdraw(tokenId, user2);
    }

    /*//////////////////////////////////////////////////////////////
                             PASSTHROUGHS
    //////////////////////////////////////////////////////////////*/

    function test_increaseLiquidity() public {
        depositPosition(c, user, tokenId);
        fund(WETH, user, 1 ether);
        fund(USDG, user, 5000e6);
        vm.startPrank(user);
        weth.approve(address(c), 1 ether);
        usdg.approve(address(c), 5000e6);
        c.increaseLiquidity(tokenId, 1 ether, 5000e6, 0, 0);
        vm.stopPrank();
        assertGt(positionLiquidity(tokenId), liq0 * 19 / 10, "roughly doubled");
        assertTrue(c.getPositionInfo(tokenId).staked);
        assertEq(weth.balanceOf(address(c)), 0, "leftovers refunded");
        assertEq(usdg.balanceOf(address(c)), 0);
        assertGt(usdg.balanceOf(user), 0, "unused USDG refunded");
    }

    function test_decreaseLiquidity() public {
        depositPosition(c, user, tokenId);
        skip(1 hours);
        vm.prank(user);
        c.decreaseLiquidity(tokenId, liq0 / 2, 0, 0);
        assertApproxEqAbs(positionLiquidity(tokenId), liq0 - liq0 / 2, 1);
        assertTrue(c.getPositionInfo(tokenId).staked);
        assertGt(weth.balanceOf(user), 0);
        assertGt(usdg.balanceOf(user), 0);
        assertGt(up.balanceOf(user), 0, "pending UP paid on unstake");

        uint128 rest = positionLiquidity(tokenId);
        vm.prank(user);
        c.decreaseLiquidity(tokenId, rest, 0, 0);
        assertEq(positionLiquidity(tokenId), 0);
        assertFalse(c.getPositionInfo(tokenId).staked, "empty position is not restaked");
        assertEq(nft.ownerOf(tokenId), address(c));
    }

    function test_emergencyUnstakeAndRestake() public {
        depositPosition(c, user, tokenId);
        skip(1 hours);
        vm.prank(user);
        c.emergencyUnstake(tokenId);
        assertFalse(c.getPositionInfo(tokenId).staked);
        assertEq(nft.ownerOf(tokenId), address(c));
        assertGt(up.balanceOf(user), 0);
        vm.prank(user);
        vm.expectRevert(UserCompounder.NotStaked.selector);
        c.emergencyUnstake(tokenId);
        vm.prank(user);
        c.restake(tokenId);
        assertTrue(c.getPositionInfo(tokenId).staked);
        vm.prank(user);
        vm.expectRevert(UserCompounder.AlreadyStaked.selector);
        c.restake(tokenId);
    }

    /*//////////////////////////////////////////////////////////////
                              GAS & SWEEP
    //////////////////////////////////////////////////////////////*/

    function test_gasFunding() public {
        vm.deal(user, 2 ether);
        vm.prank(user);
        c.fundGas{value: 1 ether}();
        vm.prank(user);
        (bool ok,) = address(c).call{value: 0.5 ether}("");
        assertTrue(ok);
        assertEq(c.gasBalance(), 1.5 ether);
        vm.prank(user2);
        vm.expectRevert(UserCompounder.NotOwner.selector);
        c.withdrawGas(1 ether, user2);
        vm.prank(user);
        c.withdrawGas(1 ether, user2);
        assertEq(user2.balance, 1 ether);
        assertEq(c.gasBalance(), 0.5 ether);
    }

    function test_sweep() public {
        fund(UP, address(c), 10 ether);
        vm.prank(user);
        c.sweep(UP, user);
        assertEq(up.balanceOf(user), 10 ether);
        assertEq(up.balanceOf(address(c)), 0);
    }

    function test_viewsWhenEmpty() public view {
        assertEq(c.earned(999), 0);
        assertEq(c.positionCount(), 0);
        assertTrue(c.isActive());
    }
}
