// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeadMansSwitchVault} from "../DeadMansSwitchVault.sol";
import {DeadMansSwitchVaultTestBase} from "./DeadMansSwitchVault.Base.t.sol";

/// @dev Categories 1-4: createVault, trigger, owner-only ops, expired-vault reverts.
contract DeadMansSwitchVaultTest is DeadMansSwitchVaultTestBase {
    // ============ 1) createVault ============

    function test_Create_SharesUnder10000Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(DeadMansSwitchVault.InvalidSharesTotal.selector, 9999));
        vm.prank(owner);
        dms.createVault(_addrs2(), _shares2(5000, 4999), INTERVAL);
    }

    function test_Create_SharesOver10000Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(DeadMansSwitchVault.InvalidSharesTotal.selector, 10001));
        vm.prank(owner);
        dms.createVault(_addrs2(), _shares2(5000, 5001), INTERVAL);
    }

    function test_Create_EmptyBeneficiariesReverts() public {
        address[] memory a = new address[](0);
        uint16[] memory s = new uint16[](0);
        vm.expectRevert(DeadMansSwitchVault.EmptyBeneficiaries.selector);
        vm.prank(owner);
        dms.createVault(a, s, INTERVAL);
    }

    function test_Create_LengthMismatchReverts() public {
        uint16[] memory s = new uint16[](1);
        s[0] = 10000;
        vm.expectRevert(DeadMansSwitchVault.LengthMismatch.selector);
        vm.prank(owner);
        dms.createVault(_addrs2(), s, INTERVAL);
    }

    function test_Create_TooManyBeneficiariesReverts() public {
        address[] memory a = new address[](21);
        uint16[] memory s = new uint16[](21);
        for (uint256 i; i < 21; ++i) {
            a[i] = address(uint160(0x1000 + i));
            s[i] = 1;
        }
        vm.expectRevert(DeadMansSwitchVault.TooManyBeneficiaries.selector);
        vm.prank(owner);
        dms.createVault(a, s, INTERVAL);
    }

    function test_Create_ZeroAddressBeneficiaryReverts() public {
        address[] memory a = _addrs2();
        a[1] = address(0);
        vm.expectRevert(DeadMansSwitchVault.ZeroBeneficiary.selector);
        vm.prank(owner);
        dms.createVault(a, _shares2(5000, 5000), INTERVAL);
    }

    function test_Create_DuplicateBeneficiaryReverts() public {
        address[] memory a = _addrs2();
        a[1] = alice;
        vm.expectRevert(abi.encodeWithSelector(DeadMansSwitchVault.DuplicateBeneficiary.selector, alice));
        vm.prank(owner);
        dms.createVault(a, _shares2(5000, 5000), INTERVAL);
    }

    function test_Create_ZeroShareReverts() public {
        vm.expectRevert(abi.encodeWithSelector(DeadMansSwitchVault.ZeroShare.selector, bob));
        vm.prank(owner);
        dms.createVault(_addrs2(), _shares2(10000, 0), INTERVAL);
    }

    function test_Create_Interval59RevertsAnd60Ok() public {
        vm.expectRevert(abi.encodeWithSelector(DeadMansSwitchVault.InvalidInterval.selector, uint64(59)));
        vm.prank(owner);
        dms.createVault(_addrs2(), _shares2(5000, 5000), 59);

        uint256 id = _create(_addrs2(), _shares2(5000, 5000), 60);
        assertEq(dms.getVault(id).interval, 60);
    }

    function test_Create_IntervalTooLargeReverts() public {
        uint64 max = dms.MAX_INTERVAL();
        vm.expectRevert(abi.encodeWithSelector(DeadMansSwitchVault.InvalidInterval.selector, max + 1));
        vm.prank(owner);
        dms.createVault(_addrs2(), _shares2(5000, 5000), max + 1);

        uint256 id = _create(_addrs2(), _shares2(5000, 5000), max); // boundary ok
        assertEq(dms.deadline(id), block.timestamp + max);
    }

    function test_Create_TimestampOverflowReverts() public {
        vm.warp(uint256(type(uint64).max) - 10);
        vm.expectRevert(DeadMansSwitchVault.TimestampOverflow.selector);
        vm.prank(owner);
        dms.createVault(_addrs2(), _shares2(5000, 5000), 60);
    }

    function test_Create_HappyPathEmitsAndStoresState() public {
        address[] memory a = _addrs2();
        uint16[] memory s = _shares2(6000, 4000);
        vm.expectEmit(true, true, false, true, address(dms));
        emit DeadMansSwitchVault.VaultCreated(1, owner, a, s, INTERVAL);
        uint256 id = _create(a, s, INTERVAL);

        assertEq(id, 1);
        assertEq(dms.vaultCount(), 1);
        assertEq(dms.nextVaultId(), 2);
        DeadMansSwitchVault.VaultView memory v = dms.getVault(id);
        assertEq(v.owner, owner);
        assertEq(v.lastCheckIn, block.timestamp);
        assertEq(v.interval, INTERVAL);
        assertEq(v.deadline, block.timestamp + INTERVAL);
        assertEq(v.balance, 0);
        assertEq(v.claimPool, 0);
        assertFalse(v.triggered);
        assertEq(v.beneficiaryCount, 2);
        (address[] memory ga, uint16[] memory gs) = dms.getBeneficiaries(id);
        assertEq(ga[0], alice);
        assertEq(ga[1], bob);
        assertEq(gs[0], 6000);
        assertEq(gs[1], 4000);
    }

    function test_Create_ConstructorZeroTokenReverts() public {
        vm.expectRevert(DeadMansSwitchVault.ZeroTokenAddress.selector);
        new DeadMansSwitchVault(IERC20(address(0)));
    }

    // ============ 2) trigger ============

    function test_Trigger_BeforeDeadlineReverts() public {
        uint256 id = _createDefault();
        vm.expectRevert(abi.encodeWithSelector(DeadMansSwitchVault.VaultNotExpired.selector, id));
        dms.trigger(id);
    }

    function test_Trigger_OneSecondBeforeDeadlineReverts() public {
        uint256 id = _createDefault();
        vm.warp(dms.deadline(id) - 1);
        vm.expectRevert(abi.encodeWithSelector(DeadMansSwitchVault.VaultNotExpired.selector, id));
        dms.trigger(id);
    }

    function test_Trigger_AtExactDeadlineSucceeds() public {
        uint256 id = _createDefault();
        _expire(id);
        dms.trigger(id);
        assertTrue(dms.getVault(id).triggered);
    }

    function test_Trigger_AfterDeadlineSucceeds() public {
        uint256 id = _createDefault();
        vm.warp(dms.deadline(id) + 10 days);
        dms.trigger(id);
        assertTrue(dms.getVault(id).triggered);
    }

    function test_Trigger_AnyoneCanTriggerAndEmits() public {
        uint256 id = _createDefault();
        _deposit(id, owner, 1000);
        _expire(id);
        address rando = makeAddr("rando");
        vm.expectEmit(true, true, false, true, address(dms));
        emit DeadMansSwitchVault.Triggered(id, rando, 1000);
        vm.prank(rando);
        dms.trigger(id);
    }

    function test_Trigger_DoubleTriggerReverts() public {
        uint256 id = _createDefault();
        _expire(id);
        dms.trigger(id);
        vm.expectRevert(abi.encodeWithSelector(DeadMansSwitchVault.VaultAlreadyTriggered.selector, id));
        dms.trigger(id);
    }

    function test_Trigger_SnapshotsClaimPool() public {
        uint256 id = _createDefault();
        _deposit(id, owner, 700);
        _deposit(id, stranger, 300);
        _expire(id);
        dms.trigger(id);
        DeadMansSwitchVault.VaultView memory v = dms.getVault(id);
        assertEq(v.claimPool, 1000);
        assertEq(v.balance, 0);
        assertEq(v.totalClaimed, 0);
    }

    function test_Trigger_UnknownVaultReverts() public {
        vm.expectRevert(abi.encodeWithSelector(DeadMansSwitchVault.VaultNotFound.selector, 42));
        dms.trigger(42);
    }

    // ============ 3) owner-only checkIn / withdraw ============

    function test_CheckIn_NonOwnerReverts() public {
        uint256 id = _createDefault();
        vm.expectRevert(abi.encodeWithSelector(DeadMansSwitchVault.NotVaultOwner.selector, id));
        vm.prank(alice);
        dms.checkIn(id);
    }

    function test_Withdraw_NonOwnerReverts() public {
        uint256 id = _createDefault();
        _deposit(id, owner, 100);
        vm.expectRevert(abi.encodeWithSelector(DeadMansSwitchVault.NotVaultOwner.selector, id));
        vm.prank(alice);
        dms.withdraw(id, 1);
    }

    function test_CheckIn_OwnerResetsTimerAndEmits() public {
        uint256 id = _createDefault();
        vm.warp(block.timestamp + 10 hours);
        uint256 expected = block.timestamp + INTERVAL;
        vm.expectEmit(true, false, false, true, address(dms));
        emit DeadMansSwitchVault.CheckedIn(id, block.timestamp, expected);
        vm.prank(owner);
        dms.checkIn(id);
        assertEq(dms.deadline(id), expected);
        assertEq(dms.getVault(id).lastCheckIn, block.timestamp);
    }

    function test_Withdraw_OwnerPartialBeforeDeadline() public {
        uint256 id = _createDefault();
        _deposit(id, owner, 1000);
        uint256 dl = dms.deadline(id);
        vm.expectEmit(true, false, false, true, address(dms));
        emit DeadMansSwitchVault.Withdrawn(id, 400);
        vm.prank(owner);
        dms.withdraw(id, 400);
        assertEq(usdc.balanceOf(owner), 400);
        assertEq(dms.getVault(id).balance, 600);
        assertEq(usdc.balanceOf(address(dms)), 600);
        assertEq(dms.deadline(id), dl); // withdraw does not reset timer
    }

    function test_Withdraw_OwnerFullBeforeDeadline() public {
        uint256 id = _createDefault();
        _deposit(id, owner, 1000);
        vm.prank(owner);
        dms.withdraw(id, 1000);
        assertEq(usdc.balanceOf(owner), 1000);
        assertEq(dms.getVault(id).balance, 0);
        assertEq(usdc.balanceOf(address(dms)), 0);
    }

    function test_Withdraw_MoreThanBalanceReverts() public {
        uint256 id = _createDefault();
        _deposit(id, owner, 1000);
        vm.expectRevert(abi.encodeWithSelector(DeadMansSwitchVault.InsufficientVaultBalance.selector, 1000, 1001));
        vm.prank(owner);
        dms.withdraw(id, 1001);
    }

    function test_Withdraw_ZeroAmountReverts() public {
        uint256 id = _createDefault();
        _deposit(id, owner, 1000);
        vm.expectRevert(DeadMansSwitchVault.ZeroAmount.selector);
        vm.prank(owner);
        dms.withdraw(id, 0);
    }

    function test_Withdraw_OtherVaultFundsNotAccessible() public {
        uint256 id1 = _createDefault();
        uint256 id2 = _createDefault();
        _deposit(id2, owner, 1000);
        vm.expectRevert(abi.encodeWithSelector(DeadMansSwitchVault.InsufficientVaultBalance.selector, 0, 1));
        vm.prank(owner);
        dms.withdraw(id1, 1);
    }

    // ============ 4) expired-vault reverts ============

    function test_CheckIn_AtDeadlineReverts() public {
        uint256 id = _createDefault();
        _expire(id);
        vm.expectRevert(abi.encodeWithSelector(DeadMansSwitchVault.VaultExpired.selector, id));
        vm.prank(owner);
        dms.checkIn(id);
    }

    function test_CheckIn_AfterDeadlineReverts() public {
        uint256 id = _createDefault();
        vm.warp(dms.deadline(id) + 1);
        vm.expectRevert(abi.encodeWithSelector(DeadMansSwitchVault.VaultExpired.selector, id));
        vm.prank(owner);
        dms.checkIn(id);
    }

    function test_CheckIn_OneSecondBeforeDeadlineWorks() public {
        uint256 id = _createDefault();
        vm.warp(dms.deadline(id) - 1);
        vm.prank(owner);
        dms.checkIn(id);
        assertEq(dms.deadline(id), block.timestamp + INTERVAL);
    }

    function test_Withdraw_AtDeadlineReverts() public {
        uint256 id = _createDefault();
        _deposit(id, owner, 100);
        _expire(id);
        vm.expectRevert(abi.encodeWithSelector(DeadMansSwitchVault.VaultExpired.selector, id));
        vm.prank(owner);
        dms.withdraw(id, 1);
    }

    function test_Withdraw_AfterDeadlineReverts() public {
        uint256 id = _createDefault();
        _deposit(id, owner, 100);
        vm.warp(dms.deadline(id) + 5);
        vm.expectRevert(abi.encodeWithSelector(DeadMansSwitchVault.VaultExpired.selector, id));
        vm.prank(owner);
        dms.withdraw(id, 1);
    }

    function test_Withdraw_OneSecondBeforeDeadlineWorks() public {
        uint256 id = _createDefault();
        _deposit(id, owner, 100);
        vm.warp(dms.deadline(id) - 1);
        vm.prank(owner);
        dms.withdraw(id, 100);
        assertEq(usdc.balanceOf(owner), 100);
    }

    function test_CheckInAndWithdraw_AfterTriggerRevert() public {
        uint256 id = _createDefault();
        _deposit(id, owner, 100);
        _expire(id);
        dms.trigger(id);
        // Expiry check is evaluated after the triggered check in the contract.
        vm.expectRevert(abi.encodeWithSelector(DeadMansSwitchVault.VaultAlreadyTriggered.selector, id));
        vm.prank(owner);
        dms.checkIn(id);
        vm.expectRevert(abi.encodeWithSelector(DeadMansSwitchVault.VaultAlreadyTriggered.selector, id));
        vm.prank(owner);
        dms.withdraw(id, 1);
    }

    function test_CheckIn_UnknownVaultReverts() public {
        vm.expectRevert(abi.encodeWithSelector(DeadMansSwitchVault.VaultNotFound.selector, 7));
        vm.prank(owner);
        dms.checkIn(7);
    }
}
