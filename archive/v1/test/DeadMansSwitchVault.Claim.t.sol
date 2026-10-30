// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DeadMansSwitchVault} from "../DeadMansSwitchVault.sol";
import {DeadMansSwitchVaultTestBase} from "./DeadMansSwitchVault.Base.t.sol";

/// @dev Categories 5-6: deposits and claims.
contract DeadMansSwitchVaultClaimTest is DeadMansSwitchVaultTestBase {
    // ============ 5) deposits ============

    function test_Deposit_OwnerCanDepositAndEmits() public {
        uint256 id = _createDefault();
        usdc.mint(owner, 500);
        vm.startPrank(owner);
        usdc.approve(address(dms), 500);
        vm.expectEmit(true, true, false, true, address(dms));
        emit DeadMansSwitchVault.Deposited(id, owner, 500);
        dms.deposit(id, 500);
        vm.stopPrank();
        assertEq(dms.getVault(id).balance, 500);
        assertEq(usdc.balanceOf(address(dms)), 500);
    }

    function test_Deposit_ThirdPartyCanDeposit() public {
        uint256 id = _createDefault();
        _deposit(id, stranger, 250);
        assertEq(dms.getVault(id).balance, 250);
        assertEq(usdc.balanceOf(stranger), 0);
    }

    function test_Deposit_DoesNotResetTimer() public {
        uint256 id = _createDefault();
        uint256 dl = dms.deadline(id);
        vm.warp(block.timestamp + 5 hours);
        _deposit(id, owner, 100);
        _deposit(id, stranger, 100);
        assertEq(dms.deadline(id), dl);
        assertEq(dms.getVault(id).lastCheckIn, dl - INTERVAL);
    }

    function test_Deposit_UnknownVaultReverts() public {
        usdc.mint(owner, 100);
        vm.startPrank(owner);
        usdc.approve(address(dms), 100);
        vm.expectRevert(abi.encodeWithSelector(DeadMansSwitchVault.VaultNotFound.selector, 99));
        dms.deposit(99, 100);
        vm.stopPrank();
    }

    function test_Deposit_AfterTriggerReverts() public {
        uint256 id = _createDefault();
        _expire(id);
        dms.trigger(id);
        usdc.mint(owner, 100);
        vm.startPrank(owner);
        usdc.approve(address(dms), 100);
        vm.expectRevert(abi.encodeWithSelector(DeadMansSwitchVault.VaultAlreadyTriggered.selector, id));
        dms.deposit(id, 100);
        vm.stopPrank();
    }

    function test_Deposit_ZeroAmountReverts() public {
        uint256 id = _createDefault();
        vm.expectRevert(DeadMansSwitchVault.ZeroAmount.selector);
        dms.deposit(id, 0);
    }

    function test_Deposit_AfterExpiryBeforeTriggerWorksAndCountsInPool() public {
        uint256 id = _createDefault();
        _expire(id);
        _deposit(id, stranger, 777);
        dms.trigger(id);
        assertEq(dms.getVault(id).claimPool, 777);
    }

    function test_Deposit_VaultsAreIsolated() public {
        uint256 id1 = _createDefault();
        uint256 id2 = _createDefault();
        _deposit(id1, owner, 100);
        _deposit(id2, owner, 300);
        assertEq(dms.getVault(id1).balance, 100);
        assertEq(dms.getVault(id2).balance, 300);
    }

    // ============ 6) claim ============

    function test_Claim_BeforeTriggerReverts() public {
        uint256 id = _createDefault();
        _deposit(id, owner, 100);
        vm.expectRevert(abi.encodeWithSelector(DeadMansSwitchVault.VaultNotTriggered.selector, id));
        vm.prank(alice);
        dms.claim(id);
    }

    function test_Claim_ExpiredButUntriggeredReverts() public {
        uint256 id = _createDefault();
        _deposit(id, owner, 100);
        _expire(id);
        vm.expectRevert(abi.encodeWithSelector(DeadMansSwitchVault.VaultNotTriggered.selector, id));
        vm.prank(alice);
        dms.claim(id);
    }

    function test_Claim_UnknownVaultReverts() public {
        vm.expectRevert(abi.encodeWithSelector(DeadMansSwitchVault.VaultNotFound.selector, 5));
        vm.prank(alice);
        dms.claim(5);
    }

    function test_Claim_PayoutsByShareAndEmits() public {
        uint256 id = _createDefault(); // alice 60%, bob 40%
        _deposit(id, owner, 1000);
        _expire(id);
        dms.trigger(id);

        vm.expectEmit(true, true, false, true, address(dms));
        emit DeadMansSwitchVault.Claimed(id, alice, 600);
        assertEq(_claim(id, alice), 600);
        assertEq(dms.claimable(id, bob), 400);
        assertEq(_claim(id, bob), 400);

        assertEq(usdc.balanceOf(address(dms)), 0);
        DeadMansSwitchVault.VaultView memory v = dms.getVault(id);
        assertEq(v.totalClaimed, 1000);
        assertEq(v.claimedCount, 2);
        assertTrue(dms.hasClaimed(id, alice));
        assertTrue(dms.hasClaimed(id, bob));
    }

    function test_Claim_DoubleClaimReverts() public {
        uint256 id = _createDefault();
        _deposit(id, owner, 1000);
        _expire(id);
        dms.trigger(id);
        _claim(id, alice);
        vm.expectRevert(abi.encodeWithSelector(DeadMansSwitchVault.AlreadyClaimed.selector, id, alice));
        vm.prank(alice);
        dms.claim(id);
        assertEq(dms.claimable(id, alice), 0);
    }

    function test_Claim_NonBeneficiaryReverts() public {
        uint256 id = _createDefault();
        _deposit(id, owner, 1000);
        _expire(id);
        dms.trigger(id);
        vm.expectRevert(abi.encodeWithSelector(DeadMansSwitchVault.NotBeneficiary.selector, id, stranger));
        vm.prank(stranger);
        dms.claim(id);
    }

    function test_Claim_OwnerNotBeneficiaryReverts() public {
        uint256 id = _createDefault();
        _deposit(id, owner, 1000);
        _expire(id);
        dms.trigger(id);
        vm.expectRevert(abi.encodeWithSelector(DeadMansSwitchVault.NotBeneficiary.selector, id, owner));
        vm.prank(owner);
        dms.claim(id);
    }

    function test_Claim_BeneficiaryOfOtherVaultCannotClaim() public {
        uint256 id1 = _createDefault();
        address[] memory a = new address[](1);
        a[0] = carol;
        uint16[] memory s = new uint16[](1);
        s[0] = 10000;
        uint256 id2 = _create(a, s, INTERVAL);
        _deposit(id1, owner, 1000);
        _deposit(id2, owner, 1000);
        _expire(id1);
        dms.trigger(id1);
        vm.expectRevert(abi.encodeWithSelector(DeadMansSwitchVault.NotBeneficiary.selector, id1, carol));
        vm.prank(carol);
        dms.claim(id1);
    }

    function _setup3(uint256 amount) internal returns (uint256 id) {
        id = _create(_addrs3(), _shares3(3333, 3333, 3334), INTERVAL);
        _deposit(id, owner, amount);
        _expire(id);
        dms.trigger(id);
    }

    function test_Claim_RemainderToLastClaimant_ABC() public {
        uint256 id = _setup3(101);
        assertEq(_claim(id, alice), 33);
        assertEq(_claim(id, bob), 33);
        assertEq(_claim(id, carol), 35); // 101 - 66
        assertEq(usdc.balanceOf(address(dms)), 0);
    }

    function test_Claim_RemainderToLastClaimant_CAB() public {
        uint256 id = _setup3(101);
        assertEq(_claim(id, carol), 33); // floor(101*3334/10000)
        assertEq(_claim(id, alice), 33);
        assertEq(_claim(id, bob), 35); // last claimant gets the dust
        assertEq(usdc.balanceOf(address(dms)), 0);
    }

    function test_Claim_RemainderToLastClaimant_BCA() public {
        uint256 id = _setup3(101);
        assertEq(_claim(id, bob), 33);
        assertEq(_claim(id, carol), 33);
        assertEq(_claim(id, alice), 35);
        assertEq(usdc.balanceOf(address(dms)), 0);
    }

    function test_Claim_Pool100_LastGetsRemainder() public {
        uint256 id = _setup3(100);
        assertEq(_claim(id, bob), 33);
        assertEq(_claim(id, alice), 33);
        assertEq(_claim(id, carol), 34);
        assertEq(usdc.balanceOf(address(dms)), 0);
    }

    function test_Claim_Pool1Wei_FirstClaimantsGetZeroLastGetsOne() public {
        uint256 id = _setup3(1);
        assertEq(_claim(id, carol), 0);
        assertEq(_claim(id, alice), 0);
        assertEq(_claim(id, bob), 1);
        assertEq(usdc.balanceOf(address(dms)), 0);
        assertEq(dms.getVault(id).totalClaimed, 1);
    }

    function test_Claim_OddAmountsContractBalanceEndsZero() public {
        uint256 id = _setup3(999_999_937);
        uint256 total = _claim(id, bob) + _claim(id, carol) + _claim(id, alice);
        assertEq(total, 999_999_937);
        assertEq(usdc.balanceOf(address(dms)), 0);
    }

    function test_Claim_OtherVaultFundsUntouched() public {
        uint256 id = _setup3(101);
        uint256 other = _createDefault();
        _deposit(other, owner, 5000);
        _claim(id, alice);
        _claim(id, bob);
        _claim(id, carol);
        assertEq(usdc.balanceOf(address(dms)), 5000);
        assertEq(dms.getVault(other).balance, 5000);
    }

    function test_Claim_EmptyVaultPaysZeroAndMarksClaimed() public {
        uint256 id = _createDefault();
        _expire(id);
        dms.trigger(id);
        assertEq(dms.getVault(id).claimPool, 0);

        vm.expectEmit(true, true, false, true, address(dms));
        emit DeadMansSwitchVault.Claimed(id, alice, 0);
        assertEq(_claim(id, alice), 0);
        assertTrue(dms.hasClaimed(id, alice));
        assertEq(dms.getVault(id).claimedCount, 1);

        vm.expectRevert(abi.encodeWithSelector(DeadMansSwitchVault.AlreadyClaimed.selector, id, alice));
        vm.prank(alice);
        dms.claim(id);
        assertEq(_claim(id, bob), 0);
        assertEq(dms.getVault(id).claimedCount, 2);
    }

    function test_Claim_SingleBeneficiaryGetsAll() public {
        address[] memory a = new address[](1);
        a[0] = alice;
        uint16[] memory s = new uint16[](1);
        s[0] = 10000;
        uint256 id = _create(a, s, INTERVAL);
        _deposit(id, owner, 12345);
        _expire(id);
        dms.trigger(id);
        assertEq(_claim(id, alice), 12345);
    }

    function test_Claim_ClaimableViewBeforeTriggerIsZero() public {
        uint256 id = _createDefault();
        _deposit(id, owner, 100);
        assertEq(dms.claimable(id, alice), 0);
        assertEq(dms.claimable(id, stranger), 0);
    }
}
