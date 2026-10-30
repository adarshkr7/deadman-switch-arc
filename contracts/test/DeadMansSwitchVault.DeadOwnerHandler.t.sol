// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DeadMansSwitchVault as DMS} from "../DeadMansSwitchVault.sol";
import {MockUSDC} from "../test-helpers/MockUSDC.sol";
import {DeadOwnerHandlerBase} from "./DeadMansSwitchVault.DeadOwnerBase.t.sol";

/// @dev Action surface of the "dead owner" campaign (state, plumbing, clock and constructor live in the base).
contract DeadOwnerHandler is DeadOwnerHandlerBase {
    constructor(DMS dms_, MockUSDC usdc_, bool strict_) DeadOwnerHandlerBase(dms_, usdc_, strict_) {}


    function deposit(uint256 vSeed, uint256 amt) external track(false) {
        uint256 id = _vid(vSeed);
        amt = bound(amt, 1, 1e9);
        usdc.mint(depositor, amt);
        vm.prank(depositor);
        usdc.approve(address(dms), amt);
        vm.prank(depositor);
        try dms.deposit(id, amt) {
            _ok("deposit");
        } catch {
            _fail("deposit");
        }
    }

    /// @dev Non-delegate, non-owner accounts can never check in.
    function checkIn(uint256 vSeed, uint256 aSeed) external track(false) {
        vm.prank(_actor(aSeed));
        try dms.checkIn(_vid(vSeed)) {
            unexpectedSuccess++;
        } catch {
            _fail("checkIn");
        }
    }

    /// @dev The ONLY legitimate liveness signal: a routine check-in by the creation-time delegate. It resets the
    ///      extension allowance and may cancel a trigger inside the challenge window (rescue).
    function delegateCheckIn(uint256 vSeed) external track(false) {
        uint256 id = _vid(vSeed);
        bool wasTriggered = dms.getVault(id).triggered;
        vm.prank(dlg);
        try dms.checkIn(id) {
            _ok("delegateCheckIn");
            if (wasTriggered) _ok("delegateRescue");
            ghostLastCheckIn[id] = block.timestamp;
            extThisPeriod[id] = 0;
        } catch {
            _fail("delegateCheckIn");
        }
    }

    /// @dev The delegate can ONLY check in: every other owner-only action it tries must revert.
    function delegateOverreach(uint256 vSeed, uint256 kind, uint256 tSeed) external track(false) {
        uint256 id = _vid(vSeed);
        vm.startPrank(dlg);
        if (kind % 3 == 0) {
            try dms.requestWithdraw(id, 1) {
                unexpectedSuccess++;
            } catch {
                _fail("delegateOverreach");
            }
        } else if (kind % 3 == 1) {
            try dms.setCheckInDelegate(id, _target(tSeed)) {
                unexpectedSuccess++;
            } catch {
                _fail("delegateOverreach");
            }
        } else {
            try dms.executeWithdraw(id) {
                unexpectedSuccess++;
            } catch {
                _fail("delegateOverreach");
            }
        }
        vm.stopPrank();
    }

    /// @dev approveOwnerRotation by any actor-pool account (never owner/delegate) must always revert, including
    ///      the pending newOwner itself and guardians.
    function approveRotation(uint256 vSeed, uint256 aSeed, uint256 tSeed) external track(false) {
        uint256 id = _vid(vSeed);
        DMS.PendingRotation memory r = dms.getPendingRotation(id);
        address target = tSeed % 2 == 0 && r.exists ? r.newOwner : _target(tSeed);
        address caller = aSeed % 4 == 0 && r.exists ? r.newOwner : _actor(aSeed);
        vm.prank(caller);
        try dms.approveOwnerRotation(id, target) {
            unexpectedSuccess++;
        } catch {
            _fail("approveRotation");
        }
    }

    function setDelegate(uint256 vSeed, uint256 aSeed, uint256 tSeed) external track(false) {
        address t = tSeed % 4 == 0 ? address(0) : _target(tSeed);
        vm.prank(_actor(aSeed));
        try dms.setCheckInDelegate(_vid(vSeed), t) {
            unexpectedSuccess++;
        } catch {
            _fail("setDelegate");
        }
    }

    function requestWithdraw(uint256 vSeed, uint256 aSeed, uint256 amt) external track(false) {
        amt = bound(amt, 1, 1e9);
        vm.prank(_actor(aSeed));
        try dms.requestWithdraw(_vid(vSeed), amt) {
            unexpectedSuccess++;
        } catch {
            _fail("requestWithdraw");
        }
    }

    function executeWithdraw(uint256 vSeed, uint256 aSeed) external track(false) {
        vm.prank(_actor(aSeed));
        try dms.executeWithdraw(_vid(vSeed)) {
            unexpectedSuccess++;
        } catch {
            _fail("executeWithdraw");
        }
    }

    function cancelWithdraw(uint256 vSeed, uint256 aSeed) external track(false) {
        vm.prank(_actor(aSeed));
        try dms.cancelWithdraw(_vid(vSeed)) {
            unexpectedSuccess++;
        } catch {
            _fail("cancelWithdraw");
        }
    }

    function executeRotation(uint256 vSeed, uint256 aSeed) external track(false) {
        uint256 id = _vid(vSeed);
        vm.prank(_actor(aSeed));
        try dms.executeOwnerRotation(id) {
            unexpectedSuccess++;
        } catch (bytes memory err) {
            _fail("executeRotation");
            if (err.length >= 4 && bytes4(err) == DMS.RotationNotApproved.selector) _ok("execNotApproved");
        }
    }

    /// @dev Only non-vetoers (not owner/delegate/beneficiary of the vault) call cancel, so proposals stay pending.
    function cancelRotation(uint256 vSeed, uint256 aSeed) external track(false) {
        uint256 id = _vid(vSeed);
        address a = _actor(aSeed);
        if (_isBen(id, a)) return;
        vm.prank(a);
        try dms.cancelOwnerRotation(id) {
            unexpectedSuccess++;
        } catch {
            _fail("cancelRotation");
        }
    }

    // ------------------------------------------------------------------ guardian-collusion actions that may succeed

    function _afterExtend(uint256 id, bool wasUsed, uint256 dlBefore, bool ok) internal {
        bool nowUsed = dms.getVault(id).extensionUsed;
        if (ok && wasUsed) unexpectedSuccess++; // a second executed extension in one check-in period
        if (!wasUsed && nowUsed) {
            if (block.timestamp >= dlBefore) unexpectedSuccess++; // an extension executed on an expired vault
            extExecuted[id]++;
            uint256 n = ++extThisPeriod[id];
            if (n > maxExtPeriod[id]) maxExtPeriod[id] = n;
            _ok("extendExecuted");
        }
    }

    function extend(uint256 vSeed, uint256 aSeed, uint256 arg) external track(false) {
        uint256 id = _vid(vSeed);
        bool wasUsed = dms.getVault(id).extensionUsed;
        uint256 dlBefore = dms.deadline(id);
        uint64 nd = _ndFor(id, arg);
        vm.prank(_actor(aSeed));
        try dms.extendDeadline(id, nd) {
            _ok("extend");
            _afterExtend(id, wasUsed, dlBefore, true);
        } catch {
            _fail("extend");
        }
    }

    /// @dev Every guardian votes the same deadline within one timestamp (reaches quorum).
    function extendQuorum(uint256 vSeed, uint256 arg) external track(false) {
        uint256 id = _vid(vSeed);
        uint64 nd = arg % 2 == 0 ? uint64(block.timestamp + dms.getVault(id).interval) : _ndFor(id, arg);
        address[] memory gs = dms.getGuardians(id);
        for (uint256 i; i < gs.length; ++i) {
            bool was = dms.getVault(id).extensionUsed;
            uint256 dlBefore = dms.deadline(id);
            vm.prank(gs[i]);
            try dms.extendDeadline(id, nd) {
                _ok("extend");
                _afterExtend(id, was, dlBefore, true);
            } catch {
                _fail("extend");
            }
        }
    }

    function _noteQuorum(uint256 id, bool pendingBefore) internal {
        if (!pendingBefore && dms.getPendingRotation(id).exists) _ok("quorum");
    }

    function proposeRotation(uint256 vSeed, uint256 aSeed, uint256 tSeed) external track(false) {
        uint256 id = _vid(vSeed);
        address t = _target(tSeed);
        bool pb = dms.getPendingRotation(id).exists;
        vm.prank(_actor(aSeed));
        try dms.proposeOwnerRotation(id, t) {
            _ok("propose");
            _noteQuorum(id, pb);
        } catch {
            _fail("propose");
        }
    }

    function proposeQuorum(uint256 vSeed, uint256 tSeed) external track(false) {
        uint256 id = _vid(vSeed);
        address t = tSeed % 2 == 0 ? _target(tSeed) : address(uint160(uint256(keccak256(abi.encode("fresh-q", tSeed)))));
        _monitor(t);
        bool pb = dms.getPendingRotation(id).exists;
        address[] memory gs = dms.getGuardians(id);
        for (uint256 i; i < gs.length; ++i) {
            vm.prank(gs[i]);
            try dms.proposeOwnerRotation(id, t) {
                _ok("propose");
            } catch {
                _fail("propose");
            }
        }
        _noteQuorum(id, pb);
    }

    function spawnAttacker(uint256 seed) external {
        totalCalls++;
        if (freshCount >= 6) return;
        address a = address(uint160(uint256(keccak256(abi.encode("fresh-actor", seed, freshCount)))));
        freshCount++;
        actors.push(a);
        _monitor(a);
        _ok("spawn");
    }

    // ------------------------------------------------------------------ permissionless / role actions

    function trigger(uint256 vSeed, uint256 aSeed) external track(false) {
        uint256 id = _vid(vSeed);
        uint256 dl = dms.deadline(id);
        vm.prank(_actor(aSeed));
        try dms.trigger(id) {
            _ok("trigger");
            if (block.timestamp < dl) triggerEarly++;
        } catch {
            _fail("trigger");
        }
    }

    function finalize(uint256 vSeed, uint256 aSeed) external track(false) {
        vm.prank(_actor(aSeed));
        try dms.finalize(_vid(vSeed)) {
            _ok("finalize");
        } catch {
            _fail("finalize");
        }
    }

    function setPayout(uint256 vSeed, uint256 aSeed, uint256 pSeed) external track(false) {
        uint256 id = _vid(vSeed);
        address caller = _callerOrBen(id, aSeed);
        address payout;
        if (_isBen(id, caller)) {
            uint256 r = pSeed % 4;
            payout = r == 0 ? bPay1 : (r == 1 ? bPay2 : (r == 2 ? bPay3 : address(0)));
        } else {
            payout = caller; // a non-beneficiary trying to redirect to itself
        }
        vm.prank(caller);
        try dms.setPayoutAddress(id, payout) {
            _ok("setPayout");
            if (payout != address(0) && !isAllowed[payout]) badRecipient++;
        } catch {
            _fail("setPayout");
        }
    }

    function setFallbackPayout(uint256 vSeed, uint256 aSeed, uint256 pSeed) external track(false) {
        uint256 id = _vid(vSeed);
        address fbA = dms.getConfig(id).fallbackAddress;
        address caller = aSeed % 3 != 0 ? fbA : _actor(aSeed / 3);
        address payout;
        if (caller == fbA) {
            uint256 r = pSeed % 3;
            payout = r == 0 ? fbDest1 : (r == 1 ? fbDest2 : address(0));
        } else {
            payout = caller;
        }
        vm.prank(caller);
        try dms.setFallbackPayout(id, payout) {
            _ok("setFallback");
            if (payout != address(0) && !isAllowed[payout]) badRecipient++;
        } catch {
            _fail("setFallback");
        }
    }

    function claim(uint256 vSeed, uint256 aSeed) external track(true) {
        uint256 id = _vid(vSeed);
        address caller = _callerOrBen(id, aSeed);
        address dest = dms.payoutAddressOf(id, caller);
        uint256 b = usdc.balanceOf(address(dms));
        vm.prank(caller);
        try dms.claim(id) {
            _ok("claim");
            ghostClaimed += b - usdc.balanceOf(address(dms));
            if (!isAllowed[dest]) badRecipient++;
        } catch {
            _fail("claim");
        }
    }

    function sweep(uint256 vSeed, uint256 aSeed) external track(true) {
        uint256 id = _vid(vSeed);
        address dest = dms.fallbackPayoutOf(id);
        uint256 b = usdc.balanceOf(address(dms));
        vm.prank(_actor(aSeed));
        try dms.sweep(id) {
            _ok("sweep");
            ghostSwept += b - usdc.balanceOf(address(dms));
            if (!isAllowed[dest]) badRecipient++;
        } catch {
            _fail("sweep");
        }
    }
}
