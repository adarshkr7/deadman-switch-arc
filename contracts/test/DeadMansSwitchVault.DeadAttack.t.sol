// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DeadMansSwitchVault as DMS} from "../DeadMansSwitchVault.sol";
import {DMSTestBase} from "./DeadMansSwitchVault.Base.t.sol";

/// @dev Scripted exact attack: the owner NEVER acts after creation; a colluding guardian quorum
///      tries to hijack a dead owner's vault. Funds must only ever reach beneficiary payouts / fallback.
contract DMSDeadOwnerAttackTest is DMSTestBase {
    address internal attacker = makeAddr("attackerFresh");
    uint256 internal id;

    function setUp() public override {
        super.setUp();
        id = _funded(DEP); // created by `owner`, funded by a third party; owner never acts again
    }

    function _attackerAndGuardiansBroke() internal view {
        assertEq(usdc.balanceOf(attacker), 0, "attacker");
        assertEq(usdc.balanceOf(g1), 0, "g1");
        assertEq(usdc.balanceOf(g2), 0, "g2");
        assertEq(usdc.balanceOf(g3), 0, "g3");
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
        vm.expectRevert(abi.encodeWithSelector(DMS.NotBeneficiary.selector, id, attacker));
        dms.claim(id);
        vm.stopPrank();
    }

    /// @dev Phases 1-3 of the attack up to and including the trigger. Returns the trigger time.
    function _attackUntilTriggered() internal {
        vm.warp(T0 + 1 days);
        _propose(id, g1, attacker);
        _propose(id, g2, attacker); // 2-of-3 quorum
        DMS.PendingRotation memory r = dms.getPendingRotation(id);
        assertTrue(r.exists);
        assertEq(r.newOwner, attacker);

        // past the rotation timelock: anyone tries to execute -> never approved by owner/delegate
        vm.warp(uint256(r.executableAt) + 1);
        vm.prank(stranger);
        vm.expectRevert(_e(DMS.RotationNotApproved.selector, id));
        dms.executeOwnerRotation(id);
        vm.prank(g3);
        vm.expectRevert(_e(DMS.RotationNotApproved.selector, id));
        dms.executeOwnerRotation(id);
        assertEq(_v(id).owner, owner);

        _attackerCannotAct();

        // guardians extend ONCE, then every further attempt fails
        uint64 nd = uint64(block.timestamp + INTERVAL);
        _extend(id, g1, nd);
        _extend(id, g2, nd);
        assertEq(dms.deadline(id), nd);
        assertTrue(_v(id).extensionUsed);
        skip(1 days);
        uint64 nd2 = uint64(block.timestamp + INTERVAL);
        address[3] memory gs = [g1, g2, g3];
        for (uint256 i; i < gs.length; ++i) {
            vm.prank(gs[i]);
            vm.expectRevert(_e(DMS.ExtensionAlreadyUsed.selector, id));
            dms.extendDeadline(id, nd2);
        }
        assertEq(dms.deadline(id), nd, "deadline fixed at the single extension");

        // still no approval right up to the end of the extended period
        vm.warp(nd - 1);
        vm.prank(stranger);
        vm.expectRevert(_e(DMS.RotationNotApproved.selector, id));
        dms.executeOwnerRotation(id);
        vm.prank(stranger);
        vm.expectRevert(_e(DMS.VaultNotExpired.selector, id));
        dms.trigger(id);

        // the extended deadline passes; anyone triggers
        vm.warp(nd);
        vm.prank(attacker);
        dms.trigger(id);
        assertTrue(_v(id).triggered);
    }

    function test_Attack_RotationToFreshAddressThenBeneficiariesGetEverything() public {
        _attackUntilTriggered();
        // the pending rotation can never execute after trigger
        vm.prank(stranger);
        vm.expectRevert(_e(DMS.VaultAlreadyTriggered.selector, id));
        dms.executeOwnerRotation(id);
        assertEq(_v(id).owner, owner);

        // challenge window passes
        _assertPhase(id, DMS.Phase.Challenge);
        vm.warp(_v(id).challengeEnd);
        _assertPhase(id, DMS.Phase.ClaimsOpen);

        vm.prank(stranger);
        vm.expectRevert(_e(DMS.VaultAlreadyTriggered.selector, id));
        dms.executeOwnerRotation(id);

        vm.prank(alice);
        dms.setPayoutAddress(id, payoutAddr);
        vm.prank(alice);
        dms.claim(id);
        vm.prank(bob);
        dms.claim(id);

        assertEq(usdc.balanceOf(payoutAddr), 600e6, "alice's payout");
        assertEq(usdc.balanceOf(bob), 400e6);
        _attackerAndGuardiansBroke();
        assertEq(usdc.balanceOf(address(dms)), 0, "contract ends at zero");
        assertEq(dms.totalPaidOut(), DEP);
        assertEq(dms.totalDeposited(), DEP);
        assertEq(_v(id).owner, owner, "owner never changed");

        // post-claim: nothing left to take; hijack is still impossible
        vm.prank(stranger);
        vm.expectRevert(_e(DMS.VaultAlreadyTriggered.selector, id));
        dms.executeOwnerRotation(id);
        vm.warp(_v(id).sweepAt);
        vm.prank(attacker);
        dms.sweep(id); // zero remainder -> nothing moves
        assertEq(usdc.balanceOf(fallbackAddr), 0);
        _attackerAndGuardiansBroke();
    }

    function test_Attack_UnclaimedFundsSweepToFallbackOnly() public {
        _attackUntilTriggered();
        vm.warp(_v(id).sweepAt);
        vm.prank(attacker); // attacker triggers the sweep: funds still go to the fallback
        dms.sweep(id);
        assertEq(usdc.balanceOf(fallbackAddr), DEP);
        _attackerAndGuardiansBroke();
        assertEq(usdc.balanceOf(address(dms)), 0);
        assertEq(dms.totalPaidOut(), DEP);
        _assertPhase(id, DMS.Phase.Swept);
    }

    function test_Attack_SweepRoutedByFallbackOnlyToFallbackDestination() public {
        _attackUntilTriggered();
        vm.prank(attacker);
        vm.expectRevert(_e(DMS.NotFallback.selector, id));
        dms.setFallbackPayout(id, attacker);
        vm.prank(fallbackAddr);
        dms.setFallbackPayout(id, payoutAddr);
        vm.warp(_v(id).sweepAt);
        dms.sweep(id);
        assertEq(usdc.balanceOf(payoutAddr), DEP);
        _attackerAndGuardiansBroke();
    }

    function test_Attack_PayoutRedirectByNonBeneficiaryReverts() public {
        _attackUntilTriggered();
        vm.warp(_v(id).challengeEnd);
        address[4] memory bad = [attacker, g1, g2, g3];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(bad[i]);
            vm.expectRevert(abi.encodeWithSelector(DMS.NotBeneficiary.selector, id, bad[i]));
            dms.setPayoutAddress(id, bad[i]);
        }
        vm.prank(alice);
        dms.claim(id);
        vm.prank(bob);
        dms.claim(id);
        assertEq(usdc.balanceOf(alice), 600e6);
        assertEq(usdc.balanceOf(bob), 400e6);
        _attackerAndGuardiansBroke();
    }

    // ------------------------------------------------------------------ variant: execution attempts after trigger

    function test_Variant_RotationExecutionAfterTriggerRevertsInEveryLaterPhase() public {
        // quorum formed just before the deadline so the timelock outlives the trigger
        vm.warp(dms.deadline(id) - 1 hours);
        _proposeQuorum(id, attacker);
        uint64 ready = dms.getPendingRotation(id).executableAt;
        _trigger(id);
        address[4] memory callers = [g1, g2, attacker, stranger];

        vm.warp(ready);
        _assertPhase(id, DMS.Phase.ClaimsOpen);
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(_e(DMS.VaultAlreadyTriggered.selector, id));
            dms.executeOwnerRotation(id);
        }
        // proposing anew after trigger is rejected too
        vm.prank(g3);
        vm.expectRevert(_e(DMS.VaultAlreadyTriggered.selector, id));
        dms.proposeOwnerRotation(id, makeAddr("another"));

        vm.warp(_v(id).sweepAt);
        dms.sweep(id);
        vm.prank(attacker);
        vm.expectRevert(_e(DMS.VaultAlreadyTriggered.selector, id));
        dms.executeOwnerRotation(id);
        assertEq(_v(id).owner, owner);
        assertEq(usdc.balanceOf(fallbackAddr), DEP);
        _attackerAndGuardiansBroke();
    }

    function test_Variant_RotationFirstAfterTriggerWindowCheckInByNobody() public {
        // quorum is formed while the vault is Expired-untriggered; neither owner nor delegate can check in
        _toDeadline(id);
        _proposeQuorum(id, attacker);
        vm.warp(dms.getPendingRotation(id).executableAt + 1);
        vm.prank(attacker);
        vm.expectRevert(_e(DMS.RotationNotApproved.selector, id));
        dms.executeOwnerRotation(id);
        _trigger(id);
        vm.prank(attacker);
        vm.expectRevert(_e(DMS.VaultAlreadyTriggered.selector, id));
        dms.executeOwnerRotation(id);
        vm.warp(_v(id).challengeEnd);
        vm.prank(alice);
        dms.claim(id);
        vm.prank(bob);
        dms.claim(id);
        assertEq(usdc.balanceOf(alice) + usdc.balanceOf(bob), DEP);
        _attackerAndGuardiansBroke();
    }
}
