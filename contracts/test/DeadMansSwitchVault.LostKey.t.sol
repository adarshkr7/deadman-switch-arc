// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DeadMansSwitchVault as DMS} from "../DeadMansSwitchVault.sol";
import {DMSTestBase} from "./DeadMansSwitchVault.Base.t.sol";

/// @dev LOST-KEY RECOVERY: the owner key is never used after setup. The creation-time delegate approves the exact
///      replacement proposed by the guardian quorum; after the timelock anyone executes.
contract DMSLostKeyRecoveryTest is DMSTestBase {
    uint256 internal id;

    function setUp() public override {
        super.setUp();
        id = createDefaultVault(); // created by `owner`
        // creation-time setup: the delegate is configured and funds are deposited; the owner also queues a
        // withdrawal while it still held the key. After this block the owner key is "lost" and never signs again.
        vm.prank(owner);
        dms.setCheckInDelegate(id, delegate);
        _deposit(id, depositor, DEP);
        _request(id, 100e6);
    }

    function _execute() internal {
        vm.prank(stranger);
        dms.executeOwnerRotation(id);
    }

    function test_LostKey_DelegateApprovesExactOwner_QuorumProposed_TimelockPasses_AnyoneExecutes() public {
        assertTrue(dms.getPendingWithdrawal(id).exists, "stale withdrawal from the lost key");
        vm.warp(T0 + 1 days);
        _proposeQuorum(id, newOwner);
        vm.expectEmit(true, true, true, false, address(dms));
        emit DMS.OwnerRotationApproved(id, newOwner, delegate);
        vm.prank(delegate);
        dms.approveOwnerRotation(id, newOwner);
        assertTrue(dms.getPendingRotation(id).approved);

        vm.warp(dms.getPendingRotation(id).executableAt - 1);
        vm.prank(stranger);
        vm.expectRevert(_e(DMS.RotationNotReady.selector, id));
        dms.executeOwnerRotation(id);

        vm.warp(dms.getPendingRotation(id).executableAt);
        vm.expectEmit(true, false, false, true, address(dms));
        emit DMS.CheckInDelegateSet(id, address(0));
        vm.expectEmit(true, true, false, false, address(dms));
        emit DMS.WithdrawCancelled(id, stranger);
        vm.expectEmit(true, true, true, false, address(dms));
        emit DMS.OwnerRotated(id, owner, newOwner);
        _execute();

        DMS.VaultView memory v = _v(id);
        assertEq(v.owner, newOwner);
        assertEq(v.checkInDelegate, address(0), "delegate cleared");
        assertFalse(dms.getPendingWithdrawal(id).exists, "pending withdrawal cleared");
        assertFalse(dms.getPendingRotation(id).exists);
        assertEq(v.balance, DEP, "no funds moved");
        assertEq(usdc.balanceOf(owner), 0);
    }

    function test_LostKey_NewOwnerGainsRights_OldOwnerAndDelegateLoseThem() public {
        vm.warp(T0 + 1 days);
        _proposeQuorum(id, newOwner);
        vm.prank(delegate);
        dms.approveOwnerRotation(id, newOwner);
        vm.warp(dms.getPendingRotation(id).executableAt);
        _execute();

        // old owner and old delegate: nothing works
        address[2] memory olds = [owner, delegate];
        for (uint256 i; i < olds.length; ++i) {
            vm.startPrank(olds[i]);
            vm.expectRevert(_e(DMS.NotOwnerOrDelegate.selector, id));
            dms.checkIn(id);
            vm.expectRevert(_e(DMS.NotVaultOwner.selector, id));
            dms.requestWithdraw(id, 1);
            vm.expectRevert(_e(DMS.NotVaultOwner.selector, id));
            dms.executeWithdraw(id);
            vm.expectRevert(_e(DMS.NotVaultOwner.selector, id));
            dms.setCheckInDelegate(id, olds[i]);
            vm.expectRevert(_e(DMS.NotOwnerOrDelegate.selector, id));
            dms.approveOwnerRotation(id, newOwner);
            vm.expectRevert(_e(DMS.NotOwnerDelegateOrBeneficiary.selector, id));
            dms.cancelOwnerRotation(id);
            vm.stopPrank();
        }

        // new owner: checkIn, requestWithdraw, executeWithdraw after its delay
        skip(1 hours);
        vm.prank(newOwner);
        dms.checkIn(id);
        assertEq(uint256(_v(id).lastCheckIn), block.timestamp);
        vm.prank(newOwner);
        dms.requestWithdraw(id, 50e6);
        vm.prank(newOwner);
        vm.expectRevert(_e(DMS.WithdrawalNotReady.selector, id));
        dms.executeWithdraw(id);
        vm.warp(block.timestamp + WD);
        vm.prank(newOwner);
        dms.executeWithdraw(id);
        assertEq(usdc.balanceOf(newOwner), 50e6);
        assertEq(usdc.balanceOf(owner), 0);
        assertEq(_v(id).balance, DEP - 50e6);
    }

    function test_LostKey_ExecutesLongAfterTimelockWhenDelegateApprovesLate() public {
        _proposeQuorum(id, newOwner);
        vm.warp(dms.getPendingRotation(id).executableAt + 20 days);
        vm.prank(stranger);
        vm.expectRevert(_e(DMS.RotationNotApproved.selector, id));
        dms.executeOwnerRotation(id);
        // keep the vault alive only through the delegate's routine check-in, then approve
        vm.prank(delegate);
        dms.checkIn(id);
        vm.prank(stranger);
        vm.expectRevert(_e(DMS.RotationNotApproved.selector, id));
        dms.executeOwnerRotation(id);
        vm.prank(delegate);
        dms.approveOwnerRotation(id, newOwner);
        _execute();
        assertEq(_v(id).owner, newOwner);
    }

    function test_LostKey_DelegateApprovesDifferentAddress_TargetMismatch() public {
        _proposeQuorum(id, newOwner);
        address[3] memory wrong = [makeAddr("attackerFresh3"), stranger, g1];
        for (uint256 i; i < wrong.length; ++i) {
            vm.prank(delegate);
            vm.expectRevert(_e(DMS.RotationTargetMismatch.selector, id));
            dms.approveOwnerRotation(id, wrong[i]);
        }
        assertFalse(dms.getPendingRotation(id).approved);
        vm.warp(dms.getPendingRotation(id).executableAt);
        vm.prank(stranger);
        vm.expectRevert(_e(DMS.RotationNotApproved.selector, id));
        dms.executeOwnerRotation(id);
        // the exact address still works
        vm.prank(delegate);
        dms.approveOwnerRotation(id, newOwner);
        _execute();
        assertEq(_v(id).owner, newOwner);
    }

    function test_LostKey_OwnerKeyAlonePath_OwnerApproves() public {
        vm.prank(owner);
        dms.setCheckInDelegate(id, address(0)); // no delegate at all: the owner key alone
        _proposeQuorum(id, newOwner);
        vm.expectEmit(true, true, true, false, address(dms));
        emit DMS.OwnerRotationApproved(id, newOwner, owner);
        _approveRot(id, owner, newOwner);
        vm.warp(dms.getPendingRotation(id).executableAt);
        _execute();
        assertEq(_v(id).owner, newOwner);
    }

    function test_LostKey_GuardiansAloneCanNeverCompleteRecovery() public {
        // no one approves: the quorum + timelock alone achieve nothing, even years later
        _proposeQuorum(id, newOwner);
        vm.warp(dms.getPendingRotation(id).executableAt + 10 days);
        vm.prank(g1);
        vm.expectRevert(_e(DMS.RotationNotApproved.selector, id));
        dms.executeOwnerRotation(id);
        vm.prank(newOwner);
        vm.expectRevert(_e(DMS.NotOwnerOrDelegate.selector, id));
        dms.approveOwnerRotation(id, newOwner);
        assertEq(_v(id).owner, owner);
    }
}
