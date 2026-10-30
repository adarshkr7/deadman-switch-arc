// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DeadMansSwitchVault as DMS} from "../DeadMansSwitchVault.sol";
import {DMSTestBase} from "./DeadMansSwitchVault.Base.t.sol";

/// @dev requestWithdraw, executeWithdraw, cancelWithdraw.
contract DMSWithdrawTest is DMSTestBase {
    uint256 internal id;

    function setUp() public override {
        super.setUp();
        id = _funded(DEP);
    }

    // ------------------------------------------------------------------ requestWithdraw

    function test_RequestWithdraw_QueuesAndEmits() public {
        vm.expectEmit(true, false, false, true, address(dms));
        emit DMS.WithdrawRequested(id, 400e6, block.timestamp + WD);
        _request(id, 400e6);
        DMS.PendingWithdrawal memory pw = dms.getPendingWithdrawal(id);
        assertTrue(pw.exists);
        assertEq(pw.amount, 400e6);
        assertEq(pw.executableAt, block.timestamp + WD);
        // funds remain credited and in the contract until execution
        assertEq(_v(id).balance, DEP);
        assertEq(usdc.balanceOf(address(dms)), DEP);
    }

    function test_RequestWithdraw_FullBalanceAllowed() public {
        _request(id, DEP);
        assertEq(dms.getPendingWithdrawal(id).amount, DEP);
    }

    function test_RequestWithdraw_CustomDelayUsed() public {
        DMS.CreateParams memory p = _params();
        p.withdrawDelay = 120;
        uint256 id2 = _create(p);
        _deposit(id2, depositor, DEP);
        _request(id2, 1e6);
        assertEq(dms.getPendingWithdrawal(id2).executableAt, block.timestamp + 120);
    }

    function test_RevertRequestWithdraw_NotOwner() public {
        address[4] memory bad = [stranger, g1, alice, delegate];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(bad[i]);
            vm.expectRevert(_e(DMS.NotVaultOwner.selector, id));
            dms.requestWithdraw(id, 1e6);
        }
    }

    function test_RevertRequestWithdraw_ZeroAmount() public {
        vm.prank(owner);
        vm.expectRevert(DMS.ZeroAmount.selector);
        dms.requestWithdraw(id, 0);
    }

    function test_RevertRequestWithdraw_InsufficientVaultBalance() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(DMS.InsufficientVaultBalance.selector, DEP, DEP + 1));
        dms.requestWithdraw(id, DEP + 1);
    }

    function test_RevertRequestWithdraw_WithdrawalPending() public {
        _request(id, 1e6);
        vm.prank(owner);
        vm.expectRevert(_e(DMS.WithdrawalPending.selector, id));
        dms.requestWithdraw(id, 1e6);
    }

    function test_RevertRequestWithdraw_VaultExpiredAtDeadline() public {
        _toDeadline(id);
        vm.prank(owner);
        vm.expectRevert(_e(DMS.VaultExpired.selector, id));
        dms.requestWithdraw(id, 1e6);
    }

    function test_RequestWithdraw_OkAtDeadlineMinusOne() public {
        vm.warp(dms.deadline(id) - 1);
        _request(id, 1e6);
        assertTrue(dms.getPendingWithdrawal(id).exists);
    }

    function test_RevertRequestWithdraw_ChallengeClaimsSwept() public {
        _trigger(id);
        vm.prank(owner);
        vm.expectRevert(_e(DMS.VaultAlreadyTriggered.selector, id));
        dms.requestWithdraw(id, 1e6);
        vm.warp(_v(id).challengeEnd);
        vm.prank(owner);
        vm.expectRevert(_e(DMS.VaultAlreadyTriggered.selector, id));
        dms.requestWithdraw(id, 1e6);
        vm.warp(_v(id).sweepAt);
        dms.sweep(id);
        vm.prank(owner);
        vm.expectRevert(_e(DMS.VaultAlreadyTriggered.selector, id));
        dms.requestWithdraw(id, 1e6);
    }

    function test_RevertRequestWithdraw_VaultNotFound() public {
        vm.prank(owner);
        vm.expectRevert(_e(DMS.VaultNotFound.selector, 99));
        dms.requestWithdraw(99, 1);
    }

    // ------------------------------------------------------------------ executeWithdraw

    function test_ExecuteWithdraw_SucceedsAtExecutableAt() public {
        _request(id, 400e6);
        uint64 execAt = dms.getPendingWithdrawal(id).executableAt;
        uint256 nonceBefore = _v(id).guardianNonce;
        vm.warp(execAt);
        vm.expectEmit(true, false, false, true, address(dms));
        emit DMS.WithdrawExecuted(id, 400e6);
        vm.prank(owner);
        dms.executeWithdraw(id);
        assertEq(usdc.balanceOf(owner), 400e6);
        assertEq(usdc.balanceOf(address(dms)), DEP - 400e6);
        assertEq(_v(id).balance, DEP - 400e6);
        assertEq(dms.totalPaidOut(), 400e6);
        assertFalse(dms.getPendingWithdrawal(id).exists);
        assertEq(_v(id).guardianNonce, nonceBefore + 1);
    }

    function test_RevertExecuteWithdraw_NotReadyAtExecutableAtMinusOne() public {
        _request(id, 400e6);
        vm.warp(dms.getPendingWithdrawal(id).executableAt - 1);
        vm.prank(owner);
        vm.expectRevert(_e(DMS.WithdrawalNotReady.selector, id));
        dms.executeWithdraw(id);
    }

    function test_RevertExecuteWithdraw_NotOwner() public {
        _request(id, 1e6);
        vm.warp(block.timestamp + WD);
        address[3] memory bad = [stranger, g1, delegate];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(bad[i]);
            vm.expectRevert(_e(DMS.NotVaultOwner.selector, id));
            dms.executeWithdraw(id);
        }
    }

    function test_RevertExecuteWithdraw_NoPending() public {
        vm.prank(owner);
        vm.expectRevert(_e(DMS.NoPendingWithdrawal.selector, id));
        dms.executeWithdraw(id);
    }

    function test_RevertExecuteWithdraw_SecondExecuteHasNoPending() public {
        _request(id, 1e6);
        vm.warp(block.timestamp + WD);
        vm.startPrank(owner);
        dms.executeWithdraw(id);
        vm.expectRevert(_e(DMS.NoPendingWithdrawal.selector, id));
        dms.executeWithdraw(id);
        vm.stopPrank();
    }

    function test_RevertExecuteWithdraw_VaultExpiredMeanwhile() public {
        vm.warp(dms.deadline(id) - 1);
        _request(id, 1e6);
        vm.warp(dms.getPendingWithdrawal(id).executableAt);
        _assertPhase(id, DMS.Phase.Expired);
        vm.prank(owner);
        vm.expectRevert(_e(DMS.VaultExpired.selector, id));
        dms.executeWithdraw(id);
        assertEq(_v(id).balance, DEP);
    }

    function test_RevertExecuteWithdraw_TriggeredMeanwhileClearsRequest() public {
        vm.warp(dms.deadline(id) - 1);
        _request(id, 1e6);
        uint64 execAt = dms.getPendingWithdrawal(id).executableAt;
        vm.warp(dms.deadline(id));
        vm.expectEmit(true, true, false, false, address(dms));
        emit DMS.WithdrawCancelled(id, stranger);
        vm.prank(stranger);
        dms.trigger(id);
        vm.warp(execAt);
        vm.prank(owner);
        vm.expectRevert(_e(DMS.NoPendingWithdrawal.selector, id));
        dms.executeWithdraw(id);
    }

    function test_ExecuteWithdraw_CanRequestAgainAfter() public {
        _request(id, 100e6);
        vm.warp(block.timestamp + WD);
        vm.prank(owner);
        dms.executeWithdraw(id);
        _request(id, 200e6);
        vm.warp(block.timestamp + WD);
        vm.prank(owner);
        dms.executeWithdraw(id);
        assertEq(usdc.balanceOf(owner), 300e6);
        assertEq(_v(id).balance, DEP - 300e6);
    }

    function test_ExecuteWithdraw_FullBalanceThenEmpty() public {
        _request(id, DEP);
        vm.warp(block.timestamp + WD);
        vm.prank(owner);
        dms.executeWithdraw(id);
        assertEq(_v(id).balance, 0);
        assertEq(usdc.balanceOf(address(dms)), 0);
    }

    function test_RevertExecuteWithdraw_VaultNotFound() public {
        vm.prank(owner);
        vm.expectRevert(_e(DMS.VaultNotFound.selector, 99));
        dms.executeWithdraw(99);
    }

    // ------------------------------------------------------------------ cancelWithdraw

    function test_CancelWithdraw_OwnerCancelsInstantly() public {
        _request(id, 100e6);
        uint256 nonceBefore = _v(id).guardianNonce;
        vm.expectEmit(true, true, false, false, address(dms));
        emit DMS.WithdrawCancelled(id, owner);
        vm.prank(owner);
        dms.cancelWithdraw(id);
        assertFalse(dms.getPendingWithdrawal(id).exists);
        assertEq(_v(id).guardianNonce, nonceBefore + 1);
        assertEq(_v(id).balance, DEP);
    }

    function test_CancelWithdraw_OwnerCanCancelAfterReadyBeforeExecute() public {
        _request(id, 100e6);
        vm.warp(block.timestamp + WD + 1 hours);
        vm.prank(owner);
        dms.cancelWithdraw(id);
        assertFalse(dms.getPendingWithdrawal(id).exists);
    }

    function test_CancelWithdraw_OwnerCancelsInExpiredPhase() public {
        vm.warp(dms.deadline(id) - 1);
        _request(id, 100e6);
        vm.warp(dms.deadline(id));
        _assertPhase(id, DMS.Phase.Expired);
        vm.prank(owner);
        dms.cancelWithdraw(id);
        assertFalse(dms.getPendingWithdrawal(id).exists);
    }

    function test_CancelWithdraw_GuardianQuorumOfTwo() public {
        _request(id, 400e6);
        DMS.PendingWithdrawal memory pw = dms.getPendingWithdrawal(id);
        bytes32 aid = _cancelId(400e6, pw.executableAt, 0);

        vm.expectEmit(true, true, true, true, address(dms));
        emit DMS.GuardianApproved(id, g1, aid, 1, 2);
        vm.prank(g1);
        dms.cancelWithdraw(id);
        assertTrue(dms.getPendingWithdrawal(id).exists);
        assertEq(dms.approvalCount(id, aid), 1);
        assertTrue(dms.hasApproved(id, aid, g1));
        assertFalse(dms.hasApproved(id, aid, g2));
        assertEq(_v(id).guardianNonce, 0);

        vm.expectEmit(true, true, true, true, address(dms));
        emit DMS.GuardianApproved(id, g2, aid, 2, 2);
        vm.expectEmit(true, true, false, false, address(dms));
        emit DMS.WithdrawCancelled(id, g2);
        vm.prank(g2);
        dms.cancelWithdraw(id);
        assertFalse(dms.getPendingWithdrawal(id).exists);
        assertEq(_v(id).guardianNonce, 1);
        assertEq(_v(id).balance, DEP);
        assertEq(usdc.balanceOf(g2), 0);
    }

    function test_RevertCancelWithdraw_AlreadyApproved() public {
        _request(id, 400e6);
        DMS.PendingWithdrawal memory pw = dms.getPendingWithdrawal(id);
        bytes32 aid = _cancelId(400e6, pw.executableAt, 0);
        vm.prank(g1);
        dms.cancelWithdraw(id);
        vm.prank(g1);
        vm.expectRevert(abi.encodeWithSelector(DMS.AlreadyApproved.selector, id, aid, g1));
        dms.cancelWithdraw(id);
    }

    function test_CancelWithdraw_SingleGuardianThresholdOne() public {
        DMS.CreateParams memory p = _params();
        p.guardians = new address[](1);
        p.guardians[0] = g1;
        p.guardianThreshold = 1;
        uint256 id2 = _create(p);
        _deposit(id2, depositor, DEP);
        _request(id2, 1e6);
        vm.prank(g1);
        dms.cancelWithdraw(id2);
        assertFalse(dms.getPendingWithdrawal(id2).exists);
    }

    function test_RevertCancelWithdraw_NotOwnerOrGuardian() public {
        _request(id, 1e6);
        address[4] memory bad = [stranger, delegate, alice, fallbackAddr];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(bad[i]);
            vm.expectRevert(_e(DMS.NotOwnerOrGuardian.selector, id));
            dms.cancelWithdraw(id);
        }
    }

    function test_RevertCancelWithdraw_NoPendingForOwnerAndGuardian() public {
        vm.prank(owner);
        vm.expectRevert(_e(DMS.NoPendingWithdrawal.selector, id));
        dms.cancelWithdraw(id);
        vm.prank(g1);
        vm.expectRevert(_e(DMS.NoPendingWithdrawal.selector, id));
        dms.cancelWithdraw(id);
    }

    function test_RevertCancelWithdraw_VaultNotFound() public {
        vm.prank(owner);
        vm.expectRevert(_e(DMS.VaultNotFound.selector, 99));
        dms.cancelWithdraw(99);
    }

    function test_CancelWithdraw_CancelledAmountStaysInVault() public {
        _request(id, 100e6);
        vm.prank(owner);
        dms.cancelWithdraw(id);
        vm.warp(block.timestamp + WD);
        vm.prank(owner);
        vm.expectRevert(_e(DMS.NoPendingWithdrawal.selector, id));
        dms.executeWithdraw(id);
        assertEq(usdc.balanceOf(owner), 0);
    }
}
