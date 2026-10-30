// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeadMansSwitchVault as DMS} from "../DeadMansSwitchVault.sol";
import {MockUSDC} from "../test-helpers/MockUSDC.sol";
import {DeadOwnerHandler} from "./DeadMansSwitchVault.DeadOwnerHandler.t.sol";

/// @dev Shared "dead owner" invariants. Concrete contracts choose the clock policy.
abstract contract DeadOwnerInvariantBase is Test {
    DMS internal dms;
    MockUSDC internal usdc;
    DeadOwnerHandler internal h;

    function _strict() internal pure virtual returns (bool);

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc = new MockUSDC();
        dms = new DMS(IERC20(address(usdc)));
        h = new DeadOwnerHandler(dms, usdc, _strict());

        bytes4[] memory s = new bytes4[](24);
        s[0] = h.warp.selector;
        s[1] = h.warpToEvent.selector;
        s[2] = h.deposit.selector;
        s[3] = h.checkIn.selector;
        s[4] = h.setDelegate.selector;
        s[5] = h.requestWithdraw.selector;
        s[6] = h.executeWithdraw.selector;
        s[7] = h.cancelWithdraw.selector;
        s[8] = h.executeRotation.selector;
        s[9] = h.cancelRotation.selector;
        s[10] = h.extend.selector;
        s[11] = h.extendQuorum.selector;
        s[12] = h.proposeRotation.selector;
        s[13] = h.proposeQuorum.selector;
        s[14] = h.spawnAttacker.selector;
        s[15] = h.trigger.selector;
        s[16] = h.finalize.selector;
        s[17] = h.setPayout.selector;
        s[18] = h.setFallbackPayout.selector;
        s[19] = h.claim.selector;
        s[20] = h.sweep.selector;
        s[21] = h.delegateCheckIn.selector;
        s[22] = h.delegateOverreach.selector;
        s[23] = h.approveRotation.selector;
        targetContract(address(h));
        targetSelector(FuzzSelector({addr: address(h), selectors: s}));
    }

    // ------------------------------------------------------------------ helpers

    function _sumFunds() internal view returns (uint256 sum) {
        for (uint256 i; i < h.vaultCount(); ++i) {
            DMS.VaultView memory v = dms.getVault(h.vaultIds(i));
            sum += v.balance;
            if (v.finalized && !v.swept) sum += v.claimPool - v.totalClaimed;
        }
    }

    function _checkAll() internal view {
        invariant_NoAttackerGuardianOrStrangerEverGains();
        invariant_OutflowIsOnlyClaimsAndSweepsToAllowedRecipients();
        invariant_OwnerNeverChangesAndNoOwnerActions();
        invariant_AtMostOneExtensionPerPeriodAndDeadlineBound();
        invariant_AccountingAndSolvency();
    }

    // ------------------------------------------------------------------ invariants

    /// (1) No attacker / guardian / stranger / owner address ever holds more USDC than it started with.
    function invariant_NoAttackerGuardianOrStrangerEverGains() public view {
        for (uint256 i; i < h.monitoredCount(); ++i) {
            address m = h.monitored(i);
            assertLe(usdc.balanceOf(m), h.startBal(m), "monitored address gained USDC");
            assertLe(h.maxBal(m), h.startBal(m), "monitored address gained USDC at some point");
        }
    }

    /// (2) Everything that left the contract was a Claimed/Swept payout to an allowed recipient.
    function invariant_OutflowIsOnlyClaimsAndSweepsToAllowedRecipients() public view {
        assertEq(h.illegalOut(), 0, "outflow from a non-claim, non-sweep action");
        assertEq(h.badRecipient(), 0, "payout to a recipient outside the allowed set");
        assertEq(h.unexpectedSuccess(), 0, "an owner-only / dead-owner-impossible call succeeded");
        assertEq(dms.totalPaidOut(), h.ghostClaimed() + h.ghostSwept(), "paid == claimed + swept");
        assertEq(dms.totalPaidOut(), h.ghostOut(), "paid == observed outflow");
        assertEq(dms.totalDeposited(), h.ghostIn(), "deposited == observed inflow");
        uint256 allowedSum;
        for (uint256 i; i < h.allowedCount(); ++i) allowedSum += usdc.balanceOf(h.allowedList(i));
        assertEq(allowedSum, dms.totalPaidOut(), "all paid-out USDC sits with allowed recipients");
    }

    /// (3) Dead owner: the owner never changes, the delegate stays the creation-time one, only the delegate's
    ///     own check-ins ever move lastCheckIn, and no withdrawal can ever exist or execute.
    function invariant_OwnerNeverChangesAndNoOwnerActions() public view {
        for (uint256 i; i < h.vaultCount(); ++i) {
            uint256 id = h.vaultIds(i);
            DMS.VaultView memory v = dms.getVault(id);
            assertEq(v.owner, h.originalOwner(id), "owner changed");
            assertEq(v.checkInDelegate, h.dlg(), "delegate changed");
            assertEq(uint256(v.lastCheckIn), h.ghostLastCheckIn(id), "check-in by someone other than the delegate");
            assertFalse(dms.getPendingWithdrawal(id).exists, "withdrawal exists");
        }
        assertEq(h.triggerEarly(), 0, "trigger succeeded before the deadline");
        assertEq(h.unexpectedSuccess(), 0, "executeOwnerRotation / approve / owner-only call succeeded");
    }

    /// (4) Restated PER CHECK-IN PERIOD (the delegate checks in): at most one executed extension since the last
    ///     check-in; deadline <= lastCheckIn + 2*interval and <= now + interval at ALL times (both clock policies,
    ///     since guardians can no longer extend an expired vault); the deadline is never shortened.
    function invariant_AtMostOneExtensionPerPeriodAndDeadlineBound() public view {
        for (uint256 i; i < h.vaultCount(); ++i) {
            uint256 id = h.vaultIds(i);
            DMS.VaultView memory v = dms.getVault(id);
            assertLe(h.extThisPeriod(id), 1, "more than one executed extension since the last check-in");
            assertLe(h.maxExtPeriod(id), 1, "more than one extension in some check-in period");
            assertEq(v.extensionUsed, h.extThisPeriod(id) == 1, "extensionUsed flag mismatch");
            assertLe(uint256(v.deadline), uint256(v.lastCheckIn) + 2 * uint256(v.interval), "deadline > lastCheckIn + 2*interval");
            assertLe(uint256(v.deadline), block.timestamp + uint256(v.interval), "deadline > now + interval");
            assertGe(uint256(v.deadline), uint256(v.lastCheckIn) + uint256(v.interval), "deadline shortened");
        }
    }

    /// (6) totalPaidOut <= totalDeposited; token balance == in - out and covers every vault + unclaimed pool.
    function invariant_AccountingAndSolvency() public view {
        assertLe(dms.totalPaidOut(), dms.totalDeposited());
        assertEq(usdc.balanceOf(address(dms)), dms.totalDeposited() - dms.totalPaidOut());
        assertEq(usdc.balanceOf(address(dms)), _sumFunds(), "no stray funds / fully backed");
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 200
/// forge-config: default.invariant.fail_on_revert = false
contract DeadOwnerStrictClockInvariantTest is DeadOwnerInvariantBase {
    function _strict() internal pure override returns (bool) {
        return true;
    }

    /// Deterministic script proving each guardian-collusion / payout path CAN succeed in the campaign
    /// (success counters > 0) while every invariant holds along the way.
    function test_Script_HandlerExercisesAllPathsAndInvariantsHold() public {
        h.deposit(0, 1000e6);
        h.deposit(1, 500e6);
        h.deposit(2, 200e6);
        _checkAll();

        // colluding guardians queue rotations to fresh attackers on every vault; nobody can execute / veto them
        h.proposeQuorum(0, 1);
        h.proposeQuorum(1, 1);
        h.proposeQuorum(2, 1);
        h.executeRotation(0, 3);
        h.executeRotation(1, 8);
        h.cancelRotation(0, 8); // att1 is a non-vetoer
        h.checkIn(0, 8);
        h.setDelegate(0, 8, 5);
        h.requestWithdraw(0, 8, 1e6);
        h.executeWithdraw(0, 8);
        h.cancelWithdraw(0, 0); // guardian, nothing pending
        // the delegate (set at creation) checks in; it can do nothing else. Nobody else can approve a rotation.
        h.delegateCheckIn(0);
        h.delegateCheckIn(1);
        h.delegateOverreach(0, 0, 0);
        h.delegateOverreach(0, 1, 1);
        h.delegateOverreach(0, 2, 0);
        h.approveRotation(0, 4, 0); // caller = the pending newOwner itself
        h.approveRotation(0, 8, 1); // caller = attacker
        _checkAll();

        // each vault: one quorum extension succeeds, the second is rejected
        h.warp(100);
        h.executeRotation(0, 8); // timelock passed, but never approved -> RotationNotApproved
        h.executeRotation(1, 8);
        h.extendQuorum(0, 0);
        h.extendQuorum(1, 0);
        h.extendQuorum(2, 0);
        h.extendQuorum(0, 2);
        h.extend(0, 2, 7);
        _checkAll();

        // V0: a delegate check-in starts a NEW check-in period, so exactly one more extension is possible
        h.delegateCheckIn(0);
        h.warp(51);
        h.extendQuorum(0, 0);
        h.extendQuorum(0, 2); // second extension in the same period is rejected
        _checkAll();

        // V2 (single beneficiary): trigger, claim, sweep
        h.warpToEvent(2, 0);
        h.trigger(2, 8);
        h.warpToEvent(2, 1);
        h.claim(2, 1);
        h.warpToEvent(2, 2);
        h.sweep(2, 0);
        _checkAll();

        // V0: trigger, payout routing, three claims
        h.warpToEvent(0, 0);
        h.trigger(0, 8);
        h.warpToEvent(0, 1);
        h.finalize(0, 8);
        h.setPayout(0, 1, 0);
        h.setPayout(0, 24, 0); // aSeed 24 -> att1 (non-beneficiary) redirect attempt fails
        h.setFallbackPayout(0, 1, 0);
        h.claim(0, 1);
        h.claim(0, 4);
        h.claim(0, 7);
        _checkAll();

        // V1: unclaimed funds are swept to the fallback destination only
        h.warpToEvent(1, 0);
        h.trigger(1, 8);
        h.warpToEvent(1, 2);
        h.setFallbackPayout(1, 1, 1);
        h.sweep(1, 8);
        _checkAll();

        bytes32[14] memory must = [
            bytes32("deposit"), "quorum", "extendExecuted", "extend", "trigger", "finalize",
            "claim", "sweep", "setPayout", "setFallback", "propose", "delegateCheckIn", "execNotApproved", "warp"
        ];
        for (uint256 i; i < must.length; ++i) {
            assertGt(h.okCount(must[i]), 0, string(abi.encodePacked("never succeeded: ", must[i])));
        }
        bytes32[11] memory mustFail = [
            bytes32("checkIn"), "setDelegate", "requestWithdraw", "executeWithdraw", "cancelWithdraw",
            "executeRotation", "cancelRotation", "extend", "setPayout", "approveRotation", "delegateOverreach"
        ];
        for (uint256 i; i < mustFail.length; ++i) {
            assertGt(h.failCount(mustFail[i]), 0, string(abi.encodePacked("never rejected: ", mustFail[i])));
        }
        assertEq(h.okCount("extendExecuted"), 4, "one extension per vault + one more for V0 after the delegate check-in");
        assertEq(h.maxExtPeriod(h.vaultIds(0)), 1, "never more than one extension per check-in period");
        assertEq(h.extExecuted(h.vaultIds(0)), 2);
        assertEq(h.ghostClaimed(), 1200e6);
        assertEq(h.ghostSwept(), 500e6);
        assertEq(dms.totalPaidOut(), 1700e6);
        assertEq(usdc.balanceOf(address(dms)), 0, "contract ends at zero");
        assertEq(usdc.balanceOf(h.fbDest2()), 500e6);
        assertEq(usdc.balanceOf(h.g1()) + usdc.balanceOf(h.g2()) + usdc.balanceOf(h.g3()), 0);
        for (uint256 i; i < 3; ++i) {
            assertEq(uint8(dms.phase(h.vaultIds(i))), i == 0 ? uint8(DMS.Phase.ClaimsOpen) : uint8(DMS.Phase.Swept));
        }
    }

    /// Scripted companion: the delegate keeps V0 alive across several check-in periods (one guardian extension per
    /// period, a pending rotation that is never approved), then STOPS. The vault must then be triggerable no later
    /// than lastCheckIn + 2*interval, and every payout path must still work.
    function test_Script_DelegateStopsCheckingIn_TriggerableByLastCheckInPlus2Interval() public {
        h.deposit(0, 900e6);
        uint256 id = h.vaultIds(0);
        uint256 interval = 300;
        h.proposeQuorum(0, 1); // quorum-queued rotation to a fresh attacker target; nobody approves it
        assertTrue(dms.getPendingRotation(id).exists);
        assertFalse(dms.getPendingRotation(id).approved);

        for (uint256 r; r < 4; ++r) {
            uint256 last = h.ghostLastCheckIn(id);
            vm.warp(last + 101);
            h.extendQuorum(0, 0); // the period's single extension executes...
            h.extendQuorum(0, 2); // ...a second one is rejected
            assertEq(dms.deadline(id), last + 101 + interval);
            assertLe(dms.deadline(id), last + 2 * interval);
            h.executeRotation(0, 8); // timelock long passed, but never approved
            h.approveRotation(0, 4, 0); // the pending newOwner itself cannot approve
            assertFalse(dms.getPendingRotation(id).approved);
            vm.warp(last + 252);
            h.delegateCheckIn(0); // routine check-in only
            assertEq(uint256(_vv(id).lastCheckIn), block.timestamp);
            assertFalse(_vv(id).extensionUsed, "check-in starts a new period");
            _checkAll();
        }
        assertEq(h.extExecuted(id), 4);
        assertEq(h.maxExtPeriod(id), 1);

        // the delegate stops. Last period: extend as late as possible.
        uint256 L = h.ghostLastCheckIn(id);
        vm.warp(L + 299);
        h.extendQuorum(0, 0);
        assertEq(dms.deadline(id), L + 299 + interval);
        assertLe(dms.deadline(id), L + 2 * interval, "deadline <= lastCheckIn + 2*interval");
        assertEq(h.extExecuted(id), 5);

        vm.warp(L + 2 * interval - 2);
        h.trigger(0, 8);
        assertFalse(_vv(id).triggered, "not yet expired");
        vm.warp(L + 2 * interval - 1);
        h.extendQuorum(0, 0); // expired: guardians cannot extend (DeadlinePassed)
        assertEq(dms.deadline(id), L + 299 + interval);
        h.executeRotation(0, 8); // still unapproved
        h.trigger(0, 8);
        assertTrue(_vv(id).triggered, "triggerable by lastCheckIn + 2*interval");
        assertLe(block.timestamp, L + 2 * interval);
        _checkAll();

        // challenge passes with no delegate check-in; claims and sweep pay only allowed recipients
        vm.warp(_vv(id).challengeEnd);
        h.executeRotation(0, 3); // triggered: VaultAlreadyTriggered
        h.finalize(0, 8);
        h.claim(0, 1);
        h.claim(0, 4);
        vm.warp(_vv(id).sweepAt);
        h.sweep(0, 8);
        _checkAll();

        assertEq(h.ghostClaimed(), 2 * Math.mulDiv(900e6, 3333, 10_000));
        assertEq(h.ghostSwept(), 900e6 - h.ghostClaimed());
        assertEq(usdc.balanceOf(h.fb()), h.ghostSwept());
        assertEq(usdc.balanceOf(address(dms)), 0);
        assertEq(_vv(id).owner, h.ownerA());
        assertEq(usdc.balanceOf(h.g1()) + usdc.balanceOf(h.g2()) + usdc.balanceOf(h.g3()), 0);
        assertEq(usdc.balanceOf(h.att1()) + usdc.balanceOf(h.att2()) + usdc.balanceOf(h.att3()), 0);
        bytes32[8] memory must = [
            bytes32("quorum"), "extendExecuted", "extend", "delegateCheckIn", "trigger", "claim", "sweep",
            "execNotApproved"
        ];
        for (uint256 i; i < must.length; ++i) {
            assertGt(h.okCount(must[i]), 0, string(abi.encodePacked("never succeeded: ", must[i])));
        }
        assertGe(h.okCount("delegateCheckIn"), 4);
    }

    /// The delegate may rescue a triggered vault inside the challenge window (a check-in), after which the
    /// allowance is fresh; once it stops, the vault is triggerable by the new lastCheckIn + 2*interval.
    function test_Script_DelegateRescueInChallengeWindowThenStops() public {
        h.deposit(0, 100e6);
        uint256 id = h.vaultIds(0);
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 300);
        h.trigger(0, 8);
        assertTrue(_vv(id).triggered);
        h.delegateCheckIn(0);
        assertFalse(_vv(id).triggered, "rescued");
        assertEq(h.okCount("delegateRescue"), 1);
        assertEq(dms.deadline(id), t0 + 600);
        vm.warp(t0 + 400);
        h.extendQuorum(0, 0); // allowance is fresh after the rescue
        assertEq(h.maxExtPeriod(id), 1);
        assertLe(dms.deadline(id), t0 + 300 + 2 * 300);
        _checkAll();
        vm.warp(dms.deadline(id));
        h.trigger(0, 8);
        assertTrue(_vv(id).triggered);
        assertLe(block.timestamp, t0 + 300 + 2 * 300);
        vm.warp(_vv(id).challengeEnd);
        h.claim(0, 1);
        h.claim(0, 4);
        h.claim(0, 7);
        _checkAll();
        assertEq(h.ghostClaimed(), 100e6);
    }

    function _vv(uint256 id) internal view returns (DMS.VaultView memory) {
        return dms.getVault(id);
    }
}

/// Free clock: time may skip past an untriggered deadline. The per-check-in-period extension bound and
/// deadline <= lastCheckIn + 2*interval hold universally (guardians cannot extend an expired vault).
/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 200
/// forge-config: default.invariant.fail_on_revert = false
contract DeadOwnerFreeClockInvariantTest is DeadOwnerInvariantBase {
    function _strict() internal pure override returns (bool) {
        return false;
    }
}
