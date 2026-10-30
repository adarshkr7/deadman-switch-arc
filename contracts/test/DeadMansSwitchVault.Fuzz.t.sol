// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DeadMansSwitchVault as DMS} from "../DeadMansSwitchVault.sol";
import {DMSTestBase} from "./DeadMansSwitchVault.Base.t.sol";

contract DMSFuzzTest is DMSTestBase {
    uint256 internal vid;
    uint256 internal n;
    uint256 internal totalDeposited_;
    uint256 internal withdrawn;
    address[] internal bens;
    uint16[] internal shs;

    // ------------------------------------------------------------------ helpers

    function _randomShares(uint256 seed, uint256 count) internal pure returns (uint16[] memory s) {
        s = new uint16[](count);
        uint256 remaining = 10_000;
        for (uint256 i; i < count; ++i) {
            uint256 left = count - 1 - i;
            if (left == 0) {
                s[i] = uint16(remaining);
            } else {
                uint256 pick = bound(uint256(keccak256(abi.encode(seed, i))), 1, remaining - left);
                s[i] = uint16(pick);
                remaining -= pick;
            }
        }
    }

    function _perm(uint256 seed, uint256 count) internal pure returns (uint256[] memory p) {
        p = new uint256[](count);
        for (uint256 i; i < count; ++i) p[i] = i;
        for (uint256 i = count; i > 1; --i) {
            uint256 j = uint256(keccak256(abi.encode(seed, "perm", i))) % i;
            (p[i - 1], p[j]) = (p[j], p[i - 1]);
        }
    }

    function _build(uint256 seed, uint256 count) internal {
        n = count;
        uint16[] memory s = _randomShares(seed, count);
        DMS.CreateParams memory p = _params();
        p.beneficiaries = new address[](count);
        p.sharesBps = s;
        for (uint256 i; i < count; ++i) {
            p.beneficiaries[i] = address(uint160(0x5000 + i));
            bens.push(p.beneficiaries[i]);
            shs.push(s[i]);
        }
        p.guardians = new address[](0);
        p.guardianThreshold = 0;
        vid = _create(p);
    }

    function _dep(uint256 amt) internal {
        if (amt == 0) return;
        _deposit(vid, depositor, amt);
        totalDeposited_ += amt;
    }

    function _maybeWithdraw(uint256 seed) internal {
        uint256 bal = _v(vid).balance;
        uint256 amt = bound(uint256(keccak256(abi.encode(seed, "w"))), 0, bal);
        if (amt == 0) return;
        _request(vid, amt);
        vm.warp(block.timestamp + WD);
        vm.prank(owner);
        dms.executeWithdraw(vid);
        withdrawn += amt;
    }

    function _claimK(uint256[] memory order, uint256 k, uint256 pool) internal returns (uint256 sumPaid) {
        for (uint256 j; j < k; ++j) {
            uint256 idx = order[j];
            address b = bens[idx];
            uint256 before_ = usdc.balanceOf(b);
            vm.prank(b);
            dms.claim(vid);
            uint256 paid = usdc.balanceOf(b) - before_;
            if (j + 1 < n) {
                assertEq(paid, (pool * shs[idx]) / 10_000, "non-last claimant gets exactly floor(share)");
            } else {
                assertEq(paid, pool - sumPaid, "last claimant gets remainder");
            }
            sumPaid += paid;
            DMS.VaultView memory v = _v(vid);
            assertLe(v.totalClaimed, v.claimPool, "totalClaimed <= claimPool");
            assertEq(v.totalClaimed, sumPaid);
        }
    }

    // ------------------------------------------------------------------ D1: accounting

    function testFuzz_ClaimsPlusSweepEqualDepositsMinusWithdrawals(
        uint256 seed,
        uint8 nRaw,
        uint256 d1,
        uint256 d2,
        uint256 d3
    ) public {
        _build(seed, bound(nRaw, 1, 20));
        _dep(bound(d1, 0, 1e12));
        _maybeWithdraw(seed);
        _dep(bound(d2, 0, 1e12));
        _trigger(vid);
        _dep(bound(d3, 0, 1e12)); // Challenge-phase deposit is still pooled
        vm.warp(_v(vid).challengeEnd);

        uint256 pool = totalDeposited_ - withdrawn;
        uint256 k = bound(uint256(keccak256(abi.encode(seed, "k"))), 0, n);
        uint256 sumPaid = _claimK(_perm(seed, n), k, pool);

        vm.warp(_v(vid).sweepAt);
        uint256 fbBefore = usdc.balanceOf(fallbackAddr);
        dms.sweep(vid);
        uint256 swept = usdc.balanceOf(fallbackAddr) - fbBefore;

        assertEq(_v(vid).claimPool, pool);
        assertEq(sumPaid + swept, pool, "claims + sweep == deposits - withdrawals");
        assertEq(sumPaid + swept + withdrawn, totalDeposited_);
        assertEq(usdc.balanceOf(address(dms)), 0);
        assertEq(dms.totalDeposited(), totalDeposited_);
        assertEq(dms.totalPaidOut(), totalDeposited_);
        if (k == n) assertEq(swept, 0);
    }

    function testFuzz_SharesAreAlwaysValid(uint256 seed, uint8 nRaw) public {
        uint256 count = bound(nRaw, 1, 20);
        uint16[] memory s = _randomShares(seed, count);
        uint256 total;
        for (uint256 i; i < count; ++i) {
            assertGt(uint256(s[i]), 0);
            total += s[i];
        }
        assertEq(total, 10_000);
    }

    // ------------------------------------------------------------------ D2: phase function

    function testFuzz_PhaseMatchesModelAcrossTimestamps(uint256 a, uint256 b, uint256 c, bool doCheckIn) public {
        uint256 id = createDefaultVault();
        uint256 dl = T0 + INTERVAL;

        // step 1: arbitrary time within [0, 2*INTERVAL]
        uint256 t1 = T0 + bound(a, 0, 2 * uint256(INTERVAL));
        vm.warp(t1);
        _assertPhase(id, t1 < dl ? DMS.Phase.Active : DMS.Phase.Expired);
        assertEq(dms.isExpired(id), t1 >= dl);

        if (t1 < dl && doCheckIn) {
            vm.prank(owner);
            dms.checkIn(id);
            dl = t1 + INTERVAL;
            assertEq(dms.deadline(id), dl);
            _assertPhase(id, DMS.Phase.Active);
        }

        // step 2: go to the (possibly late) trigger time and trigger
        uint256 tt = (t1 > dl ? t1 : dl) + bound(b, 0, 10 days);
        vm.warp(tt);
        _assertPhase(id, DMS.Phase.Expired);
        dms.trigger(id);

        // step 3: arbitrary time after trigger
        uint256 challengeEnd = tt + CW;
        uint256 sweepAt = challengeEnd + SP;
        uint256 t3 = tt + bound(c, 0, uint256(CW) + SP + 30 days);
        vm.warp(t3);
        DMS.Phase expected = t3 < challengeEnd ? DMS.Phase.Challenge : DMS.Phase.ClaimsOpen;
        _assertPhase(id, expected);
        if (t3 >= sweepAt) {
            dms.sweep(id);
            _assertPhase(id, DMS.Phase.Swept);
            vm.warp(t3 + 1 days);
            _assertPhase(id, DMS.Phase.Swept);
        } else {
            vm.expectRevert(_e(DMS.SweepNotReady.selector, id));
            dms.sweep(id);
        }
    }

    function testFuzz_PhaseIsMonotonicWithoutOwnerActions(uint256 a, uint256 b, uint256 c) public {
        uint256 id = createDefaultVault();
        uint8 last;
        uint256 t = T0;
        uint256[3] memory steps = [a, b, c];
        for (uint256 i; i < 3; ++i) {
            t += bound(steps[i], 0, 120 days);
            vm.warp(t);
            // anyone may trigger once expired; phase must never go backwards
            if (block.timestamp >= dms.deadline(id) && !_v(id).triggered) dms.trigger(id);
            uint8 ph = uint8(dms.phase(id));
            assertGe(uint256(ph), uint256(last));
            last = ph;
        }
    }

    // ------------------------------------------------------------------ D3: withdrawals

    function testFuzz_WithdrawNeverExceedsBalance(uint256 deposit1, uint256 w1, uint256 w2) public {
        deposit1 = bound(deposit1, 1, 1e15);
        uint256 id = _funded(deposit1);
        uint256[2] memory ws = [bound(w1, 0, deposit1 * 2), bound(w2, 0, deposit1 * 2)];
        for (uint256 i; i < 2; ++i) {
            uint256 bal = _v(id).balance;
            uint256 w = ws[i];
            if (w == 0) {
                vm.prank(owner);
                vm.expectRevert(DMS.ZeroAmount.selector);
                dms.requestWithdraw(id, 0);
            } else if (w > bal) {
                vm.prank(owner);
                vm.expectRevert(abi.encodeWithSelector(DMS.InsufficientVaultBalance.selector, bal, w));
                dms.requestWithdraw(id, w);
            } else {
                _request(id, w);
                vm.warp(block.timestamp + WD);
                vm.prank(owner);
                dms.executeWithdraw(id);
                assertEq(_v(id).balance, bal - w);
            }
            assertLe(usdc.balanceOf(owner), deposit1);
            assertEq(usdc.balanceOf(owner) + _v(id).balance, deposit1);
            assertEq(usdc.balanceOf(address(dms)), _v(id).balance);
        }
    }

    // ------------------------------------------------------------------ extension bounds

    function testFuzz_ExtendDeadlineLegalRangeExact(uint64 nd, uint32 elapsed) public {
        DMS.CreateParams memory p = _params();
        p.guardians = new address[](1);
        p.guardians[0] = g1;
        p.guardianThreshold = 1;
        uint256 id = _create(p);
        vm.warp(T0 + bound(elapsed, 0, 3 * uint256(INTERVAL)));
        uint256 dl = dms.deadline(id);
        nd = uint64(bound(nd, T0, T0 + 5 * uint256(INTERVAL)));
        bool passed = block.timestamp >= dl; // DeadlinePassed precedes the range check
        bool legal = !passed && nd > dl && nd > block.timestamp && uint256(nd) <= block.timestamp + INTERVAL;
        vm.prank(g1);
        if (passed) vm.expectRevert(_e(DMS.DeadlinePassed.selector, id));
        else if (!legal) vm.expectRevert(_e(DMS.ExtensionTooLarge.selector, id));
        dms.extendDeadline(id, nd);
        if (legal) assertEq(dms.deadline(id), nd);
        else assertEq(dms.deadline(id), dl);
    }
}
