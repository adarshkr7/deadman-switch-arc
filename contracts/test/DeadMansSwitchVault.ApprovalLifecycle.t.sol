// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;


import {DeadMansSwitchVault as DMS} from "../DeadMansSwitchVault.sol";
import {DMSApprovalBase} from "./DeadMansSwitchVault.Approval.Base.t.sol";

/// @dev Approval lifecycle: cleared by cancel / execution, veto after approval, execution side effects.
contract DMSApprovalLifecycleTest is DMSApprovalBase {
    function _cancelClearsApproval(address who) internal {
        _setDel(delegate);
        _proposeQuorum(id, newOwner);
        _approveRot(id, owner, newOwner);
        vm.prank(who);
        dms.cancelOwnerRotation(id);
        DMS.PendingRotation memory r = dms.getPendingRotation(id);
        assertFalse(r.exists);
        assertFalse(r.approved, "approval cleared with the pending rotation");
        // the SAME newOwner is re-proposed with a fresh quorum: it starts unapproved
        _proposeQuorum(id, newOwner);
        r = dms.getPendingRotation(id);
        assertTrue(r.exists);
        assertFalse(r.approved);
        _ready();
        _execRevert(_e(DMS.RotationNotApproved.selector, id));
        _approveRot(id, delegate, newOwner);
        _exec();
        assertEq(_v(id).owner, newOwner);
    }

    function test_Cancel_ClearsApproval_Owner() public { _cancelClearsApproval(owner); }
    function test_Cancel_ClearsApproval_Delegate() public { _cancelClearsApproval(delegate); }
    function test_Cancel_ClearsApproval_Alice() public { _cancelClearsApproval(alice); }
    function test_Cancel_ClearsApproval_Bob() public { _cancelClearsApproval(bob); }

    function test_Cancel_AfterTimelockClearsApproval() public {
        _proposeQuorum(id, newOwner);
        _approveRot(id, owner, newOwner);
        _ready();
        vm.warp(block.timestamp + 1 days);
        vm.prank(bob);
        dms.cancelOwnerRotation(id);
        _execRevert(_e(DMS.NoPendingRotation.selector, id));
        _proposeQuorum(id, newOwner);
        assertFalse(dms.getPendingRotation(id).approved);
        _ready();
        _execRevert(_e(DMS.RotationNotApproved.selector, id));
    }

    function test_Execution_ClearsApproval_NextProposalStartsUnapproved() public {
        _rotate(id, newOwner);
        DMS.PendingRotation memory r = dms.getPendingRotation(id);
        assertFalse(r.exists);
        assertFalse(r.approved);
        assertEq(r.newOwner, address(0));
        address third = makeAddr("third");
        _proposeQuorum(id, third);
        r = dms.getPendingRotation(id);
        assertTrue(r.exists);
        assertFalse(r.approved, "the earlier approval does not leak into the next proposal");
        _ready();
        _execRevert(_e(DMS.RotationNotApproved.selector, id));
        _approveRot(id, newOwner, third);
        _exec();
        assertEq(_v(id).owner, third);
    }

    // ------------------------------------------------------------------ InvalidNewOwner after approval

    function test_RevertExecute_DelegateSetToPendingNewOwnerAfterDelegateApproval() public {
        _setDel(delegate);
        _proposeQuorum(id, newOwner);
        _approveRot(id, delegate, newOwner);
        _setDel(newOwner); // the owner makes the pending newOwner the delegate
        _ready();
        _execRevert(abi.encodeWithSelector(DMS.InvalidNewOwner.selector));
        assertEq(_v(id).owner, owner);
        // the old delegate lost its rights, the new delegate (== newOwner) may still veto
        vm.prank(newOwner);
        dms.cancelOwnerRotation(id);
        assertFalse(dms.getPendingRotation(id).exists);
    }

    // ------------------------------------------------------------------ veto after approval

    function _vetoAfterApproval(address who, bool afterTimelock) internal {
        _setDel(delegate);
        _proposeQuorum(id, newOwner);
        _approveRot(id, owner, newOwner);
        if (afterTimelock) _ready();
        uint256 nonce = _v(id).guardianNonce;
        vm.expectEmit(true, true, false, false, address(dms));
        emit DMS.OwnerRotationCancelled(id, who);
        vm.prank(who);
        dms.cancelOwnerRotation(id);
        assertFalse(dms.getPendingRotation(id).exists);
        assertFalse(dms.getPendingRotation(id).approved);
        assertEq(_v(id).guardianNonce, nonce + 1);
        vm.warp(block.timestamp + RT + 1);
        _execRevert(_e(DMS.NoPendingRotation.selector, id));
        assertEq(_v(id).owner, owner);
    }

    function test_VetoAfterApproval_OwnerBefore() public { _vetoAfterApproval(owner, false); }
    function test_VetoAfterApproval_DelegateBefore() public { _vetoAfterApproval(delegate, false); }
    function test_VetoAfterApproval_AliceBefore() public { _vetoAfterApproval(alice, false); }
    function test_VetoAfterApproval_BobBefore() public { _vetoAfterApproval(bob, false); }
    function test_VetoAfterApproval_OwnerAfter() public { _vetoAfterApproval(owner, true); }
    function test_VetoAfterApproval_DelegateAfter() public { _vetoAfterApproval(delegate, true); }
    function test_VetoAfterApproval_AliceAfter() public { _vetoAfterApproval(alice, true); }
    function test_VetoAfterApproval_BobAfter() public { _vetoAfterApproval(bob, true); }

    function test_VetoAfterApproval_GuardiansAndStrangersCannot() public {
        _proposeQuorum(id, newOwner);
        _approveRot(id, owner, newOwner);
        address[4] memory bad = [g1, g2, stranger, newOwner];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(bad[i]);
            vm.expectRevert(_e(DMS.NotOwnerDelegateOrBeneficiary.selector, id));
            dms.cancelOwnerRotation(id);
        }
        assertTrue(dms.getPendingRotation(id).approved);
    }

    // ------------------------------------------------------------------ execution side effects unchanged

    function test_Execute_ApprovedRotation_ClearsDelegateWithdrawalAndBumpsNonce() public {
        _setDel(delegate);
        _request(id, 100e6);
        _proposeQuorum(id, newOwner);
        _approveRot(id, delegate, newOwner);
        _ready();
        uint256 nonce = _v(id).guardianNonce;
        vm.expectEmit(true, false, false, true, address(dms));
        emit DMS.CheckInDelegateSet(id, address(0));
        vm.expectEmit(true, true, false, false, address(dms));
        emit DMS.WithdrawCancelled(id, stranger);
        vm.expectEmit(true, true, true, false, address(dms));
        emit DMS.OwnerRotated(id, owner, newOwner);
        _exec();
        DMS.VaultView memory v = _v(id);
        assertEq(v.owner, newOwner);
        assertEq(v.checkInDelegate, address(0));
        assertFalse(dms.getPendingWithdrawal(id).exists);
        assertEq(v.guardianNonce, nonce + 1);
        assertEq(v.balance, DEP, "rotation moves no funds");
    }
}
