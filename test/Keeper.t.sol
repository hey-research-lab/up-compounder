// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    Setup,
    UserCompounder,
    CompounderRegistry,
    KeeperMulticall,
    IUserCompounder,
    IERC20,
    console2
} from "./utils/Setup.sol";

contract KeeperTest is Setup {
    UserCompounder c1;
    UserCompounder c2;
    uint256 id1;
    uint256 id2;
    uint128 l1;
    uint128 l2;

    function setUp() public override {
        super.setUp();
        c1 = createCompounder(user);
        c2 = createCompounder(user2);
        (id1, l1) = mintInRange(user, POOL_WETH_USDG, 50, 1 ether, 2500e6);
        (id2, l2) = mintInRange(user2, POOL_WETH_UP, 5, 1 ether, 3000 ether);
        depositPosition(c1, user, id1);
        depositPosition(c2, user2, id2);

        vm.prank(user);
        c1.setKeeper(address(keeperMulticall));
        vm.prank(user2);
        c2.setKeeper(address(keeperMulticall));
        vm.deal(user, 1 ether);
        vm.prank(user);
        c1.fundGas{value: 1 ether}();
    }

    function _list(address a, address b) internal pure returns (address[] memory l) {
        l = new address[](2);
        l[0] = a;
        l[1] = b;
    }

    function test_batch_reimbursesAndIsolatesFailures() public {
        skip(1 days);
        vm.txGasPrice(0.1 gwei);
        vm.prank(operator);
        uint256 ok = keeperMulticall.batch(_list(address(c1), address(c2)));
        assertEq(ok, 1, "c2 unfunded fails, c1 succeeds");
        assertGt(positionLiquidity(id1), l1);
        assertEq(positionLiquidity(id2), l2);

        uint256 paid = c1.totalGasReimbursed();
        assertGt(paid, 0);
        assertEq(address(keeperMulticall).balance, paid);
        assertEq(c1.gasBalance(), 1 ether - paid);
        assertEq(keeperMulticall.totalBatches(), 1);
        assertEq(keeperMulticall.totalCompounds(), 1);
        assertEq(keeperMulticall.totalEthReceived(), paid);
        console2.log("reimbursed wei", paid);

        vm.prank(admin);
        keeperMulticall.withdrawETH(treasury, paid);
        assertEq(treasury.balance, paid);
    }

    function test_reimbursement_capsGasPrice() public {
        skip(1 days);
        vm.txGasPrice(100 gwei); // above maxGasPrice (1 gwei)
        uint256[] memory ids = new uint256[](1);
        ids[0] = id1;
        uint256[][] memory sel = new uint256[][](1);
        sel[0] = ids;
        address[] memory one = new address[](1);
        one[0] = address(c1);
        vm.prank(operator);
        keeperMulticall.batchSelect(one, sel);
        uint256 paid = c1.totalGasReimbursed();
        // at 1 gwei with a 10% premium, 1.5M gas would be 1.65e15; anything near 100 gwei would be > 1e17
        assertLt(paid, 3e15);
        assertGt(paid, 0);
    }

    function test_noReimbursementForOwnerCalls() public {
        skip(1 days);
        vm.txGasPrice(0.1 gwei);
        vm.prank(user);
        c1.compoundAll();
        assertEq(c1.totalGasReimbursed(), 0);
        assertEq(c1.gasBalance(), 1 ether);
    }

    function test_unfundedRevertsWithReason() public {
        skip(1 days);
        vm.txGasPrice(0.1 gwei);
        vm.prank(address(keeperMulticall));
        vm.expectRevert(); // InsufficientGas(required, available)
        c2.compoundAll();
    }

    function test_onlyOperator() public {
        vm.prank(user);
        vm.expectRevert(KeeperMulticall.NotOperator.selector);
        keeperMulticall.batch(_list(address(c1), address(c2)));
        // owner is always an operator
        vm.prank(admin);
        keeperMulticall.batch(_list(address(c1), address(c2)));
    }

    function test_batch_rejectsUnknownCompounder() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(KeeperMulticall.NotCompounder.selector, address(0xBEEF)));
        keeperMulticall.batch(_list(address(c1), address(0xBEEF)));
    }

    function test_isCompoundable_reasons() public {
        skip(1 days);
        uint256 gasPrice = 0.1 gwei;
        uint256 est = 1_500_000;

        (bool ok, KeeperMulticall.Skip reason,) = keeperMulticall.isCompoundable(address(0xBEEF), gasPrice, est, 0);
        assertFalse(ok);
        assertEq(uint256(reason), uint256(KeeperMulticall.Skip.NotCompounder));

        (ok, reason,) = keeperMulticall.isCompoundable(address(c1), gasPrice, est, 0);
        assertTrue(ok);
        assertEq(uint256(reason), uint256(KeeperMulticall.Skip.None));

        (ok, reason,) = keeperMulticall.isCompoundable(address(c2), gasPrice, est, 0);
        assertFalse(ok);
        assertEq(uint256(reason), uint256(KeeperMulticall.Skip.Unfunded));

        (ok, reason,) = keeperMulticall.isCompoundable(address(c1), gasPrice, est, 1e30);
        assertEq(uint256(reason), uint256(KeeperMulticall.Skip.BelowThreshold));

        vm.prank(user);
        c1.setMinUpToCompound(1e30);
        (ok, reason,) = keeperMulticall.isCompoundable(address(c1), gasPrice, est, 0);
        assertEq(uint256(reason), uint256(KeeperMulticall.Skip.BelowThreshold));
        vm.prank(user);
        c1.setMinUpToCompound(0);

        vm.prank(user);
        c1.setKeeper(user);
        (ok, reason,) = keeperMulticall.isCompoundable(address(c1), gasPrice, est, 0);
        assertEq(uint256(reason), uint256(KeeperMulticall.Skip.NotDelegated));
        vm.prank(user);
        c1.setKeeper(address(keeperMulticall));

        vm.prank(admin);
        registry.setPaused(true);
        (ok, reason,) = keeperMulticall.isCompoundable(address(c1), gasPrice, est, 0);
        assertEq(uint256(reason), uint256(KeeperMulticall.Skip.Inactive));
        vm.prank(admin);
        registry.setPaused(false);

        vm.prank(user);
        c1.withdraw(id1, user);
        (ok, reason,) = keeperMulticall.isCompoundable(address(c1), gasPrice, est, 0);
        assertEq(uint256(reason), uint256(KeeperMulticall.Skip.NoPositions));
    }

    function test_isCompoundable_skipsDisabledPool() public {
        skip(1 days);
        vm.prank(admin);
        registry.disablePool(POOL_WETH_USDG);
        assertGt(lens.pendingUp(address(c1)), 0, "still earning in the gauge");

        // compoundAll() skips the disabled pool but the keeper would still be reimbursed
        (bool ok, KeeperMulticall.Skip reason,) = keeperMulticall.isCompoundable(address(c1), 0.1 gwei, 1_500_000, 0);
        assertFalse(ok);
        assertEq(uint256(reason), uint256(KeeperMulticall.Skip.BelowThreshold));
        assertEq(keeperMulticall.compoundableUp(address(c1)), 0);
    }

    function test_isCompoundable_appliesMinPerPosition() public {
        (uint256 id3,) = mintInRange(user, POOL_WETH_USDG, 50, 1 ether, 2500e6);
        depositPosition(c1, user, id3);
        skip(1 days);
        uint256 e1 = c1.earned(id1);
        uint256 e3 = c1.earned(id3);
        uint256 minUp = (e1 > e3 ? e1 : e3) + 1; // above each position, below their sum
        assertLt(minUp, e1 + e3);
        vm.prank(user);
        c1.setMinUpToCompound(minUp);

        (bool ok, KeeperMulticall.Skip reason,) = keeperMulticall.isCompoundable(address(c1), 0.1 gwei, 1_500_000, 0);
        assertFalse(ok, "compoundAll() would skip both positions");
        assertEq(uint256(reason), uint256(KeeperMulticall.Skip.BelowThreshold));

        // and it really would: nothing is compounded, yet the call is reimbursed
        vm.txGasPrice(0.1 gwei);
        vm.prank(address(keeperMulticall));
        c1.compoundAll();
        assertEq(c1.getPositionInfo(id1).compoundCount, 0);
        assertEq(c1.getPositionInfo(id3).compoundCount, 0);
        assertGt(c1.totalGasReimbursed(), 0);
    }

    function test_reimbursementFor() public view {
        // (gas + overhead) * price * 1.1
        uint256 r = keeperMulticall.reimbursementFor(1_000_000, 0.1 gwei);
        assertEq(r, (1_060_000 * 0.1 gwei * 11_000) / 10_000);
        uint256 capped = keeperMulticall.reimbursementFor(1_000_000, 50 gwei);
        assertEq(capped, (1_060_000 * 1 gwei * 11_000) / 10_000);
    }

    function test_lensViews() public {
        skip(6 hours);
        (IUserCompounder.CompounderSnapshot[] memory list, uint256 total) = lens.scan(0, 10);
        assertEq(total, 2);
        assertEq(list.length, 2);
        assertEq(list[0].compounder, address(c1));
        assertEq(list[0].owner, user);
        assertEq(list[0].keeper, address(keeperMulticall));
        assertTrue(list[0].active);
        assertEq(list[0].gasBalance, 1 ether);
        assertEq(list[0].positionCount, 1);
        assertGt(list[0].pendingUp, 0);
        assertEq(list[0].pendingUp, lens.pendingUp(address(c1)));

        (list,) = lens.scan(1, 10);
        assertEq(list.length, 1);
        assertEq(list[0].compounder, address(c2));
        (list,) = lens.scan(5, 10);
        assertEq(list.length, 0);

        IUserCompounder.PositionSnapshot[] memory ps = lens.positionSnapshots(address(c1));
        assertEq(ps.length, 1);
        assertEq(ps[0].tokenId, id1);
        assertEq(ps[0].pool, POOL_WETH_USDG);
        assertEq(ps[0].token0, WETH);
        assertEq(ps[0].token1, USDG);
        assertEq(ps[0].tickSpacing, 10);
        assertTrue(ps[0].inRange);
        assertTrue(ps[0].staked);
        assertTrue(ps[0].poolEnabled);
        assertEq(ps[0].liquidity, l1);
        assertGt(ps[0].earned, 0);

        (
            address comp,
            IUserCompounder.CompounderSnapshot memory s,
            IUserCompounder.PositionSnapshot[] memory pos,
            address[] memory prev
        ) = lens.userView(user);
        assertEq(comp, address(c1));
        assertEq(s.owner, user);
        assertEq(pos.length, 1);
        assertEq(prev.length, 0);

        (comp, s, pos, prev) = lens.userView(makeAddr("nobody"));
        assertEq(comp, address(0));
        assertEq(pos.length, 0);

        uint256[] memory byPool = lens.positionsByPool(address(c1), POOL_WETH_USDG);
        assertEq(byPool.length, 1);
        byPool = lens.positionsByPool(address(c1), POOL_WETH_UP);
        assertEq(byPool.length, 0);
    }

    function test_batchGas_manyPositions() public {
        // one compounder with several positions in both pools
        uint256[] memory ids = new uint256[](4);
        for (uint256 i = 0; i < 4; i++) {
            address pool = i % 2 == 0 ? POOL_WETH_USDG : POOL_WETH_UP;
            (ids[i],) = i % 2 == 0
                ? mintInRange(user, pool, 30 + int24(int256(i)), 0.5 ether, 1250e6)
                : mintInRange(user, pool, 3 + int24(int256(i)), 0.5 ether, 1500 ether);
            depositPosition(c1, user, ids[i]);
        }
        skip(1 days);
        vm.txGasPrice(0.1 gwei);
        address[] memory one = new address[](1);
        one[0] = address(c1);
        vm.prank(operator);
        uint256 g = gasleft();
        keeperMulticall.batch(one);
        console2.log("batch gas for 5 positions", g - gasleft());
        assertEq(c1.getPositionInfo(ids[3]).compoundCount, 1);
    }
}
