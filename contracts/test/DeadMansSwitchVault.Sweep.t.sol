// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DeadMansSwitchVault as DMS} from "../DeadMansSwitchVault.sol";
import {DMSTestBase} from "./DeadMansSwitchVault.Base.t.sol";

/// @dev sweep and setFallbackPayout.
contract DMSSweepTest is DMSTestBase {
    uint256 internal id;

    function setUp() public override {
        super.setUp();
        id = _funded(DEP);
    }

    // ------------------------------------------------------------------ sweep

    function test_RevertSweep_NotTriggered() public {
        vm.expectRevert(_e(DMS.SweepNotReady.selector, id));
        dms.sweep(id);
        vm.warp(T0 + INTERVAL + SP + 365 days);
        vm.expectRevert(_e(DMS.SweepNotReady.selector, id));
        dms.sweep(id);
    }

    function test_RevertSweep_NotReadyAtSweepAtMinusOne() public {
        _trigger(id);
        vm.warp(_v(id).sweepAt - 1);
        vm.expectRevert(_e(DMS.SweepNotReady.selector, id));
        dms.sweep(id);
    }

    function test_Sweep_AtSweepAtByAnyoneSendsAllToFallback() public {
        _toSweepTime(id);
        uint256 sweepAt = block.timestamp;
        vm.expectEmit(true, false, false, true, address(dms));
        emit DMS.Finalized(id, DEP);
        vm.expectEmit(true, true, true, true, address(dms));
        emit DMS.Swept(id, stranger, fallbackAddr, DEP);
        vm.prank(stranger);
        dms.sweep(id);
        assertEq(usdc.balanceOf(fallbackAddr), DEP);
        assertEq(usdc.balanceOf(address(dms)), 0);
        assertEq(dms.totalPaidOut(), DEP);
        DMS.VaultView memory v = _v(id);
        assertTrue(v.swept);
        assertTrue(v.finalized);
        assertEq(block.timestamp, sweepAt);
        _assertPhase(id, DMS.Phase.Swept);
    }

    function test_Sweep_OnlyUnclaimedRemainderGoesToFallback() public {
        _toClaims(id);
        vm.prank(alice);
        dms.claim(id);
        vm.warp(_v(id).sweepAt);
        vm.expectEmit(true, true, true, true, address(dms));
        emit DMS.Swept(id, owner, fallbackAddr, 400e6);
        vm.prank(owner);
        dms.sweep(id);
        assertEq(usdc.balanceOf(alice), 600e6);
        assertEq(usdc.balanceOf(bob), 0);
        assertEq(usdc.balanceOf(fallbackAddr), 400e6);
        assertEq(dms.totalPaidOut(), DEP);
    }

    function test_Sweep_ZeroAmountAfterAllClaimed() public {
        _toClaims(id);
        vm.prank(alice);
        dms.claim(id);
        vm.prank(bob);
        dms.claim(id);
        vm.warp(_v(id).sweepAt);
        vm.expectEmit(true, true, true, true, address(dms));
        emit DMS.Swept(id, stranger, fallbackAddr, 0);
        vm.prank(stranger);
        dms.sweep(id);
        assertEq(usdc.balanceOf(fallbackAddr), 0);
        _assertPhase(id, DMS.Phase.Swept);
    }

    function test_Sweep_ZeroAmountEmptyVault() public {
        uint256 id2 = createDefaultVault();
        _toSweepTime(id2);
        vm.expectEmit(true, true, true, true, address(dms));
        emit DMS.Swept(id2, stranger, fallbackAddr, 0);
        vm.prank(stranger);
        dms.sweep(id2);
        assertTrue(_v(id2).swept);
        assertEq(usdc.balanceOf(fallbackAddr), 0);
    }

    function test_RevertSweep_AlreadySwept() public {
        _toSweepTime(id);
        dms.sweep(id);
        vm.expectRevert(_e(DMS.AlreadySwept.selector, id));
        dms.sweep(id);
    }

    function test_Sweep_RoutesToFallbackPayoutAfterSet() public {
        vm.prank(fallbackAddr);
        dms.setFallbackPayout(id, payoutAddr);
        _toSweepTime(id);
        vm.expectEmit(true, true, true, true, address(dms));
        emit DMS.Swept(id, stranger, payoutAddr, DEP);
        vm.prank(stranger);
        dms.sweep(id);
        assertEq(usdc.balanceOf(payoutAddr), DEP);
        assertEq(usdc.balanceOf(fallbackAddr), 0);
    }

    function test_Sweep_ClaimAfterSweepReverts() public {
        _toSweepTime(id);
        dms.sweep(id);
        vm.prank(alice);
        vm.expectRevert(_e(DMS.VaultSwept.selector, id));
        dms.claim(id);
    }

    function test_Sweep_DoesNotAffectOtherVaults() public {
        uint256 id2 = _funded(7e6);
        _toSweepTime(id);
        dms.sweep(id);
        assertEq(_v(id2).balance, 7e6);
        assertFalse(_v(id2).swept);
        assertEq(usdc.balanceOf(address(dms)), 7e6);
    }

    function test_RevertSweep_VaultNotFound() public {
        vm.expectRevert(_e(DMS.VaultNotFound.selector, 99));
        dms.sweep(99);
    }

    // ------------------------------------------------------------------ setFallbackPayout

    function test_SetFallbackPayout_StoresAndEmits() public {
        assertEq(dms.fallbackPayoutOf(id), fallbackAddr);
        vm.expectEmit(true, false, false, true, address(dms));
        emit DMS.FallbackPayoutSet(id, payoutAddr);
        vm.prank(fallbackAddr);
        dms.setFallbackPayout(id, payoutAddr);
        assertEq(dms.fallbackPayoutOf(id), payoutAddr);
        assertEq(dms.getConfig(id).fallbackAddress, fallbackAddr, "identity immutable");
    }

    function test_SetFallbackPayout_ZeroResetsToFallback() public {
        vm.startPrank(fallbackAddr);
        dms.setFallbackPayout(id, payoutAddr);
        dms.setFallbackPayout(id, address(0));
        vm.stopPrank();
        assertEq(dms.fallbackPayoutOf(id), fallbackAddr);
    }

    function test_SetFallbackPayout_AllowedInChallengeAndClaimsOpen() public {
        _trigger(id);
        vm.prank(fallbackAddr);
        dms.setFallbackPayout(id, payoutAddr);
        vm.warp(_v(id).challengeEnd);
        vm.prank(fallbackAddr);
        dms.setFallbackPayout(id, stranger);
        assertEq(dms.fallbackPayoutOf(id), stranger);
    }

    function test_RevertSetFallbackPayout_NotFallback() public {
        address[4] memory bad = [stranger, owner, g1, alice];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(bad[i]);
            vm.expectRevert(_e(DMS.NotFallback.selector, id));
            dms.setFallbackPayout(id, payoutAddr);
        }
    }

    function test_RevertSetFallbackPayout_AfterSwept() public {
        _toSweepTime(id);
        dms.sweep(id);
        vm.prank(fallbackAddr);
        vm.expectRevert(_e(DMS.VaultSwept.selector, id));
        dms.setFallbackPayout(id, payoutAddr);
    }

    function test_RevertSetFallbackPayout_ContractAddress() public {
        vm.prank(fallbackAddr);
        vm.expectRevert(DMS.InvalidPayoutAddress.selector);
        dms.setFallbackPayout(id, address(dms));
    }

    function test_RevertSetFallbackPayout_VaultNotFound() public {
        vm.prank(fallbackAddr);
        vm.expectRevert(_e(DMS.VaultNotFound.selector, 99));
        dms.setFallbackPayout(99, payoutAddr);
    }
}
