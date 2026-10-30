// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;


import {DeadMansSwitchVault as DMS} from "../DeadMansSwitchVault.sol";
import {DMSApprovalBase} from "./DeadMansSwitchVault.Approval.Base.t.sol";

/// @dev approveOwnerRotation: auth / target / double / triggered paths, events, timelock interplay.
contract DMSApprovalTest is DMSApprovalBase {
    // ------------------------------------------------------------------ success + event + getter

    function test_GetPendingRotation_ApprovedFlagLifecycle() public {
        DMS.PendingRotation memory r = dms.getPendingRotation(id);
        assertFalse(r.exists);
        assertFalse(r.approved);
        _proposeQuorum(id, newOwner);
        r = dms.getPendingRotation(id);
        assertTrue(r.exists);
        assertEq(r.newOwner, newOwner);
        assertFalse(r.approved, "a new proposal starts unapproved");
        _approveRot(id, owner, newOwner);
        r = dms.getPendingRotation(id);
        assertTrue(r.approved);
        assertTrue(r.exists);
        assertEq(r.newOwner, newOwner);
        assertEq(r.executableAt, r.proposedAt + RT, "approval does not move the timelock");
    }

    function test_Approve_ByOwnerEmitsEventAndSetsApproved() public {
        _proposeQuorum(id, newOwner);
        uint256 nonce = _v(id).guardianNonce;
        vm.expectEmit(true, true, true, false, address(dms));
        emit DMS.OwnerRotationApproved(id, newOwner, owner);
        _approveRot(id, owner, newOwner);
        assertTrue(dms.getPendingRotation(id).approved);
        assertEq(_v(id).owner, owner, "approval alone does not rotate");
        assertEq(_v(id).guardianNonce, nonce, "approval does not touch guardian votes");
    }

    function test_Approve_ByDelegateEmitsEventAndSetsApproved() public {
        _setDel(delegate);
        _proposeQuorum(id, newOwner);
        vm.expectEmit(true, true, true, false, address(dms));
        emit DMS.OwnerRotationApproved(id, newOwner, delegate);
        _approveRot(id, delegate, newOwner);
        assertTrue(dms.getPendingRotation(id).approved);
        assertEq(_v(id).owner, owner);
    }

    function test_Approve_BeforeTimelockThenRevertsNotReadyOneSecondBeforeAndSucceedsAtTimelock() public {
        _proposeQuorum(id, newOwner);
        _approveRot(id, owner, newOwner);
        uint64 ready = dms.getPendingRotation(id).executableAt;
        vm.warp(ready - 1);
        _execRevert(_e(DMS.RotationNotReady.selector, id));
        vm.warp(ready);
        vm.expectEmit(true, true, true, false, address(dms));
        emit DMS.OwnerRotated(id, owner, newOwner);
        _exec();
        assertEq(_v(id).owner, newOwner);
    }

    function test_Approve_AfterTimelockByOwner() public {
        _proposeQuorum(id, newOwner);
        _ready();
        _execRevert(_e(DMS.RotationNotApproved.selector, id));
        vm.warp(block.timestamp + 3 days);
        _approveRot(id, owner, newOwner);
        _exec();
        assertEq(_v(id).owner, newOwner);
    }

    function test_Approve_AfterTimelockByDelegate_ExecutesImmediately() public {
        _setDel(delegate);
        _proposeQuorum(id, newOwner);
        _ready();
        _approveRot(id, delegate, newOwner);
        _exec(); // same second as the approval
        assertEq(_v(id).owner, newOwner);
        assertEq(_v(id).checkInDelegate, address(0));
    }

    function test_Approve_AllowedWhileExpiredUntriggered() public {
        _toDeadline(id); // Expired, not triggered: only "triggered" blocks approval
        _proposeQuorum(id, newOwner);
        _approveRot(id, owner, newOwner);
        assertTrue(dms.getPendingRotation(id).approved);
        _ready();
        _exec();
        assertEq(_v(id).owner, newOwner);
    }

    // ------------------------------------------------------------------ reverts: authorization

    function test_RevertApprove_NotOwnerOrDelegate_AllOutsiders() public {
        _proposeQuorum(id, newOwner);
        address[9] memory bad = [g1, g2, g3, alice, bob, fallbackAddr, stranger, newOwner, depositor];
        for (uint256 i; i < bad.length; ++i) {
            _approveRevert(bad[i], newOwner, _e(DMS.NotOwnerOrDelegate.selector, id));
        }
        assertFalse(dms.getPendingRotation(id).approved, "no outsider approval stuck");
    }

    function test_RevertApprove_NotOwnerOrDelegate_FallbackAddressOfVaultAndPayoutAddress() public {
        _proposeQuorum(id, newOwner);
        _approveRevert(address(dms), newOwner, _e(DMS.NotOwnerOrDelegate.selector, id));
        _approveRevert(payoutAddr, newOwner, _e(DMS.NotOwnerOrDelegate.selector, id));
        // (address(0) is unreachable as msg.sender; it would equal the unset delegate slot, so it is not tested)
    }

    function test_RevertApprove_OldAndRevokedDelegate() public {
        _setDel(delegate);
        _proposeQuorum(id, newOwner);
        _setDel(address(0)); // revoked
        _approveRevert(delegate, newOwner, _e(DMS.NotOwnerOrDelegate.selector, id));
        _setDel(makeAddr("delegate2")); // replaced by another delegate
        _approveRevert(delegate, newOwner, _e(DMS.NotOwnerOrDelegate.selector, id));
        assertFalse(dms.getPendingRotation(id).approved);
    }

    function test_RevertApprove_OldOwnerAndOldDelegateAfterRotation() public {
        _setDel(delegate);
        _rotate(id, newOwner);
        address third = makeAddr("third");
        _proposeQuorum(id, third);
        _approveRevert(owner, third, _e(DMS.NotOwnerOrDelegate.selector, id));
        _approveRevert(delegate, third, _e(DMS.NotOwnerOrDelegate.selector, id));
        _approveRot(id, newOwner, third); // only the current owner can
        assertTrue(dms.getPendingRotation(id).approved);
    }

    function test_RevertApprove_AuthorizationCheckedBeforePendingExistence() public {
        _approveRevert(stranger, newOwner, _e(DMS.NotOwnerOrDelegate.selector, id));
        _approveRevert(g1, newOwner, _e(DMS.NotOwnerOrDelegate.selector, id));
    }

    // ------------------------------------------------------------------ reverts: state

    function test_RevertApprove_NoPendingRotation() public {
        _setDel(delegate);
        _approveRevert(owner, newOwner, _e(DMS.NoPendingRotation.selector, id));
        _approveRevert(delegate, newOwner, _e(DMS.NoPendingRotation.selector, id));
        _propose(id, g1, newOwner); // a single guardian vote creates no pending rotation
        _approveRevert(owner, newOwner, _e(DMS.NoPendingRotation.selector, id));
    }

    function test_RevertApprove_NoPendingAfterCancelAndAfterExecution() public {
        _proposeQuorum(id, newOwner);
        vm.prank(owner);
        dms.cancelOwnerRotation(id);
        _approveRevert(owner, newOwner, _e(DMS.NoPendingRotation.selector, id));
        _rotate(id, newOwner);
        _approveRevert(newOwner, newOwner, _e(DMS.NoPendingRotation.selector, id));
    }

    function test_RevertApprove_TargetMismatch() public {
        _setDel(delegate);
        _proposeQuorum(id, newOwner);
        address[4] memory wrong = [stranger, address(0), owner, g1];
        for (uint256 i; i < wrong.length; ++i) {
            _approveRevert(owner, wrong[i], _e(DMS.RotationTargetMismatch.selector, id));
            _approveRevert(delegate, wrong[i], _e(DMS.RotationTargetMismatch.selector, id));
        }
        assertFalse(dms.getPendingRotation(id).approved);
        _approveRot(id, delegate, newOwner); // the exact target still works afterwards
        assertTrue(dms.getPendingRotation(id).approved);
    }

    function test_RevertApprove_Double_SameApproverAndOtherApprover() public {
        _setDel(delegate);
        _proposeQuorum(id, newOwner);
        _approveRot(id, owner, newOwner);
        _approveRevert(owner, newOwner, _e(DMS.RotationAlreadyApproved.selector, id));
        _approveRevert(delegate, newOwner, _e(DMS.RotationAlreadyApproved.selector, id));
        assertTrue(dms.getPendingRotation(id).approved);
    }

    function test_RevertApprove_CheckOrder_MismatchBeforeAlreadyApproved() public {
        _proposeQuorum(id, newOwner);
        _approveRot(id, owner, newOwner);
        _approveRevert(owner, stranger, _e(DMS.RotationTargetMismatch.selector, id));
    }

    function test_RevertApprove_WhileTriggered() public {
        _setDel(delegate);
        vm.warp(dms.deadline(id) - 1 hours);
        _proposeQuorum(id, newOwner);
        _trigger(id);
        _approveRevert(owner, newOwner, _e(DMS.VaultAlreadyTriggered.selector, id));
        _approveRevert(delegate, newOwner, _e(DMS.VaultAlreadyTriggered.selector, id));
        assertFalse(dms.getPendingRotation(id).approved);
        // check order: authorization, pending, mismatch (and already-approved) all precede the triggered check
        _approveRevert(stranger, newOwner, _e(DMS.NotOwnerOrDelegate.selector, id));
        _approveRevert(owner, stranger, _e(DMS.RotationTargetMismatch.selector, id));
    }

    function test_RevertApprove_AlreadyApprovedPrecedesTriggered() public {
        vm.warp(dms.deadline(id) - 1 hours);
        _proposeQuorum(id, newOwner);
        _approveRot(id, owner, newOwner);
        _trigger(id);
        _approveRevert(owner, newOwner, _e(DMS.RotationAlreadyApproved.selector, id));
    }

    function test_Approve_WorksAgainAfterCheckInCancelsTrigger() public {
        vm.warp(dms.deadline(id) - 1 hours);
        _proposeQuorum(id, newOwner);
        _trigger(id);
        _approveRevert(owner, newOwner, _e(DMS.VaultAlreadyTriggered.selector, id));
        _checkInAs(owner); // rescue inside the challenge window
        _approveRot(id, owner, newOwner);
        assertTrue(dms.getPendingRotation(id).approved);
    }

    function test_RevertApprove_VaultNotFound() public {
        vm.prank(owner);
        vm.expectRevert(_e(DMS.VaultNotFound.selector, 99));
        dms.approveOwnerRotation(99, newOwner);
    }

    // ------------------------------------------------------------------ plain check-ins never approve

    function test_RevertExecute_NotApproved_AfterManyRoutineCheckInsBeforeAndAfterTimelock() public {
        _setDel(delegate);
        _proposeQuorum(id, newOwner);
        uint64 ready = dms.getPendingRotation(id).executableAt;
        // before the timelock: routine check-ins by owner and delegate
        skip(1 hours);
        _checkInAs(owner);
        skip(1 hours);
        _checkInAs(delegate);
        _execRevert(_e(DMS.RotationNotReady.selector, id));
        assertFalse(dms.getPendingRotation(id).approved);
        // after the timelock: many more
        vm.warp(ready);
        for (uint256 i; i < 10; ++i) {
            _checkInAs(i % 2 == 0 ? owner : delegate);
            _execRevert(_e(DMS.RotationNotApproved.selector, id));
            skip(1 days);
        }
        assertFalse(dms.getPendingRotation(id).approved, "check-ins never approve");
        assertEq(_v(id).owner, owner);
        // only the explicit approval unlocks it
        _approveRot(id, owner, newOwner);
        _exec();
        assertEq(_v(id).owner, newOwner);
    }

    function test_RevertExecute_NotApproved_CheckInInSameSecondAsReadyAndAfter() public {
        _proposeQuorum(id, newOwner);
        _ready();
        _checkInAs(owner);
        _execRevert(_e(DMS.RotationNotApproved.selector, id));
        skip(1);
        _checkInAs(owner);
        _execRevert(_e(DMS.RotationNotApproved.selector, id));
    }

    // ------------------------------------------------------------------ approval cleared
}
