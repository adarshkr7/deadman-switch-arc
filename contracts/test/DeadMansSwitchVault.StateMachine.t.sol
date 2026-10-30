// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DeadMansSwitchVault as DMS} from "../DeadMansSwitchVault.sol";
import {DMSTestBase} from "./DeadMansSwitchVault.Base.t.sol";

/// @dev Phase machine, trigger/cancel flows, role boundaries, cross-feature interplay.
contract DMSStateMachineTest is DMSTestBase {
    uint256 internal id;

    function setUp() public override {
        super.setUp();
        id = _funded(DEP);
        vm.prank(owner);
        dms.setCheckInDelegate(id, delegate);
    }

    // ------------------------------------------------------------------ lifecycle

    function test_Lifecycle_PhaseAtEachBoundarySecond() public {
        uint256 dl = dms.deadline(id);
        _assertPhase(id, DMS.Phase.Active);
        assertFalse(dms.isExpired(id));
        vm.warp(dl - 1);
        _assertPhase(id, DMS.Phase.Active);
        assertFalse(dms.isExpired(id));
        vm.warp(dl);
        _assertPhase(id, DMS.Phase.Expired);
        assertTrue(dms.isExpired(id));
        vm.warp(dl + 100);
        _assertPhase(id, DMS.Phase.Expired);

        uint256 t = block.timestamp;
        dms.trigger(id);
        DMS.VaultView memory v = _v(id);
        assertEq(v.triggeredAt, t);
        assertEq(v.challengeEnd, t + CW);
        assertEq(v.sweepAt, t + CW + SP);
        _assertPhase(id, DMS.Phase.Challenge);
        vm.warp(v.challengeEnd - 1);
        _assertPhase(id, DMS.Phase.Challenge);
        vm.warp(v.challengeEnd);
        _assertPhase(id, DMS.Phase.ClaimsOpen);
        vm.warp(v.sweepAt - 1);
        _assertPhase(id, DMS.Phase.ClaimsOpen);
        vm.warp(v.sweepAt);
        _assertPhase(id, DMS.Phase.ClaimsOpen); // stays ClaimsOpen until sweep executes
        dms.sweep(id);
        _assertPhase(id, DMS.Phase.Swept);
        vm.warp(block.timestamp + 1000 days);
        _assertPhase(id, DMS.Phase.Swept);
    }

    function test_Lifecycle_ExpiredAndChallengeShareTheSecondOfTrigger() public {
        vm.warp(dms.deadline(id));
        _assertPhase(id, DMS.Phase.Expired);
        dms.trigger(id);
        _assertPhase(id, DMS.Phase.Challenge);
    }

    function test_Lifecycle_ConservationAcrossWithdrawClaimSweep() public {
        _request(id, 300e6);
        vm.warp(block.timestamp + WD);
        vm.prank(owner);
        dms.executeWithdraw(id);
        _deposit(id, stranger, 50e6);
        _toClaims(id);
        vm.prank(bob);
        dms.claim(id);
        vm.warp(_v(id).sweepAt);
        dms.sweep(id);
        uint256 total = DEP + 50e6;
        assertEq(usdc.balanceOf(owner) + usdc.balanceOf(bob) + usdc.balanceOf(fallbackAddr), total);
        assertEq(usdc.balanceOf(address(dms)), 0);
        assertEq(dms.totalPaidOut(), dms.totalDeposited());
        // alice never claimed -> her share went to fallback
        assertEq(usdc.balanceOf(bob), ((total - 300e6) * 4000) / 10_000);
    }

    // ------------------------------------------------------------------ trigger / cancel

    function test_OwnerCheckInDuringChallengeCancelsTrigger() public {
        _trigger(id);
        vm.warp(block.timestamp + 3 hours);
        uint256 newDl = block.timestamp + INTERVAL;
        vm.expectEmit(true, true, false, false, address(dms));
        emit DMS.TriggerCancelled(id, owner);
        vm.expectEmit(true, true, false, true, address(dms));
        emit DMS.CheckedIn(id, owner, newDl);
        vm.prank(owner);
        dms.checkIn(id);
        DMS.VaultView memory v = _v(id);
        assertFalse(v.triggered);
        assertEq(v.triggeredAt, 0);
        assertEq(v.challengeEnd, 0);
        assertEq(v.sweepAt, 0);
        assertEq(v.lastCheckIn, block.timestamp);
        assertEq(v.deadline, newDl);
        assertEq(v.balance, DEP);
        _assertPhase(id, DMS.Phase.Active);
    }

    function test_DelegateCheckInDuringChallengeCancelsTrigger() public {
        _trigger(id);
        vm.expectEmit(true, true, false, false, address(dms));
        emit DMS.TriggerCancelled(id, delegate);
        vm.prank(delegate);
        dms.checkIn(id);
        assertFalse(_v(id).triggered);
        _assertPhase(id, DMS.Phase.Active);
    }

    function test_RetriggerAfterCancelUsesFreshTiming() public {
        _trigger(id);
        vm.prank(owner);
        dms.checkIn(id);
        uint256 dl2 = dms.deadline(id);
        vm.warp(dl2 - 1);
        vm.expectRevert(_e(DMS.VaultNotExpired.selector, id));
        dms.trigger(id);
        vm.warp(dl2 + 10);
        dms.trigger(id);
        DMS.VaultView memory v = _v(id);
        assertEq(v.triggeredAt, dl2 + 10);
        assertEq(v.challengeEnd, dl2 + 10 + CW);
        assertEq(v.sweepAt, dl2 + 10 + CW + SP);
        // deposits made while cancelled/retriggered are all in the pool
        _deposit(id, stranger, 5e6);
        vm.warp(v.challengeEnd);
        dms.finalize(id);
        assertEq(_v(id).claimPool, DEP + 5e6);
    }

    function test_CancelledTriggerAllowsWithdrawalsAgain() public {
        _trigger(id);
        vm.prank(owner);
        dms.checkIn(id);
        _request(id, 10e6);
        vm.warp(block.timestamp + WD);
        vm.prank(owner);
        dms.executeWithdraw(id);
        assertEq(usdc.balanceOf(owner), 10e6);
    }

    // ------------------------------------------------------------------ delegate boundaries

    function test_DelegateCanOnlyCheckIn() public {
        _request(id, 1e6);
        vm.startPrank(delegate);
        vm.expectRevert(_e(DMS.NotVaultOwner.selector, id));
        dms.requestWithdraw(id, 1e6);
        vm.expectRevert(_e(DMS.NotVaultOwner.selector, id));
        dms.executeWithdraw(id);
        vm.expectRevert(_e(DMS.NotOwnerOrGuardian.selector, id));
        dms.cancelWithdraw(id);
        vm.expectRevert(_e(DMS.NotVaultOwner.selector, id));
        dms.setCheckInDelegate(id, stranger);
        // delegate may now veto rotations (cancelOwnerRotation): with none pending -> NoPendingRotation
        vm.expectRevert(_e(DMS.NoPendingRotation.selector, id));
        dms.cancelOwnerRotation(id);
        vm.expectRevert(_e(DMS.NotGuardian.selector, id));
        dms.extendDeadline(id, uint64(block.timestamp + 1));
        vm.expectRevert(_e(DMS.NotGuardian.selector, id));
        dms.proposeOwnerRotation(id, newOwner);
        vm.expectRevert(abi.encodeWithSelector(DMS.NotBeneficiary.selector, id, delegate));
        dms.claim(id);
        vm.expectRevert(abi.encodeWithSelector(DMS.NotBeneficiary.selector, id, delegate));
        dms.setPayoutAddress(id, payoutAddr);
        vm.expectRevert(_e(DMS.NotFallback.selector, id));
        dms.setFallbackPayout(id, payoutAddr);
        dms.checkIn(id); // the one thing it can do
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ deposits per phase

    function test_DepositsAllowedUntilClaimsOpenThenBlocked() public {
        _deposit(id, stranger, 1e6); // Active
        _toDeadline(id);
        _deposit(id, stranger, 1e6); // Expired
        vm.prank(stranger);
        dms.trigger(id);
        _deposit(id, stranger, 1e6); // Challenge
        vm.warp(_v(id).challengeEnd - 1);
        _deposit(id, stranger, 1e6); // last second of Challenge
        vm.warp(_v(id).challengeEnd);
        usdc.mint(stranger, 1e6);
        vm.startPrank(stranger);
        usdc.approve(address(dms), 1e6);
        vm.expectRevert(_e(DMS.DepositsClosed.selector, id));
        dms.deposit(id, 1e6); // ClaimsOpen
        vm.stopPrank();
        assertEq(_v(id).balance, DEP + 4e6);
    }

    // ------------------------------------------------------------------ guardians have no unilateral power

    function test_GuardiansCannotTriggerEarlyOrCheckIn() public {
        address[3] memory gs = [g1, g2, g3];
        for (uint256 i; i < 3; ++i) {
            vm.prank(gs[i]);
            vm.expectRevert(_e(DMS.VaultNotExpired.selector, id));
            dms.trigger(id);
            vm.prank(gs[i]);
            vm.expectRevert(_e(DMS.NotOwnerOrDelegate.selector, id));
            dms.checkIn(id);
        }
        assertFalse(_v(id).triggered);
    }

    function test_GuardiansCannotShortenDeadlineEvenUnanimously() public {
        vm.warp(T0 + 1 days);
        uint64 shorter = uint64(block.timestamp + 1 hours);
        address[3] memory gs = [g1, g2, g3];
        for (uint256 i; i < 3; ++i) {
            vm.prank(gs[i]);
            vm.expectRevert(_e(DMS.ExtensionTooLarge.selector, id));
            dms.extendDeadline(id, shorter);
        }
        assertEq(dms.deadline(id), T0 + INTERVAL);
    }

    function test_GuardiansCannotMoveFunds() public {
        _request(id, 100e6);
        vm.warp(T0 + 1 days);
        uint64 nd = uint64(block.timestamp + INTERVAL);
        _extend(id, g1, nd);
        _extend(id, g2, nd);
        vm.prank(g1);
        dms.cancelWithdraw(id);
        vm.prank(g2);
        dms.cancelWithdraw(id);
        _proposeQuorum(id, newOwner);
        assertEq(usdc.balanceOf(address(dms)), DEP);
        assertEq(usdc.balanceOf(g1) + usdc.balanceOf(g2) + usdc.balanceOf(g3), 0);
        assertEq(dms.totalPaidOut(), 0);
    }

    // ------------------------------------------------------------------ rotation x withdrawal x votes

    function test_RotationCancelsPendingWithdrawalAndNewOwnerGetsFunds() public {
        _request(id, 100e6);
        _rotate(id, newOwner);
        assertFalse(dms.getPendingWithdrawal(id).exists);
        vm.warp(block.timestamp + WD);
        vm.prank(owner);
        vm.expectRevert(_e(DMS.NotVaultOwner.selector, id));
        dms.executeWithdraw(id);
        vm.prank(newOwner);
        vm.expectRevert(_e(DMS.NoPendingWithdrawal.selector, id));
        dms.executeWithdraw(id);
        vm.prank(newOwner);
        dms.requestWithdraw(id, 100e6);
        vm.warp(block.timestamp + WD);
        vm.prank(newOwner);
        dms.executeWithdraw(id);
        assertEq(usdc.balanceOf(newOwner), 100e6);
        assertEq(usdc.balanceOf(owner), 0);
    }

    function test_StaleExtendVotesDieAfterRotation() public {
        vm.warp(T0 + 1 days);
        uint64 nd = uint64(block.timestamp + INTERVAL);
        _extend(id, g1, nd);
        _rotate(id, newOwner); // moves time forward 48h, owner explicitly approves (deadline untouched), bumps nonce
        uint256 dlAfterRotation = dms.deadline(id);
        uint64 nd2 = uint64(block.timestamp + INTERVAL);
        _extend(id, g2, nd2);
        assertEq(dms.deadline(id), dlAfterRotation, "no quorum after nonce change");
        _extend(id, g3, nd2);
        assertEq(dms.deadline(id), nd2);
    }

    function test_StaleCancelVotesDieAfterOwnerExecutesWithdraw() public {
        _request(id, 10e6);
        vm.prank(g1);
        dms.cancelWithdraw(id); // 1 of 2
        vm.warp(block.timestamp + WD);
        vm.prank(owner);
        dms.executeWithdraw(id);
        _request(id, 10e6); // new request, new nonce, new action id
        vm.prank(g2);
        dms.cancelWithdraw(id); // only 1 vote under the new action id
        assertTrue(dms.getPendingWithdrawal(id).exists);
    }

    function test_StaleRotationVotesDieAfterTrigger() public {
        _propose(id, g1, newOwner);
        _trigger(id); // bumps nonce
        // triggered -> cannot continue anyway
        vm.prank(g2);
        vm.expectRevert(_e(DMS.VaultAlreadyTriggered.selector, id));
        dms.proposeOwnerRotation(id, newOwner);
        vm.prank(owner);
        dms.checkIn(id); // cancel trigger
        _propose(id, g2, newOwner); // different nonce: 1 vote, not 2
        assertFalse(dms.getPendingRotation(id).exists);
    }
}
