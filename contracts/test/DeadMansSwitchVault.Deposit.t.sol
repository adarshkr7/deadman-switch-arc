// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeadMansSwitchVault as DMS} from "../DeadMansSwitchVault.sol";
import {DMSTestBase} from "./DeadMansSwitchVault.Base.t.sol";
import {MockNoopToken, MockFeeToken} from "../test-helpers/MockUSDC.sol";

/// @dev deposit, checkIn and setCheckInDelegate.
contract DMSDepositCheckInTest is DMSTestBase {
    // ------------------------------------------------------------------ deposit

    function test_Deposit_CreditsBalanceAndEmits() public {
        uint256 id = createDefaultVault();
        usdc.mint(depositor, DEP);
        vm.startPrank(depositor);
        usdc.approve(address(dms), DEP);
        vm.expectEmit(true, true, false, true, address(dms));
        emit DMS.Deposited(id, depositor, DEP);
        dms.deposit(id, DEP);
        vm.stopPrank();
        assertEq(_v(id).balance, DEP);
        assertEq(dms.totalDeposited(), DEP);
        assertEq(usdc.balanceOf(address(dms)), DEP);
        assertEq(usdc.balanceOf(depositor), 0);
    }

    function test_Deposit_DoesNotResetTimer() public {
        uint256 id = createDefaultVault();
        vm.warp(T0 + 5 days);
        _deposit(id, stranger, DEP);
        assertEq(_v(id).lastCheckIn, T0);
        assertEq(_v(id).deadline, T0 + INTERVAL);
    }

    function test_Deposit_AnyoneCanDepositAndAccumulates() public {
        uint256 id = createDefaultVault();
        _deposit(id, stranger, 10e6);
        _deposit(id, owner, 5e6);
        _deposit(id, g1, 1e6);
        assertEq(_v(id).balance, 16e6);
        assertEq(dms.totalDeposited(), 16e6);
    }

    function test_Deposit_AllowedInExpiredAndChallenge() public {
        uint256 id = createDefaultVault();
        _toDeadline(id);
        _assertPhase(id, DMS.Phase.Expired);
        _deposit(id, depositor, 1e6);
        vm.prank(stranger);
        dms.trigger(id);
        _assertPhase(id, DMS.Phase.Challenge);
        _deposit(id, depositor, 2e6);
        vm.warp(_v(id).challengeEnd - 1);
        _deposit(id, depositor, 3e6);
        assertEq(_v(id).balance, 6e6);
    }

    function test_RevertDeposit_ZeroAmount() public {
        uint256 id = createDefaultVault();
        vm.prank(depositor);
        vm.expectRevert(DMS.ZeroAmount.selector);
        dms.deposit(id, 0);
    }

    function test_RevertDeposit_VaultNotFound() public {
        usdc.mint(depositor, 1e6);
        vm.startPrank(depositor);
        usdc.approve(address(dms), 1e6);
        vm.expectRevert(_e(DMS.VaultNotFound.selector, 7));
        dms.deposit(7, 1e6);
        vm.stopPrank();
    }

    function test_RevertDeposit_ClaimsOpen() public {
        uint256 id = _funded(DEP);
        _toClaims(id);
        _assertPhase(id, DMS.Phase.ClaimsOpen);
        usdc.mint(depositor, 1e6);
        vm.startPrank(depositor);
        usdc.approve(address(dms), 1e6);
        vm.expectRevert(_e(DMS.DepositsClosed.selector, id));
        dms.deposit(id, 1e6);
        vm.stopPrank();
    }

    function test_RevertDeposit_ClaimsOpenEvenAfterSweepTimeBeforeSweep() public {
        uint256 id = _funded(DEP);
        _toSweepTime(id);
        usdc.mint(depositor, 1e6);
        vm.startPrank(depositor);
        usdc.approve(address(dms), 1e6);
        vm.expectRevert(_e(DMS.DepositsClosed.selector, id));
        dms.deposit(id, 1e6);
        vm.stopPrank();
    }

    function test_RevertDeposit_Swept() public {
        uint256 id = _funded(DEP);
        _toSweepTime(id);
        dms.sweep(id);
        usdc.mint(depositor, 1e6);
        vm.startPrank(depositor);
        usdc.approve(address(dms), 1e6);
        vm.expectRevert(_e(DMS.DepositsClosed.selector, id));
        dms.deposit(id, 1e6);
        vm.stopPrank();
    }

    function test_RevertDeposit_NoTokensReceived() public {
        MockNoopToken noop = new MockNoopToken();
        DMS d = new DMS(IERC20(address(noop)));
        vm.prank(owner);
        uint256 id = d.createVault(_params());
        vm.prank(depositor);
        vm.expectRevert(DMS.NoTokensReceived.selector);
        d.deposit(id, 100);
    }

    function test_Deposit_FeeOnTransferCreditsActualReceived() public {
        MockFeeToken fee = new MockFeeToken();
        DMS d = new DMS(IERC20(address(fee)));
        vm.prank(owner);
        uint256 id = d.createVault(_params());
        fee.mint(depositor, 1000e6);
        vm.startPrank(depositor);
        fee.approve(address(d), 1000e6);
        vm.expectEmit(true, true, false, true, address(d));
        emit DMS.Deposited(id, depositor, 900e6);
        d.deposit(id, 1000e6);
        vm.stopPrank();
        assertEq(d.getVault(id).balance, 900e6);
        assertEq(d.totalDeposited(), 900e6);
        assertEq(fee.balanceOf(address(d)), 900e6);
    }

    // ------------------------------------------------------------------ checkIn

    function test_CheckIn_OwnerResetsDeadlineAndEmits() public {
        uint256 id = createDefaultVault();
        vm.warp(T0 + 10 days);
        vm.expectEmit(true, true, false, true, address(dms));
        emit DMS.CheckedIn(id, owner, T0 + 10 days + INTERVAL);
        vm.prank(owner);
        dms.checkIn(id);
        DMS.VaultView memory v = _v(id);
        assertEq(v.lastCheckIn, T0 + 10 days);
        assertEq(v.deadline, T0 + 10 days + INTERVAL);
        _assertPhase(id, DMS.Phase.Active);
    }

    function test_CheckIn_DelegateResetsDeadline() public {
        uint256 id = createDefaultVault();
        vm.prank(owner);
        dms.setCheckInDelegate(id, delegate);
        vm.warp(T0 + 3 days);
        vm.expectEmit(true, true, false, true, address(dms));
        emit DMS.CheckedIn(id, delegate, T0 + 3 days + INTERVAL);
        vm.prank(delegate);
        dms.checkIn(id);
        assertEq(_v(id).deadline, T0 + 3 days + INTERVAL);
    }

    function test_CheckIn_RepeatedlyExtendsAndSucceedsAtDeadlineMinusOne() public {
        uint256 id = createDefaultVault();
        vm.warp(T0 + INTERVAL - 1);
        vm.prank(owner);
        dms.checkIn(id);
        assertEq(_v(id).deadline, T0 + INTERVAL - 1 + INTERVAL);
    }

    function test_RevertCheckIn_NotOwnerOrDelegate() public {
        uint256 id = createDefaultVault();
        address[4] memory bad = [stranger, g1, alice, newOwner];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(bad[i]);
            vm.expectRevert(_e(DMS.NotOwnerOrDelegate.selector, id));
            dms.checkIn(id);
        }
    }

    function test_RevertCheckIn_VaultExpiredAtExactDeadline() public {
        uint256 id = createDefaultVault();
        _toDeadline(id);
        vm.prank(owner);
        vm.expectRevert(_e(DMS.VaultExpired.selector, id));
        dms.checkIn(id);
    }

    function test_RevertCheckIn_VaultExpiredLongAfter() public {
        uint256 id = createDefaultVault();
        vm.warp(T0 + INTERVAL + 100 days);
        vm.prank(owner);
        vm.expectRevert(_e(DMS.VaultExpired.selector, id));
        dms.checkIn(id);
    }

    function test_CheckIn_DuringChallengeCancelsTriggerAtChallengeEndMinusOne() public {
        uint256 id = createDefaultVault();
        _trigger(id);
        vm.warp(_v(id).challengeEnd - 1);
        uint256 expectedDl = block.timestamp + INTERVAL;
        vm.expectEmit(true, true, false, false, address(dms));
        emit DMS.TriggerCancelled(id, owner);
        vm.expectEmit(true, true, false, true, address(dms));
        emit DMS.CheckedIn(id, owner, expectedDl);
        vm.prank(owner);
        dms.checkIn(id);
        assertFalse(_v(id).triggered);
    }

    function test_RevertCheckIn_ChallengeEndedAtExactChallengeEnd() public {
        uint256 id = createDefaultVault();
        _trigger(id);
        vm.warp(_v(id).challengeEnd);
        vm.prank(owner);
        vm.expectRevert(_e(DMS.ChallengeEnded.selector, id));
        dms.checkIn(id);
    }

    function test_RevertCheckIn_ClaimsOpenAndSwept() public {
        uint256 id = createDefaultVault();
        _toClaims(id);
        vm.prank(owner);
        vm.expectRevert(_e(DMS.ChallengeEnded.selector, id));
        dms.checkIn(id);
        vm.warp(_v(id).sweepAt);
        dms.sweep(id);
        vm.prank(owner);
        vm.expectRevert(_e(DMS.ChallengeEnded.selector, id));
        dms.checkIn(id);
    }

    function test_RevertCheckIn_VaultNotFound() public {
        vm.prank(owner);
        vm.expectRevert(_e(DMS.VaultNotFound.selector, 42));
        dms.checkIn(42);
    }

    function test_RevertCheckIn_TimestampOverflow() public {
        DMS.CreateParams memory p = _params();
        p.interval = 60;
        vm.warp(uint256(type(uint64).max) - 60);
        uint256 id = _create(p); // deadline == uint64 max
        vm.warp(uint256(type(uint64).max) - 59);
        vm.prank(owner);
        vm.expectRevert(DMS.TimestampOverflow.selector);
        dms.checkIn(id);
    }

    // ------------------------------------------------------------------ setCheckInDelegate

    function test_SetDelegate_StoresAndEmits() public {
        uint256 id = createDefaultVault();
        vm.expectEmit(true, false, false, true, address(dms));
        emit DMS.CheckInDelegateSet(id, delegate);
        vm.prank(owner);
        dms.setCheckInDelegate(id, delegate);
        assertEq(_v(id).checkInDelegate, delegate);
    }

    function test_SetDelegate_ZeroRevokes() public {
        uint256 id = createDefaultVault();
        vm.startPrank(owner);
        dms.setCheckInDelegate(id, delegate);
        vm.expectEmit(true, false, false, true, address(dms));
        emit DMS.CheckInDelegateSet(id, address(0));
        dms.setCheckInDelegate(id, address(0));
        vm.stopPrank();
        assertEq(_v(id).checkInDelegate, address(0));
        vm.prank(delegate);
        vm.expectRevert(_e(DMS.NotOwnerOrDelegate.selector, id));
        dms.checkIn(id);
    }

    function test_SetDelegate_ReplacingRevokesOld() public {
        uint256 id = createDefaultVault();
        vm.startPrank(owner);
        dms.setCheckInDelegate(id, delegate);
        dms.setCheckInDelegate(id, stranger);
        vm.stopPrank();
        vm.prank(delegate);
        vm.expectRevert(_e(DMS.NotOwnerOrDelegate.selector, id));
        dms.checkIn(id);
        vm.prank(stranger);
        dms.checkIn(id);
    }

    function test_SetDelegate_AllowedInExpiredPhase() public {
        uint256 id = createDefaultVault();
        _toDeadline(id);
        vm.prank(owner);
        dms.setCheckInDelegate(id, delegate);
        assertEq(_v(id).checkInDelegate, delegate);
    }

    function test_RevertSetDelegate_NotOwner() public {
        uint256 id = createDefaultVault();
        address[3] memory bad = [stranger, g1, alice];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(bad[i]);
            vm.expectRevert(_e(DMS.NotVaultOwner.selector, id));
            dms.setCheckInDelegate(id, delegate);
        }
    }

    function test_RevertSetDelegate_DelegateIsOwner() public {
        uint256 id = createDefaultVault();
        vm.prank(owner);
        vm.expectRevert(DMS.InvalidDelegate.selector);
        dms.setCheckInDelegate(id, owner);
    }

    function test_RevertSetDelegate_DelegateIsContract() public {
        uint256 id = createDefaultVault();
        vm.prank(owner);
        vm.expectRevert(DMS.InvalidDelegate.selector);
        dms.setCheckInDelegate(id, address(dms));
    }

    function test_RevertSetDelegate_VaultNotFound() public {
        vm.prank(owner);
        vm.expectRevert(_e(DMS.VaultNotFound.selector, 5));
        dms.setCheckInDelegate(5, delegate);
    }
}
