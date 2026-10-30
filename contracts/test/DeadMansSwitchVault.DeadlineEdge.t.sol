// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DeadMansSwitchVault as DMS} from "../DeadMansSwitchVault.sol";
import {DMSTestBase} from "./DeadMansSwitchVault.Base.t.sol";

/// @dev extendDeadline after the security change: DeadlinePassed at/after the deadline, check order, and the
///      owner/delegate rescue by checkIn in the challenge window.
contract DMSDeadlineEdgeTest is DMSTestBase {
    uint256 internal id;

    function setUp() public override {
        super.setUp();
        id = _funded(DEP);
    }

    function _nd() internal view returns (uint64) {
        return uint64(block.timestamp + INTERVAL);
    }

    function _useExtension() internal returns (uint64 nd) {
        vm.warp(T0 + 1 days);
        nd = _nd();
        _extend(id, g1, nd);
        _extend(id, g2, nd);
    }

    // ------------------------------------------------------------------ DeadlinePassed

    function test_RevertExtend_ExactlyAtDeadline_DeadlinePassed() public {
        uint256 dl = dms.deadline(id);
        vm.warp(dl);
        address[3] memory gs = [g1, g2, g3];
        for (uint256 i; i < gs.length; ++i) {
            vm.prank(gs[i]);
            vm.expectRevert(_e(DMS.DeadlinePassed.selector, id));
            dms.extendDeadline(id, _nd());
        }
        assertEq(dms.deadline(id), dl);
        assertFalse(_v(id).extensionUsed);
        _assertPhase(id, DMS.Phase.Expired);
    }

    function test_RevertExtend_AfterDeadline_DeadlinePassed() public {
        uint256 dl = dms.deadline(id);
        uint256[3] memory offs = [uint256(1), 1 hours, 100 days];
        for (uint256 i; i < offs.length; ++i) {
            vm.warp(dl + offs[i]);
            vm.prank(g1);
            vm.expectRevert(_e(DMS.DeadlinePassed.selector, id));
            dms.extendDeadline(id, _nd());
        }
        assertEq(dms.deadline(id), dl);
    }

    function test_RevertExtend_DeadlinePassed_DoesNotRecordVote() public {
        vm.warp(dms.deadline(id));
        uint64 nd = _nd();
        vm.prank(g1);
        vm.expectRevert(_e(DMS.DeadlinePassed.selector, id));
        dms.extendDeadline(id, nd);
        assertEq(dms.approvalCount(id, _extendId(nd, 0)), 0);
        assertFalse(dms.hasApproved(id, _extendId(nd, 0), g1));
        assertEq(_v(id).guardianNonce, 0);
    }

    function test_RevertExtend_VoteCastBeforeExpiryCannotBeCompletedAfterExpiry() public {
        vm.warp(dms.deadline(id) - 1 hours);
        uint64 nd = _nd();
        _extend(id, g1, nd);
        vm.warp(dms.deadline(id));
        vm.prank(g2);
        vm.expectRevert(_e(DMS.DeadlinePassed.selector, id));
        dms.extendDeadline(id, nd);
        assertEq(dms.deadline(id), T0 + INTERVAL);
        assertFalse(_v(id).extensionUsed);
    }

    // ------------------------------------------------------------------ one second before the deadline

    function test_Extend_OneSecondBeforeDeadline_Works() public {
        uint256 dl = dms.deadline(id);
        vm.warp(dl - 1);
        uint64 nd = _nd(); // dl - 1 + interval: the legal maximum
        _extend(id, g1, nd);
        vm.expectEmit(true, false, false, true, address(dms));
        emit DMS.DeadlineExtended(id, nd);
        _extend(id, g2, nd);
        assertEq(dms.deadline(id), nd);
        assertTrue(_v(id).extensionUsed);
        _assertPhase(id, DMS.Phase.Active);
        vm.prank(stranger);
        vm.expectRevert(_e(DMS.VaultNotExpired.selector, id));
        dms.trigger(id);
    }

    function test_Extend_OneSecondBeforeDeadline_StillCappedToOneInterval() public {
        uint64 dl = uint64(dms.deadline(id));
        vm.warp(dl - 1);
        vm.prank(g1);
        vm.expectRevert(_e(DMS.ExtensionTooLarge.selector, id));
        dms.extendDeadline(id, _nd() + 1);
        vm.prank(g1);
        vm.expectRevert(_e(DMS.ExtensionTooLarge.selector, id));
        dms.extendDeadline(id, dl); // not strictly larger
        assertFalse(_v(id).extensionUsed);
    }

    function test_Extend_OneSecondBeforeDeadline_OncePerPeriod() public {
        vm.warp(dms.deadline(id) - 1);
        uint64 nd = _nd();
        _extend(id, g1, nd);
        _extend(id, g2, nd);
        vm.warp(nd - 1); // one second before the NEW deadline
        vm.prank(g3);
        vm.expectRevert(_e(DMS.ExtensionAlreadyUsed.selector, id));
        dms.extendDeadline(id, _nd());
        assertEq(dms.deadline(id), nd);
    }

    // ------------------------------------------------------------------ check order

    function test_RevertExtend_Order_NotGuardianFirst() public {
        vm.warp(dms.deadline(id));
        vm.prank(stranger);
        vm.expectRevert(_e(DMS.NotGuardian.selector, id));
        dms.extendDeadline(id, _nd());
        vm.prank(owner);
        vm.expectRevert(_e(DMS.NotGuardian.selector, id));
        dms.extendDeadline(id, _nd());
        _trigger(id);
        vm.prank(stranger);
        vm.expectRevert(_e(DMS.NotGuardian.selector, id));
        dms.extendDeadline(id, _nd());
    }

    function test_RevertExtend_Order_TriggeredPrecedesDeadlinePassed() public {
        _trigger(id); // at the deadline: DeadlinePassed would also apply
        assertTrue(block.timestamp >= dms.deadline(id));
        address[3] memory gs = [g1, g2, g3];
        for (uint256 i; i < gs.length; ++i) {
            vm.prank(gs[i]);
            vm.expectRevert(_e(DMS.VaultAlreadyTriggered.selector, id));
            dms.extendDeadline(id, _nd());
        }
        vm.warp(block.timestamp + 100 days);
        vm.prank(g1);
        vm.expectRevert(_e(DMS.VaultAlreadyTriggered.selector, id));
        dms.extendDeadline(id, _nd());
    }

    function test_RevertExtend_Order_DeadlinePassedPrecedesExtensionAlreadyUsed() public {
        uint64 nd = _useExtension();
        vm.warp(nd); // the (extended) deadline arrives while the allowance is spent
        assertTrue(_v(id).extensionUsed);
        vm.prank(g3);
        vm.expectRevert(_e(DMS.DeadlinePassed.selector, id));
        dms.extendDeadline(id, _nd());
        vm.warp(nd + 3 days);
        vm.prank(g3);
        vm.expectRevert(_e(DMS.DeadlinePassed.selector, id));
        dms.extendDeadline(id, _nd());
    }

    function test_RevertExtend_Order_DeadlinePassedPrecedesRangeAndAlreadyApproved() public {
        vm.warp(dms.deadline(id) - 1 hours);
        uint64 nd = _nd();
        _extend(id, g1, nd);
        vm.warp(dms.deadline(id));
        // absurd target: DeadlinePassed, not ExtensionTooLarge
        vm.prank(g2);
        vm.expectRevert(_e(DMS.DeadlinePassed.selector, id));
        dms.extendDeadline(id, uint64(block.timestamp + 10 * INTERVAL));
        // g1 re-voting the same target: DeadlinePassed, not AlreadyApproved
        vm.prank(g1);
        vm.expectRevert(_e(DMS.DeadlinePassed.selector, id));
        dms.extendDeadline(id, nd);
    }

    function test_RevertExtend_Order_ExtensionAlreadyUsedStillPrecedesRangeBeforeExpiry() public {
        _useExtension();
        vm.prank(g3);
        vm.expectRevert(_e(DMS.ExtensionAlreadyUsed.selector, id));
        dms.extendDeadline(id, uint64(block.timestamp + 10 * INTERVAL));
    }

    // ------------------------------------------------------------------ owner / delegate rescue after expiry

    function test_OwnerRescue_ViaCheckInInChallengeWindow_ResetsAllowance() public {
        uint64 nd = _useExtension(); // allowance spent
        vm.warp(nd);
        vm.prank(stranger);
        dms.trigger(id);
        // guardians cannot rescue
        vm.prank(g1);
        vm.expectRevert(_e(DMS.VaultAlreadyTriggered.selector, id));
        dms.extendDeadline(id, _nd());
        // the owner can, inside the challenge window
        vm.warp(_v(id).challengeEnd - 1);
        vm.expectEmit(true, true, false, false, address(dms));
        emit DMS.TriggerCancelled(id, owner);
        vm.expectEmit(true, true, false, false, address(dms));
        emit DMS.ExtensionAllowanceReset(id, owner);
        vm.prank(owner);
        dms.checkIn(id);
        DMS.VaultView memory v = _v(id);
        assertFalse(v.triggered);
        assertFalse(v.extensionUsed, "allowance reset by the rescue");
        assertEq(v.deadline, block.timestamp + INTERVAL);
        _assertPhase(id, DMS.Phase.Active);
        // guardians get exactly one extension again in the new period
        skip(1 days);
        uint64 nd2 = _nd();
        _extend(id, g2, nd2);
        _extend(id, g3, nd2);
        assertEq(dms.deadline(id), nd2);
        assertTrue(_v(id).extensionUsed);
        vm.prank(g1);
        vm.expectRevert(_e(DMS.ExtensionAlreadyUsed.selector, id));
        dms.extendDeadline(id, _nd());
    }

    function test_DelegateRescue_ViaCheckInInChallengeWindow_ResetsAllowance() public {
        vm.prank(owner);
        dms.setCheckInDelegate(id, delegate);
        uint64 nd = _useExtension();
        vm.warp(nd);
        vm.prank(stranger);
        dms.trigger(id);
        vm.expectEmit(true, true, false, false, address(dms));
        emit DMS.ExtensionAllowanceReset(id, delegate);
        vm.prank(delegate);
        dms.checkIn(id);
        assertFalse(_v(id).triggered);
        assertFalse(_v(id).extensionUsed);
    }

    function test_OwnerCannotRescueAfterChallengeEnds_NorExpiredUntriggered() public {
        vm.warp(dms.deadline(id));
        vm.prank(owner);
        vm.expectRevert(_e(DMS.VaultExpired.selector, id)); // expired but untriggered: no check-in
        dms.checkIn(id);
        _trigger(id);
        vm.warp(_v(id).challengeEnd);
        vm.prank(owner);
        vm.expectRevert(_e(DMS.ChallengeEnded.selector, id));
        dms.checkIn(id);
        vm.prank(g1);
        vm.expectRevert(_e(DMS.VaultAlreadyTriggered.selector, id));
        dms.extendDeadline(id, _nd());
    }

    // ------------------------------------------------------------------ free clock fuzz

    /// @dev No watcher: time jumps freely past deadlines. Guardians hammer extendDeadline; with no check-in the
    ///      deadline can never exceed creation + 2*interval and at most one extension can ever execute.
    function testFuzz_FreeClock_NoCheckIn_DeadlineNeverBeyondCreationPlusTwoIntervals(
        uint256 seed,
        uint64 intervalRaw,
        uint8 thrRaw
    ) public {
        uint64 interval = uint64(bound(intervalRaw, 60, 365 days));
        DMS.CreateParams memory p = _params();
        p.interval = interval;
        p.guardianThreshold = uint8(bound(thrRaw, 1, 3));
        uint256 vid = _create(p);
        uint256 created = block.timestamp;
        uint256 executed;
        address[3] memory gs = [g1, g2, g3];
        for (uint256 round; round < 40; ++round) {
            uint256 h = uint256(keccak256(abi.encode(seed, round)));
            vm.warp(block.timestamp + bound(h, 1, uint256(interval) / 2 + 1)); // may skip past the deadline
            uint256 dlBefore = dms.deadline(vid);
            bool wasExpired = block.timestamp >= dlBefore;
            for (uint256 i; i < gs.length; ++i) {
                uint256 span = uint256(interval) + 1;
                uint64 nd = uint64(block.timestamp + 1 + (uint256(keccak256(abi.encode(h, i))) % span));
                vm.prank(gs[i]);
                try dms.extendDeadline(vid, nd) {} catch {}
            }
            uint256 dlAfter = dms.deadline(vid);
            if (dlAfter != dlBefore) {
                executed++;
                assertFalse(wasExpired, "an expired vault was extended");
                assertGt(dlAfter, dlBefore);
            }
            assertLe(dlAfter, created + 2 * uint256(interval), "deadline > creation + 2*interval");
            assertLe(dlAfter, block.timestamp + interval);
        }
        assertLe(executed, 1, "at most one executed extension without a check-in");
        assertEq(uint256(_v(vid).lastCheckIn), created);
    }
}
