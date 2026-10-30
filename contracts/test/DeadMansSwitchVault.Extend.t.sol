// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DeadMansSwitchVault as DMS} from "../DeadMansSwitchVault.sol";
import {DMSTestBase} from "./DeadMansSwitchVault.Base.t.sol";

/// @dev extendDeadline (guardian quorum).
contract DMSExtendTest is DMSTestBase {
    uint256 internal id;

    function setUp() public override {
        super.setUp();
        id = _funded(DEP);
    }

    function _maxNd() internal view returns (uint64) {
        return uint64(block.timestamp + INTERVAL);
    }

    function test_Extend_FirstVoteOnlyRecords() public {
        vm.warp(T0 + 1 days);
        uint64 nd = _maxNd();
        bytes32 aid = _extendId(nd, 0);
        uint64 dlBefore = uint64(dms.deadline(id));
        vm.expectEmit(true, true, true, true, address(dms));
        emit DMS.GuardianApproved(id, g1, aid, 1, 2);
        _extend(id, g1, nd);
        assertEq(dms.deadline(id), dlBefore);
        assertEq(dms.approvalCount(id, aid), 1);
        assertTrue(dms.hasApproved(id, aid, g1));
        assertEq(_v(id).guardianNonce, 0);
    }

    function test_Extend_ExecutesOnlyAtThreshold() public {
        vm.warp(T0 + 1 days);
        uint64 nd = _maxNd();
        bytes32 aid = _extendId(nd, 0);
        _extend(id, g1, nd);
        vm.expectEmit(true, true, true, true, address(dms));
        emit DMS.GuardianApproved(id, g2, aid, 2, 2);
        vm.expectEmit(true, false, false, true, address(dms));
        emit DMS.DeadlineExtended(id, nd);
        _extend(id, g2, nd);
        DMS.VaultView memory v = _v(id);
        assertEq(v.deadline, nd);
        assertEq(v.lastCheckIn, T0, "extension must not touch lastCheckIn");
        assertEq(v.guardianNonce, 1);
        _assertPhase(id, DMS.Phase.Active);
    }

    function test_Extend_ThresholdOneExecutesImmediately() public {
        DMS.CreateParams memory p = _params();
        p.guardians = new address[](1);
        p.guardians[0] = g1;
        p.guardianThreshold = 1;
        uint256 id2 = _create(p);
        vm.warp(T0 + 1 days);
        uint64 nd = _maxNd();
        _extend(id2, g1, nd);
        assertEq(dms.deadline(id2), nd);
    }

    function test_Extend_DifferentTargetsDoNotCombine() public {
        vm.warp(T0 + 1 days);
        uint64 nd = _maxNd();
        _extend(id, g1, nd);
        _extend(id, g2, nd - 1);
        assertEq(dms.deadline(id), T0 + INTERVAL);
        assertEq(dms.approvalCount(id, _extendId(nd, 0)), 1);
        assertEq(dms.approvalCount(id, _extendId(nd - 1, 0)), 1);
    }

    /// @dev REWRITTEN (was test_Extend_CanRescueExpiredUntriggeredVault): guardians can no longer rescue an
    ///      expired, untriggered vault; it stays Expired and anyone can trigger it.
    function test_Extend_CannotRescueExpiredUntriggeredVault() public {
        vm.warp(T0 + INTERVAL + 2 days);
        _assertPhase(id, DMS.Phase.Expired);
        uint64 nd = _maxNd();
        address[3] memory gs = [g1, g2, g3];
        for (uint256 i; i < gs.length; ++i) {
            vm.prank(gs[i]);
            vm.expectRevert(_e(DMS.DeadlinePassed.selector, id));
            dms.extendDeadline(id, nd);
        }
        _assertPhase(id, DMS.Phase.Expired);
        assertEq(dms.deadline(id), T0 + INTERVAL);
        dms.trigger(id);
        assertTrue(_v(id).triggered);
    }

    function test_Extend_StaleVotesDieAfterNonceChange() public {
        vm.warp(T0 + 1 days);
        uint64 nd = _maxNd();
        _extend(id, g1, nd);
        // owner action bumps guardianNonce, invalidating g1's vote
        _request(id, 1e6);
        vm.prank(owner);
        dms.cancelWithdraw(id);
        assertEq(_v(id).guardianNonce, 1);
        _extend(id, g2, nd);
        assertEq(dms.deadline(id), T0 + INTERVAL, "stale g1 vote must not count");
        assertEq(dms.approvalCount(id, _extendId(nd, 1)), 1);
        _extend(id, g1, nd); // fresh nonce -> no AlreadyApproved, reaches quorum
        assertEq(dms.deadline(id), nd);
    }

    function test_RevertExtend_NotGuardian() public {
        vm.warp(T0 + 1 days);
        uint64 nd = _maxNd();
        address[4] memory bad = [stranger, owner, delegate, alice];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(bad[i]);
            vm.expectRevert(_e(DMS.NotGuardian.selector, id));
            dms.extendDeadline(id, nd);
        }
    }

    function test_RevertExtend_AlreadyTriggered() public {
        _trigger(id);
        uint64 nd = _maxNd();
        vm.prank(g1);
        vm.expectRevert(_e(DMS.VaultAlreadyTriggered.selector, id));
        dms.extendDeadline(id, nd);
    }

    function test_RevertExtend_NewDeadlineEqualsCurrent() public {
        vm.warp(T0 + 1 days);
        uint64 dl = uint64(dms.deadline(id));
        vm.prank(g1);
        vm.expectRevert(_e(DMS.ExtensionTooLarge.selector, id));
        dms.extendDeadline(id, dl);
    }

    function test_RevertExtend_NewDeadlineBelowCurrent_GuardiansCannotShorten() public {
        vm.warp(T0 + 1 days);
        uint64 dl = uint64(dms.deadline(id));
        vm.prank(g1);
        vm.expectRevert(_e(DMS.ExtensionTooLarge.selector, id));
        dms.extendDeadline(id, dl - 1);
        vm.prank(g2);
        vm.expectRevert(_e(DMS.ExtensionTooLarge.selector, id));
        dms.extendDeadline(id, uint64(block.timestamp + 1));
    }

    /// @dev REWRITTEN (was test_RevertExtend_NewDeadlineNotAfterNow, which used an expired vault and expected
    ///      ExtensionTooLarge): on an expired vault the DeadlinePassed check now precedes the range check; on an
    ///      unexpired vault a deadline not after `now` is always rejected as ExtensionTooLarge.
    function test_RevertExtend_NewDeadlineNotAfterNow() public {
        vm.warp(T0 + INTERVAL + 2 days);
        uint64 nowTs = uint64(block.timestamp);
        vm.prank(g1);
        vm.expectRevert(_e(DMS.DeadlinePassed.selector, id));
        dms.extendDeadline(id, nowTs);
        vm.prank(g1);
        vm.expectRevert(_e(DMS.DeadlinePassed.selector, id));
        dms.extendDeadline(id, nowTs - 1);

        vm.warp(T0 + INTERVAL - 1 hours); // unexpired: range check applies
        nowTs = uint64(block.timestamp);
        vm.prank(g1);
        vm.expectRevert(_e(DMS.ExtensionTooLarge.selector, id));
        dms.extendDeadline(id, nowTs);
        vm.prank(g1);
        vm.expectRevert(_e(DMS.ExtensionTooLarge.selector, id));
        dms.extendDeadline(id, nowTs - 1);
    }

    function test_RevertExtend_BeyondNowPlusInterval() public {
        vm.warp(T0 + 1 days);
        uint64 nd = _maxNd() + 1;
        vm.prank(g1);
        vm.expectRevert(_e(DMS.ExtensionTooLarge.selector, id));
        dms.extendDeadline(id, nd);
    }

    function test_RevertExtend_AtDeadlineWindowNothingToExtend() public {
        // at creation: now + interval == deadline, so no strictly larger legal value exists
        uint64 nd = _maxNd();
        vm.prank(g1);
        vm.expectRevert(_e(DMS.ExtensionTooLarge.selector, id));
        dms.extendDeadline(id, nd);
    }

    function test_RevertExtend_AlreadyApproved() public {
        vm.warp(T0 + 1 days);
        uint64 nd = _maxNd();
        bytes32 aid = _extendId(nd, 0);
        _extend(id, g1, nd);
        vm.prank(g1);
        vm.expectRevert(abi.encodeWithSelector(DMS.AlreadyApproved.selector, id, aid, g1));
        dms.extendDeadline(id, nd);
    }

    function test_RevertExtend_VaultNotFound() public {
        vm.prank(g1);
        vm.expectRevert(_e(DMS.VaultNotFound.selector, 99));
        dms.extendDeadline(99, uint64(block.timestamp + 10));
    }

    function test_Extend_DoesNotMoveFunds() public {
        vm.warp(T0 + 1 days);
        uint64 nd = _maxNd();
        _extend(id, g1, nd);
        _extend(id, g2, nd);
        assertEq(usdc.balanceOf(address(dms)), DEP);
        assertEq(usdc.balanceOf(g1), 0);
        assertEq(usdc.balanceOf(g2), 0);
        assertEq(_v(id).balance, DEP);
    }
}
