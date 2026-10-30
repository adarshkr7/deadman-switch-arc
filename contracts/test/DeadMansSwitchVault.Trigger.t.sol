// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DeadMansSwitchVault as DMS} from "../DeadMansSwitchVault.sol";
import {DMSTestBase} from "./DeadMansSwitchVault.Base.t.sol";

/// @dev trigger and finalize.
contract DMSTriggerTest is DMSTestBase {
    uint256 internal id;

    function setUp() public override {
        super.setUp();
        id = _funded(DEP);
    }

    // ------------------------------------------------------------------ trigger

    function test_RevertTrigger_NotExpiredAtDeadlineMinusOne() public {
        vm.warp(dms.deadline(id) - 1);
        _assertPhase(id, DMS.Phase.Active);
        vm.expectRevert(_e(DMS.VaultNotExpired.selector, id));
        dms.trigger(id);
    }

    function test_Trigger_AtDeadlineSetsTimingAndEmits() public {
        uint256 dl = dms.deadline(id);
        vm.warp(dl);
        vm.expectEmit(true, true, false, true, address(dms));
        emit DMS.Triggered(id, stranger, dl + CW, dl + CW + SP);
        vm.prank(stranger);
        dms.trigger(id);
        DMS.VaultView memory v = _v(id);
        assertTrue(v.triggered);
        assertEq(v.triggeredAt, dl);
        assertEq(v.challengeEnd, dl + CW);
        assertEq(v.sweepAt, dl + CW + SP);
        assertFalse(v.finalized, "pool is not snapshotted at trigger");
        assertEq(v.claimPool, 0);
        assertEq(v.balance, DEP);
        _assertPhase(id, DMS.Phase.Challenge);
    }

    function test_Trigger_LateTriggerAnchorsTimesToActualTime() public {
        uint256 dl = dms.deadline(id);
        vm.warp(dl + 5 days);
        dms.trigger(id);
        DMS.VaultView memory v = _v(id);
        assertEq(v.triggeredAt, dl + 5 days);
        assertEq(v.challengeEnd, dl + 5 days + CW);
        assertEq(v.sweepAt, dl + 5 days + CW + SP);
    }

    function test_Trigger_UsesCustomDelays() public {
        DMS.CreateParams memory p = _params();
        p.challengeWindow = 100;
        p.sweepPeriod = 700;
        uint256 id2 = _create(p);
        uint256 dl = dms.deadline(id2);
        vm.warp(dl);
        dms.trigger(id2);
        assertEq(_v(id2).challengeEnd, dl + 100);
        assertEq(_v(id2).sweepAt, dl + 800);
    }

    function test_Trigger_AnyoneCanCall() public {
        address[5] memory callers = [stranger, owner, g1, alice, fallbackAddr];
        for (uint256 i; i < callers.length; ++i) {
            uint256 vid = createDefaultVault();
            vm.warp(dms.deadline(vid));
            vm.prank(callers[i]);
            dms.trigger(vid);
            assertTrue(_v(vid).triggered);
        }
    }

    function test_RevertTrigger_AlreadyTriggered() public {
        _trigger(id);
        vm.expectRevert(_e(DMS.VaultAlreadyTriggered.selector, id));
        dms.trigger(id);
        vm.warp(block.timestamp + 5 days);
        vm.expectRevert(_e(DMS.VaultAlreadyTriggered.selector, id));
        dms.trigger(id);
    }

    function test_Trigger_ClearsPendingWithdrawalAndBumpsNonce() public {
        vm.warp(dms.deadline(id) - 1);
        _request(id, 100e6);
        vm.warp(dms.deadline(id));
        uint256 nonceBefore = _v(id).guardianNonce;
        vm.expectEmit(true, true, false, false, address(dms));
        emit DMS.WithdrawCancelled(id, stranger);
        vm.prank(stranger);
        dms.trigger(id);
        assertFalse(dms.getPendingWithdrawal(id).exists);
        assertEq(_v(id).guardianNonce, nonceBefore + 1);
        assertEq(_v(id).balance, DEP);
    }

    function test_Trigger_WithoutPendingWithdrawalStillBumpsNonce() public {
        _trigger(id);
        assertEq(_v(id).guardianNonce, 1);
    }

    function test_Trigger_MovesNoFunds() public {
        _trigger(id);
        assertEq(usdc.balanceOf(address(dms)), DEP);
        assertEq(dms.totalPaidOut(), 0);
    }

    function test_RevertTrigger_VaultNotFound() public {
        vm.expectRevert(_e(DMS.VaultNotFound.selector, 99));
        dms.trigger(99);
    }

    function test_RevertTrigger_TimestampOverflow() public {
        DMS.CreateParams memory p = _params();
        p.interval = 60;
        uint256 id2 = _create(p);
        vm.warp(uint256(type(uint64).max) - (uint256(CW) + SP) + 1);
        vm.expectRevert(DMS.TimestampOverflow.selector);
        dms.trigger(id2);
    }

    function test_Trigger_TimestampBoundaryOk() public {
        DMS.CreateParams memory p = _params();
        p.interval = 60;
        uint256 id2 = _create(p);
        vm.warp(uint256(type(uint64).max) - (uint256(CW) + SP));
        dms.trigger(id2);
        assertEq(_v(id2).sweepAt, type(uint64).max);
    }

    // ------------------------------------------------------------------ finalize

    function test_RevertFinalize_NotTriggered() public {
        vm.expectRevert(_e(DMS.NotTriggered.selector, id));
        dms.finalize(id);
        _toDeadline(id);
        vm.expectRevert(_e(DMS.NotTriggered.selector, id));
        dms.finalize(id);
    }

    function test_RevertFinalize_ChallengeNotOverAtChallengeEndMinusOne() public {
        _trigger(id);
        vm.warp(_v(id).challengeEnd - 1);
        vm.expectRevert(_e(DMS.ChallengeNotOver.selector, id));
        dms.finalize(id);
    }

    function test_Finalize_AtChallengeEndSetsPool() public {
        _trigger(id);
        vm.warp(_v(id).challengeEnd);
        vm.expectEmit(true, false, false, true, address(dms));
        emit DMS.Finalized(id, DEP);
        vm.prank(stranger);
        dms.finalize(id);
        DMS.VaultView memory v = _v(id);
        assertTrue(v.finalized);
        assertEq(v.claimPool, DEP);
        assertEq(v.balance, 0);
        assertEq(usdc.balanceOf(address(dms)), DEP);
        _assertPhase(id, DMS.Phase.ClaimsOpen);
    }

    function test_Finalize_PoolIncludesChallengePhaseDeposits() public {
        _trigger(id);
        _deposit(id, depositor, 250e6);
        vm.warp(_v(id).challengeEnd);
        dms.finalize(id);
        assertEq(_v(id).claimPool, DEP + 250e6);
    }

    function test_Finalize_ZeroPoolOk() public {
        uint256 id2 = createDefaultVault();
        _toClaims(id2);
        vm.expectEmit(true, false, false, true, address(dms));
        emit DMS.Finalized(id2, 0);
        dms.finalize(id2);
        assertTrue(_v(id2).finalized);
    }

    function test_RevertFinalize_AlreadyFinalized() public {
        _toClaims(id);
        dms.finalize(id);
        vm.expectRevert(_e(DMS.AlreadyFinalized.selector, id));
        dms.finalize(id);
    }

    function test_RevertFinalize_AlreadyFinalizedByClaim() public {
        _toClaims(id);
        vm.prank(alice);
        dms.claim(id);
        vm.expectRevert(_e(DMS.AlreadyFinalized.selector, id));
        dms.finalize(id);
    }

    function test_RevertFinalize_AfterSweepIsNotTriggered() public {
        _toSweepTime(id);
        dms.sweep(id);
        vm.expectRevert(_e(DMS.NotTriggered.selector, id));
        dms.finalize(id);
    }

    function test_RevertFinalize_AfterTriggerCancelled() public {
        _trigger(id);
        vm.prank(owner);
        dms.checkIn(id);
        vm.expectRevert(_e(DMS.NotTriggered.selector, id));
        dms.finalize(id);
    }

    function test_RevertFinalize_VaultNotFound() public {
        vm.expectRevert(_e(DMS.VaultNotFound.selector, 99));
        dms.finalize(99);
    }
}
