// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";
import {DeadMansSwitchVault as DMS} from "../DeadMansSwitchVault.sol";
import {DMSTestBase} from "./DeadMansSwitchVault.Base.t.sol";

/// @dev Security fix: at most ONE executed guardian extension per check-in period (`extensionUsed`).
contract DMSExtensionAllowanceTest is DMSTestBase {
    uint256 internal id;
    bytes32 internal constant RESET_SIG = keccak256("ExtensionAllowanceReset(uint256,address)");

    function setUp() public override {
        super.setUp();
        id = _funded(DEP);
    }

    /// @dev Warp one day in and execute one quorum extension; returns the new deadline.
    function _useExtension() internal returns (uint64 nd) {
        vm.warp(T0 + 1 days);
        nd = uint64(block.timestamp + INTERVAL);
        _extend(id, g1, nd);
        _extend(id, g2, nd);
    }

    function _nextValid() internal view returns (uint64) {
        return uint64(block.timestamp + INTERVAL);
    }

    function _countReset(Vm.Log[] memory logs) internal pure returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == RESET_SIG) n++;
        }
    }

    // ------------------------------------------------------------------ flag accuracy

    function test_ExtensionUsed_FalseAtCreationAndAfterFirstVote_TrueAtQuorum() public {
        assertFalse(_v(id).extensionUsed);
        vm.warp(T0 + 1 days);
        uint64 nd = _nextValid();
        _extend(id, g1, nd);
        assertFalse(_v(id).extensionUsed, "single vote does not use the allowance");
        vm.expectEmit(true, false, false, true, address(dms));
        emit DMS.DeadlineExtended(id, nd);
        _extend(id, g2, nd);
        assertTrue(_v(id).extensionUsed);
        assertEq(dms.deadline(id), nd);
    }

    function test_ExtensionUsed_ThresholdOneVaultUsesOnFirstVote() public {
        DMS.CreateParams memory p = _params();
        p.guardianThreshold = 1;
        uint256 id1 = _create(p);
        vm.warp(T0 + 1 days);
        _extend(id1, g1, _nextValid());
        assertTrue(_v(id1).extensionUsed);
        assertFalse(_v(id).extensionUsed, "other vaults unaffected");
        vm.warp(T0 + 3 days);
        vm.prank(g2);
        vm.expectRevert(_e(DMS.ExtensionAlreadyUsed.selector, id1));
        dms.extendDeadline(id1, _nextValid());
    }

    // ------------------------------------------------------------------ ExtensionAlreadyUsed

    function test_RevertExtend_SecondExtensionSamePeriod_DifferentDeadlineAndGuardian() public {
        _useExtension();
        vm.warp(T0 + 3 days);
        uint64 nd2 = _nextValid();
        address[3] memory gs = [g1, g2, g3];
        for (uint256 i; i < gs.length; ++i) {
            vm.prank(gs[i]);
            vm.expectRevert(_e(DMS.ExtensionAlreadyUsed.selector, id));
            dms.extendDeadline(id, nd2);
        }
        assertEq(dms.deadline(id), T0 + 1 days + INTERVAL, "deadline unchanged");
    }

    function test_RevertExtend_UsedIsCheckedBeforeRecordingVoteOrAlreadyApproved() public {
        uint64 nd = _useExtension();
        uint256 nonce = _v(id).guardianNonce;
        // g1 already voted nd under the OLD nonce; re-voting must report ExtensionAlreadyUsed, not AlreadyApproved
        vm.prank(g1);
        vm.expectRevert(_e(DMS.ExtensionAlreadyUsed.selector, id));
        dms.extendDeadline(id, nd);
        vm.warp(T0 + 3 days);
        uint64 nd2 = _nextValid();
        vm.prank(g3);
        vm.expectRevert(_e(DMS.ExtensionAlreadyUsed.selector, id));
        dms.extendDeadline(id, nd2);
        // no vote was recorded and the nonce was not touched
        assertEq(dms.approvalCount(id, _extendId(nd2, nonce)), 0);
        assertFalse(dms.hasApproved(id, _extendId(nd2, nonce), g3));
        assertEq(_v(id).guardianNonce, nonce);
    }

    function test_RevertExtend_UsedBeatsRangeCheck() public {
        _useExtension();
        vm.prank(g3);
        vm.expectRevert(_e(DMS.ExtensionAlreadyUsed.selector, id));
        dms.extendDeadline(id, uint64(block.timestamp + 10 * INTERVAL)); // would be ExtensionTooLarge if unused
    }

    function test_RevertExtend_UsedStillRequiresGuardianAndNotTriggered() public {
        _useExtension();
        vm.prank(stranger);
        vm.expectRevert(_e(DMS.NotGuardian.selector, id));
        dms.extendDeadline(id, _nextValid());
        _trigger(id); // warps to the extended deadline and triggers
        vm.prank(g1);
        vm.expectRevert(_e(DMS.VaultAlreadyTriggered.selector, id));
        dms.extendDeadline(id, _nextValid());
    }

    function test_Extend_CapUnchangedAndFailedAttemptDoesNotConsumeAllowance() public {
        vm.warp(T0 + 1 days);
        vm.prank(g1);
        vm.expectRevert(_e(DMS.ExtensionTooLarge.selector, id));
        dms.extendDeadline(id, uint64(block.timestamp + INTERVAL + 1));
        uint64 currentDeadline = uint64(dms.deadline(id));
        vm.prank(g1);
        vm.expectRevert(_e(DMS.ExtensionTooLarge.selector, id));
        dms.extendDeadline(id, currentDeadline);
        assertFalse(_v(id).extensionUsed);
        _extend(id, g1, _nextValid());
        _extend(id, g2, _nextValid());
        assertTrue(_v(id).extensionUsed);
    }

    // ------------------------------------------------------------------ reset on check-in

    function test_Reset_OwnerCheckInEmitsEventAndReenablesExtension() public {
        _useExtension();
        vm.warp(T0 + 2 days);
        vm.expectEmit(true, true, false, false, address(dms));
        emit DMS.ExtensionAllowanceReset(id, owner);
        vm.expectEmit(true, true, false, true, address(dms));
        emit DMS.CheckedIn(id, owner, block.timestamp + INTERVAL);
        vm.prank(owner);
        dms.checkIn(id);
        assertFalse(_v(id).extensionUsed);

        vm.warp(T0 + 4 days);
        uint64 nd = _nextValid();
        _extend(id, g2, nd);
        _extend(id, g3, nd);
        assertTrue(_v(id).extensionUsed);
        assertEq(dms.deadline(id), nd);
    }

    function test_Reset_DelegateCheckInEmitsEvent() public {
        vm.prank(owner);
        dms.setCheckInDelegate(id, delegate);
        _useExtension();
        vm.warp(T0 + 2 days);
        vm.expectEmit(true, true, false, false, address(dms));
        emit DMS.ExtensionAllowanceReset(id, delegate);
        vm.prank(delegate);
        dms.checkIn(id);
        assertFalse(_v(id).extensionUsed);
    }

    function test_Reset_NoEventWhenUnusedAndOnlyOnceWhenUsed() public {
        vm.recordLogs();
        vm.prank(owner);
        dms.checkIn(id);
        assertEq(_countReset(vm.getRecordedLogs()), 0, "unused -> no reset event");

        _useExtension();
        vm.warp(T0 + 2 days);
        vm.recordLogs();
        vm.prank(owner);
        dms.checkIn(id);
        assertEq(_countReset(vm.getRecordedLogs()), 1);
        skip(1);
        vm.recordLogs();
        vm.prank(owner);
        dms.checkIn(id);
        assertEq(_countReset(vm.getRecordedLogs()), 0, "already reset -> no second event");
    }

    function test_Reset_OnlyOwnerOrDelegateCanReset() public {
        _useExtension();
        address[5] memory bad = [g1, g2, stranger, alice, fallbackAddr];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(bad[i]);
            vm.expectRevert(_e(DMS.NotOwnerOrDelegate.selector, id));
            dms.checkIn(id);
        }
        assertTrue(_v(id).extensionUsed);
    }

    function test_Reset_CheckInThatCancelsTriggerAlsoResets() public {
        _useExtension();
        _trigger(id);
        _assertPhase(id, DMS.Phase.Challenge);
        vm.expectEmit(true, true, false, false, address(dms));
        emit DMS.TriggerCancelled(id, owner);
        vm.expectEmit(true, true, false, false, address(dms));
        emit DMS.ExtensionAllowanceReset(id, owner);
        vm.prank(owner);
        dms.checkIn(id);
        assertFalse(_v(id).extensionUsed);
        assertFalse(_v(id).triggered);
    }

    // ------------------------------------------------------------------ rotation / rescue interplay

    function test_RotationExecutionDoesNotResetAllowance() public {
        vm.warp(T0 + 1 days);
        _proposeQuorum(id, newOwner);
        _approveRot(id, owner, newOwner); // explicit approval (a plain checkIn no longer counts)
        vm.warp(T0 + 2 days);
        uint64 nd = _nextValid();
        _extend(id, g1, nd);
        _extend(id, g2, nd);
        assertTrue(_v(id).extensionUsed);

        vm.warp(dms.getPendingRotation(id).executableAt);
        vm.recordLogs();
        vm.prank(stranger);
        dms.executeOwnerRotation(id);
        assertEq(_countReset(vm.getRecordedLogs()), 0);
        assertEq(_v(id).owner, newOwner);
        assertTrue(_v(id).extensionUsed, "rotation does not refresh the guardians' allowance");

        vm.prank(g3);
        vm.expectRevert(_e(DMS.ExtensionAlreadyUsed.selector, id));
        dms.extendDeadline(id, _nextValid());

        vm.expectEmit(true, true, false, false, address(dms));
        emit DMS.ExtensionAllowanceReset(id, newOwner);
        vm.prank(newOwner);
        dms.checkIn(id); // only a live owner's check-in resets
        assertFalse(_v(id).extensionUsed);
    }

    /// @dev REWRITTEN (was test_Rescue_OfExpiredUntriggeredVaultConsumesAllowance): guardians can no longer
    ///      rescue an expired vault; the allowance is untouched and anyone can trigger.
    function test_GuardiansCannotRescueExpiredVault_AllowanceUntouched() public {
        _toDeadline(id);
        _assertPhase(id, DMS.Phase.Expired);
        uint64 nd = _nextValid();
        vm.prank(g1);
        vm.expectRevert(_e(DMS.DeadlinePassed.selector, id));
        dms.extendDeadline(id, nd);
        assertFalse(_v(id).extensionUsed, "failed attempt does not consume the allowance");
        assertEq(dms.approvalCount(id, _extendId(nd, 0)), 0, "no vote recorded");
        _assertPhase(id, DMS.Phase.Expired);
        vm.prank(stranger);
        dms.trigger(id);
        assertTrue(_v(id).triggered);
    }

    function test_ExtensionsAreIndependentPerVault() public {
        uint256 id2 = createDefaultVault();
        _useExtension();
        assertFalse(_v(id2).extensionUsed);
        uint64 nd = _nextValid() + 1 days;
        vm.warp(block.timestamp + 1 days);
        nd = _nextValid();
        _extend(id2, g1, nd);
        _extend(id2, g2, nd);
        assertTrue(_v(id2).extensionUsed);
    }
}
