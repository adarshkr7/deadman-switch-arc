// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DeadMansSwitchVault as DMS} from "../DeadMansSwitchVault.sol";
import {DMSTestBase} from "./DeadMansSwitchVault.Base.t.sol";

/// @dev SCRIPTED ATTACK: a 2-of-3 guardian quorum tries to take a LIVE vault (owner AND delegate keep making
///      routine check-ins but never approve). Without the owner's/delegate's explicit approval the rotation can
///      never execute, guardians cannot extend after expiry, and once the owner/delegate stop the funds only reach
///      the beneficiaries.
contract DMSGuardianQuorumAttackTest is DMSTestBase {
    address internal attacker = makeAddr("attackerFresh2");
    uint256 internal id;
    uint64 internal readyAt;

    function setUp() public override {
        super.setUp();
        id = _funded(DEP);
        vm.prank(owner);
        dms.setCheckInDelegate(id, delegate); // owner's only act besides creating the vault
    }

    function _broke() internal view {
        assertEq(usdc.balanceOf(attacker), 0, "attacker");
        assertEq(usdc.balanceOf(g1), 0, "g1");
        assertEq(usdc.balanceOf(g2), 0, "g2");
        assertEq(usdc.balanceOf(g3), 0, "g3");
    }

    function _execNotApproved() internal {
        address[3] memory callers = [stranger, attacker, g3];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(_e(DMS.RotationNotApproved.selector, id));
            dms.executeOwnerRotation(id);
        }
        assertEq(_v(id).owner, owner);
        assertFalse(dms.getPendingRotation(id).approved);
    }

    function _attackerCannotAct() internal {
        vm.startPrank(attacker);
        vm.expectRevert(_e(DMS.NotVaultOwner.selector, id));
        dms.requestWithdraw(id, 1);
        vm.expectRevert(_e(DMS.NotVaultOwner.selector, id));
        dms.executeWithdraw(id);
        vm.expectRevert(_e(DMS.NotVaultOwner.selector, id));
        dms.setCheckInDelegate(id, attacker);
        vm.expectRevert(_e(DMS.NotOwnerOrDelegate.selector, id));
        dms.checkIn(id);
        vm.expectRevert(_e(DMS.NotOwnerOrDelegate.selector, id));
        dms.approveOwnerRotation(id, attacker);
        vm.expectRevert(abi.encodeWithSelector(DMS.NotBeneficiary.selector, id, attacker));
        dms.claim(id);
        vm.stopPrank();
    }

    function _routineCheckIn(uint256 i) internal {
        vm.prank(i % 2 == 0 ? owner : delegate);
        dms.checkIn(id);
    }

    function test_Attack_QuorumRotationBlockedWhileOwnerAndDelegateCheckInButNeverApprove() public {
        // 1. quorum queues a rotation to a fresh attacker address
        vm.warp(T0 + 1 days);
        _propose(id, g1, attacker);
        _propose(id, g2, attacker);
        DMS.PendingRotation memory r = dms.getPendingRotation(id);
        assertTrue(r.exists);
        assertEq(r.newOwner, attacker);
        assertFalse(r.approved);
        readyAt = r.executableAt;

        // 2. routine check-ins BEFORE the timelock: owner and delegate, several times
        for (uint256 i; i < 3; ++i) {
            skip(6 hours);
            _routineCheckIn(i);
            vm.prank(stranger);
            vm.expectRevert(_e(DMS.RotationNotReady.selector, id));
            dms.executeOwnerRotation(id);
        }
        _attackerCannotAct();

        // 3. the timelock passes; check-ins continue AFTER it, execution keeps failing
        vm.warp(readyAt);
        _execNotApproved();
        for (uint256 i; i < 6; ++i) {
            skip(3 days);
            _routineCheckIn(i);
            _execNotApproved();
            _attackerCannotAct();
        }
        _broke();
        assertEq(dms.getPendingRotation(id).newOwner, attacker, "proposal is still pending, never executable");

        // 4. guardians use their single extension for this check-in period, then no more
        skip(2 days);
        uint64 nd = uint64(block.timestamp + INTERVAL);
        uint64 dlBefore = uint64(dms.deadline(id));
        _extend(id, g1, nd);
        _extend(id, g2, nd);
        assertGt(nd, dlBefore);
        assertEq(dms.deadline(id), nd);
        vm.prank(g3);
        vm.expectRevert(_e(DMS.ExtensionAlreadyUsed.selector, id));
        dms.extendDeadline(id, uint64(block.timestamp + INTERVAL));
        vm.prank(attacker);
        vm.expectRevert(_e(DMS.NotGuardian.selector, id));
        dms.extendDeadline(id, uint64(block.timestamp + INTERVAL));

        // 5. owner AND delegate go silent. Still nothing executes.
        uint256 last = _v(id).lastCheckIn;
        vm.warp(nd - 1);
        _execNotApproved();
        vm.prank(stranger);
        vm.expectRevert(_e(DMS.VaultNotExpired.selector, id));
        dms.trigger(id);
        assertLe(nd, last + 2 * uint256(INTERVAL), "deadline <= lastCheckIn + 2*interval");

        // 6. the vault expires: guardians can NOT extend any more
        vm.warp(nd);
        address[3] memory gs = [g1, g2, g3];
        for (uint256 i; i < gs.length; ++i) {
            vm.prank(gs[i]);
            vm.expectRevert(_e(DMS.DeadlinePassed.selector, id));
            dms.extendDeadline(id, uint64(block.timestamp + INTERVAL));
        }
        _execNotApproved();
        // 7. anyone (even the attacker) triggers
        vm.prank(attacker);
        dms.trigger(id);
        assertTrue(_v(id).triggered);
        vm.prank(stranger);
        vm.expectRevert(_e(DMS.VaultAlreadyTriggered.selector, id));
        dms.executeOwnerRotation(id);
        vm.prank(owner);
        vm.expectRevert(_e(DMS.VaultAlreadyTriggered.selector, id));
        dms.approveOwnerRotation(id, attacker);

        // 8. claims pay the beneficiaries everything; attacker/guardians never gain
        vm.warp(_v(id).challengeEnd);
        vm.prank(alice);
        dms.setPayoutAddress(id, payoutAddr);
        vm.prank(alice);
        dms.claim(id);
        vm.prank(bob);
        dms.claim(id);
        assertEq(usdc.balanceOf(payoutAddr), 600e6);
        assertEq(usdc.balanceOf(bob), 400e6);
        assertEq(usdc.balanceOf(address(dms)), 0);
        assertEq(dms.totalPaidOut(), DEP);
        assertEq(_v(id).owner, owner, "owner never changed");
        _broke();
        vm.warp(_v(id).sweepAt);
        vm.prank(attacker);
        dms.sweep(id);
        assertEq(usdc.balanceOf(fallbackAddr), 0);
        _broke();
    }

    function test_Attack_UnclaimedFundsGoOnlyToFallbackWhenNobodyClaims() public {
        vm.warp(T0 + 1 days);
        _proposeQuorum(id, attacker);
        _routineCheckIn(0);
        vm.warp(dms.getPendingRotation(id).executableAt + 1);
        _execNotApproved();
        // both stop; the deadline passes, guardians are powerless, the vault is triggered and swept
        vm.warp(dms.deadline(id));
        vm.prank(g1);
        vm.expectRevert(_e(DMS.DeadlinePassed.selector, id));
        dms.extendDeadline(id, uint64(block.timestamp + INTERVAL));
        vm.prank(attacker);
        dms.trigger(id);
        vm.warp(_v(id).sweepAt);
        vm.prank(attacker);
        dms.sweep(id);
        assertEq(usdc.balanceOf(fallbackAddr), DEP);
        _broke();
        assertEq(usdc.balanceOf(address(dms)), 0);
    }

    function test_Attack_ColludingGuardiansProposeRepeatedlyStillNoExecution() public {
        // after each owner veto-free period the quorum re-proposes different targets; nothing is approved
        vm.warp(T0 + 1 days);
        _proposeQuorum(id, attacker);
        vm.warp(dms.getPendingRotation(id).executableAt);
        _execNotApproved();
        // a second proposal cannot replace the pending one
        vm.prank(g3);
        vm.expectRevert(_e(DMS.RotationPending.selector, id));
        dms.proposeOwnerRotation(id, makeAddr("another"));
        // beneficiary vetoes; attackers must restart (fresh votes) and the new proposal is again unapproved
        vm.prank(alice);
        dms.cancelOwnerRotation(id);
        _proposeQuorum(id, attacker);
        assertFalse(dms.getPendingRotation(id).approved);
        vm.warp(dms.getPendingRotation(id).executableAt);
        _routineCheckIn(1);
        _execNotApproved();
        _broke();
    }
}
