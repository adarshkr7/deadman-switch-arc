// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DeadMansSwitchVault as DMS} from "../DeadMansSwitchVault.sol";
import {DMSTestBase} from "./DeadMansSwitchVault.Base.t.sol";

/// @dev Dead-owner liveness: no sequence of guardian actions can keep a vault from being triggered.
contract DMSDeadOwnerLivenessTest is DMSTestBase {
    address internal attacker = makeAddr("livenessAttacker");

    /// @dev Every guardian tries every action it has; none of them may succeed except the single extension.
    function _barrage(uint256 id) internal {
        address[3] memory gs = [g1, g2, g3];
        for (uint256 i; i < gs.length; ++i) {
            address g = gs[i];
            DMS.VaultView memory v = _v(id);
            uint256 lo = v.deadline > block.timestamp ? v.deadline : block.timestamp;
            vm.prank(g);
            try dms.extendDeadline(id, uint64(block.timestamp + v.interval)) {} catch {}
            vm.prank(g);
            try dms.extendDeadline(id, uint64(lo + 1)) {} catch {}
            vm.prank(g);
            try dms.proposeOwnerRotation(id, attacker) {} catch {}
            vm.prank(g);
            try dms.executeOwnerRotation(id) {
                assertTrue(false, "rotation executed for a dead owner");
            } catch {}
            vm.prank(g);
            try dms.cancelWithdraw(id) {} catch {}
            vm.prank(g);
            try dms.checkIn(id) {
                assertTrue(false, "guardian checked in");
            } catch {}
            vm.prank(g);
            try dms.setCheckInDelegate(id, g) {
                assertTrue(false, "guardian set delegate");
            } catch {}
            vm.prank(g);
            try dms.requestWithdraw(id, 1) {
                assertTrue(false, "guardian requested withdrawal");
            } catch {}
        }
        // attacker as the (never-executed) rotation target is equally powerless
        vm.startPrank(attacker);
        try dms.executeOwnerRotation(id) {
            assertTrue(false, "attacker became owner");
        } catch {}
        try dms.requestWithdraw(id, 1) {
            assertTrue(false, "attacker requested withdrawal");
        } catch {}
        vm.stopPrank();
    }

    function testFuzz_GuardiansCannotKeepDeadOwnerVaultFromTriggering(uint256 seed, uint64 intervalRaw, uint8 thrRaw)
        public
    {
        uint64 interval = uint64(bound(intervalRaw, 60, 365 days));
        DMS.CreateParams memory p = _params();
        p.interval = interval;
        p.guardianThreshold = uint8(bound(thrRaw, 1, 3));
        uint256 id = _create(p);
        _deposit(id, depositor, DEP);
        uint256 created = block.timestamp;

        uint256 deadlineChanges;
        uint256 lastDeadline = dms.deadline(id);
        bool triggered;
        for (uint256 round; round < 100 && !triggered; ++round) {
            uint256 step = bound(uint256(keccak256(abi.encode(seed, round))), interval / 16 + 1, interval / 4 + 1);
            uint256 target = block.timestamp + step;
            uint256 dl = dms.deadline(id);
            if (target > dl) target = dl; // a watcher is always present: time never skips an untriggered deadline
            if (target > block.timestamp) vm.warp(target);

            _barrage(id);
            if (dms.deadline(id) != lastDeadline) {
                deadlineChanges++;
                lastDeadline = dms.deadline(id);
            }
            vm.prank(stranger);
            try dms.trigger(id) {
                triggered = true;
            } catch {}
        }
        assertTrue(triggered, "vault could not be triggered");
        assertLe(deadlineChanges, 1, "at most one executed extension");
        assertLe(block.timestamp, created + 2 * uint256(interval), "triggered no later than creation + 2*interval");
        assertLe(dms.deadline(id), created + 2 * uint256(interval));
        DMS.VaultView memory v = _v(id);
        assertEq(v.owner, owner);
        assertEq(uint256(v.lastCheckIn), created);
        assertTrue(v.triggered);

        // the funds then only reach beneficiaries
        vm.warp(v.challengeEnd);
        vm.prank(alice);
        dms.claim(id);
        vm.prank(bob);
        dms.claim(id);
        assertEq(usdc.balanceOf(alice) + usdc.balanceOf(bob), DEP);
        assertEq(usdc.balanceOf(g1) + usdc.balanceOf(g2) + usdc.balanceOf(g3) + usdc.balanceOf(attacker), 0);
    }

    /// @dev REWRITTEN (was test_LateRescueOfLongExpiredVaultIsStillSingleAndBounded, where guardians rescued a
    ///      long-expired vault past creation+2*interval). Now a late rescue is impossible: the deadline stays at
    ///      creation+interval, the vault is triggerable at once, and the bound holds universally.
    function test_LateRescueOfLongExpiredVaultIsImpossible() public {
        uint256 id = _funded(DEP);
        uint256 created = block.timestamp;
        vm.warp(created + 5 * uint256(INTERVAL)); // expired for 4 intervals, nobody triggered
        address[3] memory gs = [g1, g2, g3];
        for (uint256 i; i < gs.length; ++i) {
            vm.prank(gs[i]);
            vm.expectRevert(_e(DMS.DeadlinePassed.selector, id));
            dms.extendDeadline(id, uint64(block.timestamp + INTERVAL));
        }
        assertEq(dms.deadline(id), created + INTERVAL, "deadline unchanged");
        assertFalse(_v(id).extensionUsed);
        vm.prank(stranger);
        dms.trigger(id);
        assertTrue(_v(id).triggered);
        assertLe(dms.deadline(id), created + 2 * uint256(INTERVAL));
    }

    function test_PromptTriggerAtFirstDeadlinePreventsAnyRescue() public {
        uint256 id = _funded(DEP);
        _toDeadline(id);
        vm.prank(stranger);
        dms.trigger(id); // someone is watching: guardians never get the chance to rescue
        vm.prank(g1);
        vm.expectRevert(_e(DMS.VaultAlreadyTriggered.selector, id));
        dms.extendDeadline(id, uint64(block.timestamp + INTERVAL));
        assertEq(_v(id).deadline, T0 + INTERVAL);
    }
}
