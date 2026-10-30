// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeadMansSwitchVault as DMS} from "../DeadMansSwitchVault.sol";
import {MockUSDC} from "../test-helpers/MockUSDC.sol";
import {DMSHandler} from "./DeadMansSwitchVault.Handler.t.sol";

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 200
/// forge-config: default.invariant.fail_on_revert = false
contract DMSInvariantTest is Test {
    DMS internal dms;
    MockUSDC internal usdc;
    DMSHandler internal h;

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc = new MockUSDC();
        dms = new DMS(IERC20(address(usdc)));
        h = new DMSHandler(dms, usdc);
        targetContract(address(h));
    }

    // ------------------------------------------------------------------ shared checks

    function _sumFunds() internal view returns (uint256 sum) {
        uint256 count = h.vaultCount();
        for (uint256 i; i < count; ++i) {
            DMS.VaultView memory v = dms.getVault(h.vaultIds(i));
            sum += v.balance;
            if (v.finalized && !v.swept) sum += v.claimPool - v.totalClaimed;
        }
    }

    function _checkAccounting() internal view {
        assertLe(dms.totalPaidOut(), dms.totalDeposited(), "paid out <= deposited");
        assertEq(usdc.balanceOf(address(dms)), dms.totalDeposited() - dms.totalPaidOut(), "balance == in - out");
        assertEq(dms.totalDeposited(), h.ghostIn(), "ghost in");
        assertEq(dms.totalPaidOut(), h.ghostOut(), "ghost out");
    }

    function _checkSolvency() internal view {
        uint256 funds = _sumFunds();
        assertGe(usdc.balanceOf(address(dms)), funds, "token balance >= vault balances + unclaimed pools");
        assertEq(usdc.balanceOf(address(dms)), funds, "no stray funds");
    }

    function _checkPerVault() internal view {
        uint256 count = h.vaultCount();
        for (uint256 i; i < count; ++i) {
            DMS.VaultView memory v = dms.getVault(h.vaultIds(i));
            assertLe(v.totalClaimed, v.claimPool, "totalClaimed <= claimPool");
            assertLe(v.claimedCount, v.beneficiaryCount, "claimedCount <= beneficiaries");
            if (v.finalized) assertEq(v.balance, 0, "finalized => balance moved to pool");
            if (v.swept) assertTrue(v.finalized && v.triggered, "swept => finalized & triggered");
            if (!v.finalized) assertEq(v.claimPool, 0);
            if (v.triggered) assertEq(v.challengeEnd, v.triggeredAt + dms.getConfig(h.vaultIds(i)).challengeWindow);
        }
    }

    function _checkGuardians() internal view {
        assertEq(h.guardianViolations(), 0, "guardian action moved funds/accounting");
        assertEq(h.ghostGuardianOutflow(), 0, "guardian-originated outflow must be zero");
        assertEq(h.guardianTriggerFlips(), 0, "guardian cannot flip triggered (except time-gated trigger())");
        assertEq(h.triggerEarly(), 0, "trigger() must never succeed before the deadline");
        assertEq(usdc.balanceOf(h.g1()), 0);
        assertEq(usdc.balanceOf(h.g2()), 0);
        assertEq(usdc.balanceOf(h.g3()), 0);
    }

    // ------------------------------------------------------------------ invariants

    /// (i) totalPaidOut <= totalDeposited and token balance == in - out
    function invariant_AccountingConservation() public view {
        _checkAccounting();
    }

    /// (ii) solvency: token balance covers all vault balances and unclaimed pools
    function invariant_Solvency() public view {
        _checkSolvency();
    }

    /// (iii) per-vault claim bounds
    function invariant_PerVaultClaimBounds() public view {
        _checkPerVault();
    }

    /// (iv) guardians can never move funds and never trigger early
    function invariant_GuardiansCannotMoveFunds() public view {
        _checkGuardians();
    }

    function afterInvariant() public view {
        console2.log("calls", h.totalCalls());
        bytes32[12] memory keys = [
            bytes32("deposit"), "checkIn", "requestWithdraw", "executeWithdraw", "trigger", "claim",
            "sweep", "gExtend", "gCancel", "gPropose", "gExecRot", "gTrigger"
        ];
        for (uint256 i; i < keys.length; ++i) {
            console2.log(string(abi.encodePacked(keys[i])), h.okCount(keys[i]), h.failCount(keys[i]));
        }
    }

    // ------------------------------------------------------------------ (v) handler sanity

    /// Deterministic script proving that every handler action CAN succeed (ghost counters > 0)
    /// and that all invariants hold along the way.
    function test_HandlerExercisesAllPathsAndInvariantsHold() public {
        // fund the three vaults
        h.deposit(0, 1000e6);
        h.deposit(1, 500e6);
        h.deposit(2, 200e6);
        _checkAll();

        // V0: owner / delegate check-ins, delayed withdraw, cancel
        h.checkIn(0, 0);
        h.setDelegate(0, 0);
        h.checkIn(0, 3);
        h.requestWithdraw(0, 0, 100e6);
        h.warp(100);
        h.executeWithdraw(0, 0);
        h.requestWithdraw(0, 0, 10e6);
        h.cancelWithdraw(0, 0);
        _checkAll();

        // V0: guardian quorum extend / cancel / rotate (no funds move)
        h.guardianAct(0, 0, 0, 0);
        h.guardianAct(0, 1, 0, 0);
        h.requestWithdraw(0, 0, 10e6);
        h.guardianAct(0, 0, 1, 0);
        h.guardianAct(0, 1, 1, 0);
        h.guardianAct(0, 0, 2, 0);
        h.guardianAct(0, 1, 2, 0);
        h.warp(100);
        h.approveRotation(0, 1); // owner explicitly approves the pending target (rSeed 1 -> pending newOwner)
        h.guardianAct(0, 2, 3, 0);
        h.guardianAct(0, 0, 4, 0); // early trigger attempt by a guardian must fail
        _checkAll();

        // V0: expire, guardian triggers (permissionless, time-gated), claims, sweep
        h.warpToEvent(0, 0);
        h.guardianAct(0, 0, 4, 0);
        h.warpToEvent(0, 1);
        h.setPayout(0, 0, true);
        h.claim(0, 0);
        h.claim(0, 5);
        h.warpToEvent(0, 2);
        h.setFallbackPayout(0, 0, true);
        h.sweep(0, 0);
        _checkAll();

        // V1: trigger, finalize, claim, sweep
        h.warpToEvent(1, 0);
        h.trigger(1, 0);
        h.warpToEvent(1, 1);
        h.finalize(1, 0);
        h.claim(1, 0);
        h.warpToEvent(1, 2);
        h.sweep(1, 0);
        _checkAll();

        // V2: trigger, owner check-in cancels it, re-trigger, claim, sweep
        h.trigger(2, 0);
        h.checkIn(2, 0);
        h.warpToEvent(2, 0);
        h.trigger(2, 0);
        h.warpToEvent(2, 1);
        h.claim(2, 0);
        h.warpToEvent(2, 2);
        h.sweep(2, 0);
        _checkAll();

        bytes32[18] memory must = [
            bytes32("deposit"), "checkIn", "setDelegate", "requestWithdraw", "executeWithdraw",
            "cancelWithdraw", "gExtend", "gCancel", "gPropose", "gExecRot", "gTrigger", "trigger",
            "claim", "finalize", "sweep", "setPayout", "setFallback", "approveRotation"
        ];
        for (uint256 i; i < must.length; ++i) {
            assertGt(h.okCount(must[i]), 0, string(abi.encodePacked("never succeeded: ", must[i])));
        }
        assertGt(h.failCount("gTrigger"), 0, "early guardian trigger attempt was rejected");
        assertEq(h.triggerEarly(), 0);
        // the 3 vaults end Swept
        for (uint256 i; i < 3; ++i) {
            assertEq(uint8(dms.phase(h.vaultIds(i))), uint8(DMS.Phase.Swept));
        }
        assertEq(usdc.balanceOf(address(dms)), 0);
    }

    function _checkAll() internal view {
        _checkAccounting();
        _checkSolvency();
        _checkPerVault();
        _checkGuardians();
    }
}
