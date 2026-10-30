// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DeadMansSwitchVault as DMS} from "../DeadMansSwitchVault.sol";
import {DMSTestBase} from "./DeadMansSwitchVault.Base.t.sol";

/// @dev proposeOwnerRotation, executeOwnerRotation, cancelOwnerRotation.
contract DMSRotationTest is DMSTestBase {
    uint256 internal id;

    function setUp() public override {
        super.setUp();
        id = _funded(DEP);
    }

    // ------------------------------------------------------------------ propose

    function test_Propose_FirstVoteOnlyRecords() public {
        bytes32 aid = _rotId(newOwner, 0);
        vm.expectEmit(true, true, true, true, address(dms));
        emit DMS.GuardianApproved(id, g1, aid, 1, 2);
        _propose(id, g1, newOwner);
        assertFalse(dms.getPendingRotation(id).exists);
        assertEq(dms.approvalCount(id, aid), 1);
    }

    function test_Propose_QuorumQueuesRotation() public {
        bytes32 aid = _rotId(newOwner, 0);
        _propose(id, g1, newOwner);
        vm.expectEmit(true, true, true, true, address(dms));
        emit DMS.GuardianApproved(id, g2, aid, 2, 2);
        vm.expectEmit(true, true, false, true, address(dms));
        emit DMS.OwnerRotationProposed(id, newOwner, block.timestamp + RT);
        _propose(id, g2, newOwner);
        DMS.PendingRotation memory r = dms.getPendingRotation(id);
        assertTrue(r.exists);
        assertEq(r.newOwner, newOwner);
        assertEq(r.executableAt, block.timestamp + RT);
        assertEq(_v(id).owner, owner, "owner unchanged until execution");
        assertEq(_v(id).guardianNonce, 1);
    }

    function test_RevertPropose_NotGuardian() public {
        address[3] memory bad = [stranger, owner, delegate];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(bad[i]);
            vm.expectRevert(_e(DMS.NotGuardian.selector, id));
            dms.proposeOwnerRotation(id, newOwner);
        }
    }

    function test_RevertPropose_InvalidNewOwner() public {
        vm.prank(g1);
        vm.expectRevert(DMS.InvalidNewOwner.selector);
        dms.proposeOwnerRotation(id, address(0));
        vm.prank(g1);
        vm.expectRevert(DMS.InvalidNewOwner.selector);
        dms.proposeOwnerRotation(id, address(dms));
        vm.prank(g1);
        vm.expectRevert(DMS.InvalidNewOwner.selector);
        dms.proposeOwnerRotation(id, owner);
    }

    function test_RevertPropose_Triggered() public {
        _trigger(id);
        vm.prank(g1);
        vm.expectRevert(_e(DMS.VaultAlreadyTriggered.selector, id));
        dms.proposeOwnerRotation(id, newOwner);
    }

    function test_RevertPropose_RotationPending() public {
        _proposeQuorum(id, newOwner);
        vm.prank(g3);
        vm.expectRevert(_e(DMS.RotationPending.selector, id));
        dms.proposeOwnerRotation(id, stranger);
        vm.prank(g1);
        vm.expectRevert(_e(DMS.RotationPending.selector, id));
        dms.proposeOwnerRotation(id, newOwner);
    }

    function test_RevertPropose_AlreadyApproved() public {
        bytes32 aid = _rotId(newOwner, 0);
        _propose(id, g1, newOwner);
        vm.prank(g1);
        vm.expectRevert(abi.encodeWithSelector(DMS.AlreadyApproved.selector, id, aid, g1));
        dms.proposeOwnerRotation(id, newOwner);
    }

    function test_RevertPropose_VaultNotFound() public {
        vm.prank(g1);
        vm.expectRevert(_e(DMS.VaultNotFound.selector, 99));
        dms.proposeOwnerRotation(99, newOwner);
    }

    function test_Propose_AllowedWhenExpiredUntriggered() public {
        _toDeadline(id);
        _proposeQuorum(id, newOwner);
        assertTrue(dms.getPendingRotation(id).exists);
    }

    // ------------------------------------------------------------------ execute

    function test_RevertExecute_NoPendingRotation() public {
        vm.expectRevert(_e(DMS.NoPendingRotation.selector, id));
        dms.executeOwnerRotation(id);
    }

    function test_RevertExecute_NotReadyAtExecutableAtMinusOne() public {
        _proposeQuorum(id, newOwner);
        vm.warp(dms.getPendingRotation(id).executableAt - 1);
        vm.expectRevert(_e(DMS.RotationNotReady.selector, id));
        dms.executeOwnerRotation(id);
    }

    function test_Execute_AnyoneAtExecutableAtRotatesOwner() public {
        _proposeQuorum(id, newOwner);
        _approveRot(id, owner, newOwner); // explicit approval (a plain checkIn no longer counts)
        vm.warp(dms.getPendingRotation(id).executableAt);
        vm.expectEmit(true, true, true, false, address(dms));
        emit DMS.OwnerRotated(id, owner, newOwner);
        vm.prank(stranger);
        dms.executeOwnerRotation(id);
        assertEq(_v(id).owner, newOwner);
        assertFalse(dms.getPendingRotation(id).exists);
    }

    function test_Execute_ClearsDelegateAndPendingWithdrawalAndBumpsNonce() public {
        vm.prank(owner);
        dms.setCheckInDelegate(id, delegate);
        _request(id, 100e6);
        _proposeQuorum(id, newOwner);
        _approveRot(id, owner, newOwner); // explicit approval (a plain checkIn no longer counts)
        vm.warp(dms.getPendingRotation(id).executableAt);
        uint256 nonceBefore = _v(id).guardianNonce;

        vm.expectEmit(true, false, false, true, address(dms));
        emit DMS.CheckInDelegateSet(id, address(0));
        vm.expectEmit(true, true, false, false, address(dms));
        emit DMS.WithdrawCancelled(id, stranger);
        vm.expectEmit(true, true, true, false, address(dms));
        emit DMS.OwnerRotated(id, owner, newOwner);
        vm.prank(stranger);
        dms.executeOwnerRotation(id);

        DMS.VaultView memory v = _v(id);
        assertEq(v.checkInDelegate, address(0));
        assertFalse(dms.getPendingWithdrawal(id).exists);
        assertEq(v.guardianNonce, nonceBefore + 1);
        assertEq(v.balance, DEP, "rotation moves no funds");
    }

    function test_Execute_OldOwnerLosesRightsNewOwnerGains() public {
        vm.prank(owner);
        dms.setCheckInDelegate(id, delegate);
        _rotate(id, newOwner);

        vm.prank(owner);
        vm.expectRevert(_e(DMS.NotOwnerOrDelegate.selector, id));
        dms.checkIn(id);
        vm.prank(owner);
        vm.expectRevert(_e(DMS.NotVaultOwner.selector, id));
        dms.requestWithdraw(id, 1e6);
        vm.prank(owner);
        vm.expectRevert(_e(DMS.NotVaultOwner.selector, id));
        dms.setCheckInDelegate(id, delegate);
        vm.prank(delegate);
        vm.expectRevert(_e(DMS.NotOwnerOrDelegate.selector, id));
        dms.checkIn(id);

        vm.startPrank(newOwner);
        dms.checkIn(id);
        dms.setCheckInDelegate(id, delegate);
        dms.requestWithdraw(id, 50e6);
        vm.stopPrank();
        vm.warp(block.timestamp + WD);
        vm.prank(newOwner);
        dms.executeWithdraw(id);
        assertEq(usdc.balanceOf(newOwner), 50e6);
        assertEq(usdc.balanceOf(owner), 0);
    }

    function test_RevertExecute_BlockedWhenTriggeredInChallenge() public {
        DMS.CreateParams memory p = _params();
        p.rotationTimelock = 60;
        uint256 id2 = _create(p);
        uint256 dl = dms.deadline(id2);
        vm.warp(dl - 30);
        _propose(id2, g1, newOwner);
        _propose(id2, g2, newOwner);
        vm.warp(dl);
        vm.prank(stranger);
        dms.trigger(id2);
        vm.warp(dl + 30); // == executableAt, still Challenge
        _assertPhase(id2, DMS.Phase.Challenge);
        vm.expectRevert(_e(DMS.VaultAlreadyTriggered.selector, id2));
        dms.executeOwnerRotation(id2);
    }

    function test_RevertExecute_BlockedWhenTriggeredClaimsOpen() public {
        vm.warp(dms.deadline(id) - 1 hours);
        _proposeQuorum(id, newOwner);
        uint64 execAt = dms.getPendingRotation(id).executableAt;
        _trigger(id);
        vm.warp(execAt);
        vm.expectRevert(_e(DMS.VaultAlreadyTriggered.selector, id));
        dms.executeOwnerRotation(id);
        assertEq(_v(id).owner, owner);
    }

    function test_RevertExecute_VaultNotFound() public {
        vm.expectRevert(_e(DMS.VaultNotFound.selector, 99));
        dms.executeOwnerRotation(99);
    }

    function test_Execute_SecondExecuteReverts() public {
        _rotate(id, newOwner);
        vm.expectRevert(_e(DMS.NoPendingRotation.selector, id));
        dms.executeOwnerRotation(id);
    }

    // ------------------------------------------------------------------ cancel

    function test_CancelRotation_OwnerVetoes() public {
        _proposeQuorum(id, newOwner);
        uint256 nonceBefore = _v(id).guardianNonce;
        vm.expectEmit(true, true, false, false, address(dms));
        emit DMS.OwnerRotationCancelled(id, owner);
        vm.prank(owner);
        dms.cancelOwnerRotation(id);
        assertFalse(dms.getPendingRotation(id).exists);
        assertEq(_v(id).guardianNonce, nonceBefore + 1);
        vm.warp(block.timestamp + RT);
        vm.expectRevert(_e(DMS.NoPendingRotation.selector, id));
        dms.executeOwnerRotation(id);
    }

    function test_CancelRotation_WorksAfterTimelockBeforeExecution() public {
        _proposeQuorum(id, newOwner);
        vm.warp(dms.getPendingRotation(id).executableAt + 1 days);
        vm.prank(owner);
        dms.cancelOwnerRotation(id);
        assertEq(_v(id).owner, owner);
    }

    function test_CancelRotation_OldVotesStaleSoReproposeNeedsFreshQuorum() public {
        _proposeQuorum(id, newOwner);
        vm.prank(owner);
        dms.cancelOwnerRotation(id);
        // nonce changed: g1 can vote again for the same newOwner and it is only vote 1 of 2
        _propose(id, g1, newOwner);
        assertFalse(dms.getPendingRotation(id).exists);
        assertEq(dms.approvalCount(id, _rotId(newOwner, 2)), 1);
        _propose(id, g2, newOwner);
        assertTrue(dms.getPendingRotation(id).exists);
    }

    function test_RevertCancelRotation_NotOwner() public {
        _proposeQuorum(id, newOwner);
        address[4] memory bad = [g1, stranger, delegate, newOwner]; // delegate is NOT set here
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(bad[i]);
            vm.expectRevert(_e(DMS.NotOwnerDelegateOrBeneficiary.selector, id));
            dms.cancelOwnerRotation(id);
        }
    }

    function test_RevertCancelRotation_NoPending() public {
        vm.prank(owner);
        vm.expectRevert(_e(DMS.NoPendingRotation.selector, id));
        dms.cancelOwnerRotation(id);
    }

    function test_RevertCancelRotation_VaultNotFound() public {
        vm.prank(owner);
        vm.expectRevert(_e(DMS.VaultNotFound.selector, 99));
        dms.cancelOwnerRotation(99);
    }
}
