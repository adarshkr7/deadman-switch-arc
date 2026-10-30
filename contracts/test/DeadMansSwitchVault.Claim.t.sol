// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DeadMansSwitchVault as DMS} from "../DeadMansSwitchVault.sol";
import {DMSTestBase} from "./DeadMansSwitchVault.Base.t.sol";

/// @dev setPayoutAddress and claim.
contract DMSClaimTest is DMSTestBase {
    uint256 internal id;

    function setUp() public override {
        super.setUp();
        id = _funded(DEP);
    }

    function _claim(uint256 vid, address who) internal returns (uint256 paid) {
        address to = dms.payoutAddressOf(vid, who);
        uint256 beforeBal = usdc.balanceOf(to);
        vm.prank(who);
        dms.claim(vid);
        paid = usdc.balanceOf(to) - beforeBal;
    }

    /// @dev 3-beneficiary vault 33.33% / 33.33% / 33.34% holding `pool` units.
    function _threeWay(uint256 pool) internal returns (uint256 vid) {
        DMS.CreateParams memory p = _params();
        p.beneficiaries = new address[](3);
        p.beneficiaries[0] = alice;
        p.beneficiaries[1] = bob;
        p.beneficiaries[2] = carol;
        p.sharesBps = new uint16[](3);
        p.sharesBps[0] = 3333;
        p.sharesBps[1] = 3333;
        p.sharesBps[2] = 3334;
        vid = _create(p);
        _deposit(vid, depositor, pool);
        _toClaims(vid);
    }

    // ------------------------------------------------------------------ setPayoutAddress

    function test_SetPayout_StoresAndEmits() public {
        assertEq(dms.payoutAddressOf(id, alice), alice);
        vm.expectEmit(true, true, false, true, address(dms));
        emit DMS.PayoutAddressSet(id, alice, payoutAddr);
        vm.prank(alice);
        dms.setPayoutAddress(id, payoutAddr);
        assertEq(dms.payoutAddressOf(id, alice), payoutAddr);
        assertEq(dms.payoutAddressOf(id, bob), bob);
    }

    function test_SetPayout_ZeroResetsToBeneficiary() public {
        vm.startPrank(alice);
        dms.setPayoutAddress(id, payoutAddr);
        dms.setPayoutAddress(id, address(0));
        vm.stopPrank();
        assertEq(dms.payoutAddressOf(id, alice), alice);
    }

    function test_RevertSetPayout_NotBeneficiary() public {
        address[4] memory bad = [owner, g1, stranger, fallbackAddr];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(bad[i]);
            vm.expectRevert(abi.encodeWithSelector(DMS.NotBeneficiary.selector, id, bad[i]));
            dms.setPayoutAddress(id, payoutAddr);
        }
    }

    function test_RevertSetPayout_AlreadyClaimed() public {
        _toClaims(id);
        _claim(id, alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DMS.AlreadyClaimed.selector, id, alice));
        dms.setPayoutAddress(id, payoutAddr);
    }

    function test_RevertSetPayout_ContractAddress() public {
        vm.prank(alice);
        vm.expectRevert(DMS.InvalidPayoutAddress.selector);
        dms.setPayoutAddress(id, address(dms));
    }

    function test_RevertSetPayout_VaultNotFound() public {
        vm.prank(alice);
        vm.expectRevert(_e(DMS.VaultNotFound.selector, 99));
        dms.setPayoutAddress(99, payoutAddr);
    }

    // ------------------------------------------------------------------ claim: happy paths

    function test_Claim_AtChallengeEndPaysFloorShareThenRemainderToLast() public {
        _toClaims(id);
        assertEq(dms.claimable(id, alice), 600e6);
        vm.expectEmit(true, false, false, true, address(dms));
        emit DMS.Finalized(id, DEP);
        vm.expectEmit(true, true, true, true, address(dms));
        emit DMS.Claimed(id, alice, alice, 600e6);
        assertEq(_claim(id, alice), 600e6);
        assertTrue(dms.hasClaimed(id, alice));
        assertEq(dms.claimable(id, alice), 0);
        assertEq(dms.claimable(id, bob), 400e6);
        assertEq(_claim(id, bob), 400e6);
        DMS.VaultView memory v = _v(id);
        assertEq(v.claimedCount, 2);
        assertEq(v.totalClaimed, DEP);
        assertEq(v.claimPool, DEP);
        assertEq(usdc.balanceOf(address(dms)), 0);
        assertEq(dms.totalPaidOut(), DEP);
    }

    function test_Claim_PaysToPayoutAddress() public {
        vm.prank(alice);
        dms.setPayoutAddress(id, payoutAddr);
        _toClaims(id);
        vm.expectEmit(true, true, true, true, address(dms));
        emit DMS.Claimed(id, alice, payoutAddr, 600e6);
        vm.prank(alice);
        dms.claim(id);
        assertEq(usdc.balanceOf(payoutAddr), 600e6);
        assertEq(usdc.balanceOf(alice), 0);
    }

    function test_Claim_RemainderToLastClaimant_ArrayOrder() public {
        uint256 pool = 1_000_001;
        uint256 vid = _threeWay(pool);
        uint256 a = _claim(vid, alice);
        uint256 b = _claim(vid, bob);
        uint256 c = _claim(vid, carol);
        assertEq(a, (pool * 3333) / 10_000);
        assertEq(b, (pool * 3333) / 10_000);
        assertEq(c, pool - a - b, "last claimant (carol) gets the remainder");
        assertEq(a + b + c, pool);
    }

    function test_Claim_RemainderToLastClaimant_ReverseOrder() public {
        uint256 pool = 1_000_001;
        uint256 vid = _threeWay(pool);
        uint256 c = _claim(vid, carol);
        uint256 b = _claim(vid, bob);
        uint256 a = _claim(vid, alice);
        assertEq(c, (pool * 3334) / 10_000);
        assertEq(b, (pool * 3333) / 10_000);
        assertEq(a, pool - c - b, "last claimant (alice) gets the remainder");
        assertEq(a + b + c, pool);
    }

    function test_Claim_MiddleFirstOrder() public {
        uint256 pool = 777_777_777;
        uint256 vid = _threeWay(pool);
        uint256 b = _claim(vid, bob);
        uint256 c = _claim(vid, carol);
        uint256 a = _claim(vid, alice);
        assertEq(b, (pool * 3333) / 10_000);
        assertEq(c, (pool * 3334) / 10_000);
        assertEq(a + b + c, pool);
        assertEq(usdc.balanceOf(address(dms)), DEP, "only the unrelated setUp vault's funds remain");
    }

    function test_Claim_ZeroPoolConsumesClaimWithoutTransfer() public {
        uint256 id2 = createDefaultVault();
        _toClaims(id2);
        vm.expectEmit(true, false, false, true, address(dms));
        emit DMS.Finalized(id2, 0);
        vm.expectEmit(true, true, true, true, address(dms));
        emit DMS.Claimed(id2, alice, alice, 0);
        vm.prank(alice);
        dms.claim(id2);
        assertTrue(dms.hasClaimed(id2, alice));
        assertEq(_v(id2).claimedCount, 1);
        assertEq(usdc.balanceOf(alice), 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DMS.AlreadyClaimed.selector, id2, alice));
        dms.claim(id2);
    }

    function test_Claim_StillWorksAfterSweepAtUntilSwept() public {
        _toSweepTime(id);
        vm.warp(block.timestamp + 30 days);
        _assertPhase(id, DMS.Phase.ClaimsOpen);
        assertEq(_claim(id, alice), 600e6);
        dms.sweep(id);
        assertEq(usdc.balanceOf(fallbackAddr), 400e6);
    }

    function test_Claim_LastClaimantLateGetsRemainderAfterEarlierClaim() public {
        _toClaims(id);
        _claim(id, bob);
        vm.warp(block.timestamp + 100 days);
        assertEq(_claim(id, alice), 600e6);
    }

    // ------------------------------------------------------------------ claim: reverts

    function test_RevertClaim_VaultNotTriggeredActiveAndExpired() public {
        vm.prank(alice);
        vm.expectRevert(_e(DMS.VaultNotTriggered.selector, id));
        dms.claim(id);
        _toDeadline(id);
        vm.prank(alice);
        vm.expectRevert(_e(DMS.VaultNotTriggered.selector, id));
        dms.claim(id);
    }

    function test_RevertClaim_VaultNotTriggeredAfterCancel() public {
        _trigger(id);
        vm.prank(owner);
        dms.checkIn(id);
        vm.warp(block.timestamp + 5 days);
        vm.prank(alice);
        vm.expectRevert(_e(DMS.VaultNotTriggered.selector, id));
        dms.claim(id);
    }

    function test_RevertClaim_ChallengeNotOverAtChallengeEndMinusOne() public {
        _trigger(id);
        vm.warp(_v(id).challengeEnd - 1);
        vm.prank(alice);
        vm.expectRevert(_e(DMS.ChallengeNotOver.selector, id));
        dms.claim(id);
        assertEq(dms.claimable(id, alice), 0);
        vm.warp(_v(id).challengeEnd);
        assertEq(_claim(id, alice), 600e6);
    }

    function test_RevertClaim_NotBeneficiaryIncludingOwnerAndGuardian() public {
        address[5] memory bad = [owner, g1, stranger, fallbackAddr, delegate];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(bad[i]);
            vm.expectRevert(abi.encodeWithSelector(DMS.NotBeneficiary.selector, id, bad[i]));
            dms.claim(id);
        }
        _toClaims(id);
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(bad[i]);
            vm.expectRevert(abi.encodeWithSelector(DMS.NotBeneficiary.selector, id, bad[i]));
            dms.claim(id);
        }
    }

    function test_RevertClaim_AlreadyClaimed() public {
        _toClaims(id);
        _claim(id, alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DMS.AlreadyClaimed.selector, id, alice));
        dms.claim(id);
    }

    function test_RevertClaim_VaultSweptForUnclaimedAndClaimed() public {
        _toSweepTime(id);
        _claim(id, alice);
        dms.sweep(id);
        vm.prank(bob);
        vm.expectRevert(_e(DMS.VaultSwept.selector, id));
        dms.claim(id);
        vm.prank(alice);
        vm.expectRevert(_e(DMS.VaultSwept.selector, id));
        dms.claim(id);
    }

    function test_RevertClaim_VaultNotFound() public {
        vm.prank(alice);
        vm.expectRevert(_e(DMS.VaultNotFound.selector, 99));
        dms.claim(99);
    }

    function test_Claimable_ZeroOutsideWindow() public {
        assertEq(dms.claimable(id, alice), 0);
        _trigger(id);
        assertEq(dms.claimable(id, alice), 0);
        assertEq(dms.claimable(id, stranger), 0);
        vm.warp(_v(id).challengeEnd);
        assertEq(dms.claimable(id, alice), 600e6);
        assertEq(dms.claimable(id, stranger), 0);
    }
}
