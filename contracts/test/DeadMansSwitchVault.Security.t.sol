// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DeadMansSwitchVault as DMS} from "../DeadMansSwitchVault.sol";
import {DMSTestBase} from "./DeadMansSwitchVault.Base.t.sol";

/// @dev Security fix: explicit rotation approval gate, veto widening, InvalidNewOwner at propose, guardian-delegate ban.
contract DMSSecurityTest is DMSTestBase {
    uint256 internal id;

    function setUp() public override {
        super.setUp();
        id = _funded(DEP);
    }

    // ------------------------------------------------------------------ helpers

    function _checkInAs(address who) internal {
        vm.prank(who);
        dms.checkIn(id);
    }

    function _warpReady() internal {
        vm.warp(dms.getPendingRotation(id).executableAt);
    }

    function _execRevert(bytes memory err) internal {
        vm.prank(stranger);
        vm.expectRevert(err);
        dms.executeOwnerRotation(id);
    }

    function _exec() internal {
        vm.prank(stranger);
        dms.executeOwnerRotation(id);
    }

    function _setDelegate(address d) internal {
        vm.prank(owner);
        dms.setCheckInDelegate(id, d);
    }

    // ------------------------------------------------------------------ proposedAt

    function test_ProposedAt_RecordedAtQuorumNotAtFirstVote() public {
        _propose(id, g1, newOwner);
        skip(100);
        _propose(id, g2, newOwner);
        DMS.PendingRotation memory r = dms.getPendingRotation(id);
        assertEq(r.proposedAt, T0 + 100);
        assertEq(r.executableAt, r.proposedAt + RT);
        assertEq(r.newOwner, newOwner);
        assertTrue(r.exists);
    }

    // ------------------------------------------------------------------ explicit approval gate (was NoLivenessProof)

    /// @dev RENAMED/REWRITTEN (was test_RevertExecute_NoLivenessProof_NoCheckInAtAll).
    function test_RevertExecute_NotApproved_NoCheckInAtAll() public {
        _proposeQuorum(id, newOwner);
        _warpReady();
        _execRevert(_e(DMS.RotationNotApproved.selector, id));
        assertEq(_v(id).owner, owner);
        assertTrue(dms.getPendingRotation(id).exists, "still pending");
        assertFalse(dms.getPendingRotation(id).approved);
    }

    /// @dev REWRITTEN (was test_Execute_CheckInOneSecondLaterByOwnerCounts): owner approval, not a check-in.
    function test_Execute_ApprovedByOwnerExecutes() public {
        _proposeQuorum(id, newOwner);
        skip(1);
        _approveRot(id, owner, newOwner);
        _warpReady();
        vm.expectEmit(true, true, true, false, address(dms));
        emit DMS.OwnerRotated(id, owner, newOwner);
        _exec();
        assertEq(_v(id).owner, newOwner);
        assertFalse(dms.getPendingRotation(id).exists);
    }

    /// @dev REWRITTEN (was test_Execute_LivenessSatisfiedByDelegate): delegate approval, not a check-in.
    function test_Execute_ApprovedByDelegateExecutes() public {
        _setDelegate(delegate);
        _proposeQuorum(id, newOwner);
        skip(1);
        _approveRot(id, delegate, newOwner);
        _warpReady();
        _exec();
        DMS.VaultView memory v = _v(id);
        assertEq(v.owner, newOwner);
        assertEq(v.checkInDelegate, address(0), "delegation revoked by rotation");
    }

    /// @dev REWRITTEN (was test_NoLivenessPersistsPastTimelockThenLateCheckInUnlocks): only a late explicit
    ///      approval unlocks execution; a late check-in does not.
    function test_NotApprovedPersistsPastTimelockThenLateApprovalUnlocks() public {
        _proposeQuorum(id, newOwner);
        uint64 ready = dms.getPendingRotation(id).executableAt;
        vm.warp(ready - 1);
        _execRevert(_e(DMS.RotationNotReady.selector, id));
        vm.warp(ready);
        _execRevert(_e(DMS.RotationNotApproved.selector, id));
        vm.warp(ready + 1 days);
        _execRevert(_e(DMS.RotationNotApproved.selector, id));
        _checkInAs(owner); // a plain check-in does NOT unlock
        _execRevert(_e(DMS.RotationNotApproved.selector, id));
        vm.warp(block.timestamp + 10 days);
        _approveRot(id, owner, newOwner); // approval long after the timelock
        _exec();
        assertEq(_v(id).owner, newOwner);
    }

    /// @dev REWRITTEN (was test_RotationProposedWhileExpiredCanNeverExecute): without approval it still cannot
    ///      execute, and once triggered it is blocked for good (approval is blocked too).
    function test_RotationProposedWhileExpiredNeverExecutesWithoutApproval() public {
        _setDelegate(delegate);
        _toDeadline(id); // Expired, untriggered
        _proposeQuorum(id, newOwner);
        _warpReady();
        _execRevert(_e(DMS.RotationNotApproved.selector, id));
        // owner and delegate can no longer check in an expired vault
        vm.prank(owner);
        vm.expectRevert(_e(DMS.VaultExpired.selector, id));
        dms.checkIn(id);
        vm.prank(delegate);
        vm.expectRevert(_e(DMS.VaultExpired.selector, id));
        dms.checkIn(id);
        vm.warp(block.timestamp + 100 days);
        _execRevert(_e(DMS.RotationNotApproved.selector, id));
        // once triggered it is blocked for good
        vm.prank(stranger);
        dms.trigger(id);
        _execRevert(_e(DMS.VaultAlreadyTriggered.selector, id));
        vm.prank(owner);
        vm.expectRevert(_e(DMS.VaultAlreadyTriggered.selector, id));
        dms.approveOwnerRotation(id, newOwner);
        assertEq(_v(id).owner, owner);
    }

    // ------------------------------------------------------------------ check order

    function test_ExecuteOrder_NotReadyBeforeApproval() public {
        _proposeQuorum(id, newOwner);
        vm.warp(dms.getPendingRotation(id).executableAt - 1);
        _execRevert(_e(DMS.RotationNotReady.selector, id));
    }

    function test_ExecuteOrder_TriggeredBeforeApproval() public {
        vm.warp(dms.deadline(id) - 1 hours);
        _proposeQuorum(id, newOwner);
        _trigger(id);
        _warpReady();
        _execRevert(_e(DMS.VaultAlreadyTriggered.selector, id));
    }

    /// @dev REWRITTEN (was test_ExecuteOrder_LivenessBeforeInvalidNewOwner).
    function test_ExecuteOrder_ApprovalBeforeInvalidNewOwner() public {
        _proposeQuorum(id, newOwner);
        _setDelegate(newOwner); // pending newOwner becomes the delegate after the proposal
        _warpReady();
        _execRevert(_e(DMS.RotationNotApproved.selector, id)); // approval is checked first
        _approveRot(id, owner, newOwner);
        _execRevert(abi.encodeWithSelector(DMS.InvalidNewOwner.selector));
        _setDelegate(address(0)); // owner revokes -> now executable
        _exec();
        assertEq(_v(id).owner, newOwner);
    }

    /// @dev REWRITTEN: owner approves, THEN sets the delegate to the pending newOwner -> InvalidNewOwner even approved.
    function test_RevertExecute_DelegateSetToPendingNewOwner() public {
        _proposeQuorum(id, newOwner);
        _approveRot(id, owner, newOwner);
        _setDelegate(newOwner);
        _warpReady();
        _execRevert(abi.encodeWithSelector(DMS.InvalidNewOwner.selector));
        assertEq(_v(id).owner, owner);
        assertTrue(dms.getPendingRotation(id).approved);
    }

    // ------------------------------------------------------------------ veto (cancelOwnerRotation)

    function _cancelBy(address who, bool afterTimelock) internal {
        _setDelegate(delegate);
        _proposeQuorum(id, newOwner);
        if (afterTimelock) _warpReady();
        uint256 nonceBefore = _v(id).guardianNonce;
        vm.expectEmit(true, true, false, false, address(dms));
        emit DMS.OwnerRotationCancelled(id, who);
        vm.prank(who);
        dms.cancelOwnerRotation(id);
        assertFalse(dms.getPendingRotation(id).exists);
        assertEq(_v(id).guardianNonce, nonceBefore + 1);
        assertEq(_v(id).owner, owner);
        _warpReady2();
        _execRevert(_e(DMS.NoPendingRotation.selector, id));
    }

    function _warpReady2() internal {
        vm.warp(block.timestamp + RT + 1);
    }

    function test_Cancel_OwnerBeforeTimelock() public { _cancelBy(owner, false); }
    function test_Cancel_DelegateBeforeTimelock() public { _cancelBy(delegate, false); }
    function test_Cancel_AliceBeforeTimelock() public { _cancelBy(alice, false); }
    function test_Cancel_BobBeforeTimelock() public { _cancelBy(bob, false); }
    function test_Cancel_OwnerAfterTimelock() public { _cancelBy(owner, true); }
    function test_Cancel_DelegateAfterTimelock() public { _cancelBy(delegate, true); }
    function test_Cancel_AliceAfterTimelock() public { _cancelBy(alice, true); }
    function test_Cancel_BobAfterTimelock() public { _cancelBy(bob, true); }

    function test_RevertCancel_UnauthorizedCallers() public {
        _proposeQuorum(id, newOwner);
        address[7] memory bad = [stranger, g1, g2, g3, fallbackAddr, newOwner, depositor];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(bad[i]);
            vm.expectRevert(_e(DMS.NotOwnerDelegateOrBeneficiary.selector, id));
            dms.cancelOwnerRotation(id);
        }
        assertTrue(dms.getPendingRotation(id).exists, "veto attempts changed nothing");
    }

    function test_RevertCancel_OldDelegateAfterRevocationAndUnauthorizedWhenNonePending() public {
        _setDelegate(delegate);
        _setDelegate(address(0)); // revoked
        vm.prank(delegate);
        vm.expectRevert(_e(DMS.NotOwnerDelegateOrBeneficiary.selector, id));
        dms.cancelOwnerRotation(id);
        // authorization is checked before pending existence
        vm.prank(stranger);
        vm.expectRevert(_e(DMS.NotOwnerDelegateOrBeneficiary.selector, id));
        dms.cancelOwnerRotation(id);
    }

    function test_RevertCancel_NoPendingForEachVetoer() public {
        _setDelegate(delegate);
        address[5] memory ok = [owner, delegate, alice, bob, alice];
        for (uint256 i; i < ok.length; ++i) {
            vm.prank(ok[i]);
            vm.expectRevert(_e(DMS.NoPendingRotation.selector, id));
            dms.cancelOwnerRotation(id);
        }
    }

    function test_RevertCancel_VaultNotFound() public {
        vm.prank(alice);
        vm.expectRevert(_e(DMS.VaultNotFound.selector, 99));
        dms.cancelOwnerRotation(99);
    }

    function test_Cancel_AfterExecutionOldOwnerRevertsNewOwnerNoPending() public {
        _rotate(id, newOwner);
        vm.prank(owner);
        vm.expectRevert(_e(DMS.NotOwnerDelegateOrBeneficiary.selector, id));
        dms.cancelOwnerRotation(id);
        vm.prank(newOwner);
        vm.expectRevert(_e(DMS.NoPendingRotation.selector, id));
        dms.cancelOwnerRotation(id);
    }

    /// @dev REWRITTEN (was test_Cancel_VotesDeadAndReproposalNeedsFreshQuorumAndFreshLiveness): the approval of
    ///      the first proposal is cleared by the cancel; the re-proposal needs a fresh quorum AND fresh approval.
    function test_Cancel_VotesDeadAndReproposalNeedsFreshQuorumAndFreshApproval() public {
        _proposeQuorum(id, newOwner);
        _approveRot(id, owner, newOwner); // approval for the FIRST proposal only
        vm.prank(alice);
        dms.cancelOwnerRotation(id);

        // g1's old vote is dead: a single new vote creates nothing
        _propose(id, g1, newOwner);
        assertFalse(dms.getPendingRotation(id).exists);
        assertEq(dms.approvalCount(id, _rotId(newOwner, _v(id).guardianNonce)), 1);
        // g3's single vote for the same target is also only vote 2 under the new nonce -> quorum
        skip(5);
        _propose(id, g3, newOwner);
        DMS.PendingRotation memory r = dms.getPendingRotation(id);
        assertTrue(r.exists, "re-proposal after cancel works with a fresh quorum");
        assertEq(r.proposedAt, block.timestamp);
        assertFalse(r.approved, "re-proposal starts unapproved");

        _warpReady();
        _execRevert(_e(DMS.RotationNotApproved.selector, id)); // old approval does not carry over
        _approveRot(id, owner, newOwner);
        _exec();
        assertEq(_v(id).owner, newOwner);
    }

    // ------------------------------------------------------------------ InvalidNewOwner at propose

    function test_RevertPropose_InvalidNewOwnerAllCases() public {
        _setDelegate(delegate);
        address[10] memory bad = [address(0), address(dms), owner, g1, g2, g3, alice, bob, delegate, fallbackAddr];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(g1);
            vm.expectRevert(DMS.InvalidNewOwner.selector);
            dms.proposeOwnerRotation(id, bad[i]);
        }
        // the checks apply to every guardian and to the quorum-completing vote too
        vm.prank(g3);
        vm.expectRevert(DMS.InvalidNewOwner.selector);
        dms.proposeOwnerRotation(id, bob);
        assertFalse(dms.getPendingRotation(id).exists);
    }

    function test_Propose_DelegateAddressAllowedOnlyWhileNotCurrentDelegate() public {
        _propose(id, g1, delegate); // not (yet) the delegate -> accepted as a vote
        assertEq(dms.approvalCount(id, _rotId(delegate, 0)), 1);
        _setDelegate(delegate);
        vm.prank(g2);
        vm.expectRevert(DMS.InvalidNewOwner.selector);
        dms.proposeOwnerRotation(id, delegate);
    }

    function test_Propose_ValidFreshAddressStillWorks() public {
        _proposeQuorum(id, makeAddr("freshNewOwner"));
        assertTrue(dms.getPendingRotation(id).exists);
    }

    // ------------------------------------------------------------------ setCheckInDelegate guardian ban

    function test_RevertSetDelegate_CurrentGuardian() public {
        address[3] memory gs = [g1, g2, g3];
        for (uint256 i; i < gs.length; ++i) {
            vm.prank(owner);
            vm.expectRevert(DMS.InvalidDelegate.selector);
            dms.setCheckInDelegate(id, gs[i]);
        }
        assertEq(_v(id).checkInDelegate, address(0));
    }

    function test_SetDelegate_NonGuardianStillAllowedWithEvent() public {
        vm.expectEmit(true, false, false, true, address(dms));
        emit DMS.CheckInDelegateSet(id, delegate);
        _setDelegate(delegate);
        assertEq(_v(id).checkInDelegate, delegate);
    }
}
