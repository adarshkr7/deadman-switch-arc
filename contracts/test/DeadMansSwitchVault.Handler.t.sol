// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DeadMansSwitchVault as DMS} from "../DeadMansSwitchVault.sol";
import {MockUSDC} from "../test-helpers/MockUSDC.sol";

/// @dev Invariant handler. Every call is wrapped in try/catch and tracked with ghost counters.
///      g1,g2,g3 are PURE guardians: never owner, delegate, beneficiary, fallback or payout target.
contract DMSHandler is Test {
    DMS public dms;
    MockUSDC public usdc;

    address public ownerA = makeAddr("hOwnerA");
    address public ownerB = makeAddr("hOwnerB");
    address public delegateA = makeAddr("hDelegateA");
    address public g1 = makeAddr("hG1");
    address public g2 = makeAddr("hG2");
    address public g3 = makeAddr("hG3");
    address public alice = makeAddr("hAlice");
    address public bob = makeAddr("hBob");
    address public carol = makeAddr("hCarol");
    address public stranger = makeAddr("hStranger");
    address public fb = makeAddr("hFallback");
    address public fb2 = makeAddr("hFallback2");
    address public depositor = makeAddr("hDepositor");
    address public rotTarget = makeAddr("hRotTarget");
    address public altPayout = makeAddr("hAltPayout");

    uint256[] public vaultIds;
    address[] internal everyone;

    // ghosts
    uint256 public ghostIn;
    uint256 public ghostOut;
    uint256 public ghostGuardianOutflow;
    uint256 public guardianViolations;
    uint256 public guardianTriggerFlips;
    uint256 public triggerEarly;
    uint256 public totalCalls;
    mapping(bytes32 => uint256) public okCount;
    mapping(bytes32 => uint256) public failCount;

    struct Snap {
        uint256 dmsBal;
        uint256 gBal;
        uint256 paid;
        uint256 funds;
        bool triggered;
    }

    constructor(DMS dms_, MockUSDC usdc_) {
        dms = dms_;
        usdc = usdc_;
        everyone.push(ownerA);
        everyone.push(ownerB);
        everyone.push(delegateA);
        everyone.push(g1);
        everyone.push(g2);
        everyone.push(g3);
        everyone.push(alice);
        everyone.push(bob);
        everyone.push(carol);
        everyone.push(stranger);
        everyone.push(fb);
        everyone.push(fb2);
        everyone.push(depositor);
        everyone.push(rotTarget);
        everyone.push(altPayout);

        // V0: 3 beneficiaries, 2-of-3 guardians, short delays
        DMS.CreateParams memory p;
        p.beneficiaries = new address[](3);
        p.beneficiaries[0] = alice;
        p.beneficiaries[1] = bob;
        p.beneficiaries[2] = carol;
        p.sharesBps = new uint16[](3);
        p.sharesBps[0] = 3333;
        p.sharesBps[1] = 3333;
        p.sharesBps[2] = 3334;
        p.interval = 300;
        p.guardians = new address[](3);
        p.guardians[0] = g1;
        p.guardians[1] = g2;
        p.guardians[2] = g3;
        p.guardianThreshold = 2;
        p.withdrawDelay = 60;
        p.challengeWindow = 60;
        p.rotationTimelock = 60;
        p.sweepPeriod = 120;
        p.fallbackAddress = fb;
        vm.prank(ownerA);
        vaultIds.push(dms.createVault(p));

        // V1: 2 beneficiaries, 1-of-1 guardian, different owner
        p.beneficiaries = new address[](2);
        p.beneficiaries[0] = bob;
        p.beneficiaries[1] = carol;
        p.sharesBps = new uint16[](2);
        p.sharesBps[0] = 5000;
        p.sharesBps[1] = 5000;
        p.interval = 600;
        p.guardians = new address[](1);
        p.guardians[0] = g1;
        p.guardianThreshold = 1;
        p.withdrawDelay = 90;
        p.sweepPeriod = 200;
        vm.prank(ownerB);
        vaultIds.push(dms.createVault(p));

        // V2: single beneficiary, no guardians, different fallback
        p.beneficiaries = new address[](1);
        p.beneficiaries[0] = alice;
        p.sharesBps = new uint16[](1);
        p.sharesBps[0] = 10_000;
        p.interval = 120;
        p.guardians = new address[](0);
        p.guardianThreshold = 0;
        p.withdrawDelay = 60;
        p.sweepPeriod = 60;
        p.fallbackAddress = fb2;
        vm.prank(ownerA);
        vaultIds.push(dms.createVault(p));
    }

    function vaultCount() external view returns (uint256) {
        return vaultIds.length;
    }

    // ------------------------------------------------------------------ plumbing

    modifier track() {
        totalCalls++;
        uint256 b = usdc.balanceOf(address(dms));
        _;
        uint256 a = usdc.balanceOf(address(dms));
        if (a > b) ghostIn += a - b;
        else ghostOut += b - a;
    }

    function _vid(uint256 s) internal view returns (uint256) {
        return vaultIds[s % vaultIds.length];
    }

    function _ok(bytes32 k) internal {
        okCount[k]++;
    }

    function _fail(bytes32 k) internal {
        failCount[k]++;
    }

    function _any(uint256 s) internal view returns (address) {
        return everyone[s % everyone.length];
    }

    function _role(uint256 seed, address primary, address secondary) internal view returns (address) {
        uint256 r = seed % 5;
        if (r < 3) return primary;
        if (r == 3) return secondary;
        return _any(seed / 5);
    }

    function _guardian(uint256 s) internal view returns (address) {
        uint256 r = s % 3;
        return r == 0 ? g1 : (r == 1 ? g2 : g3);
    }

    function _beneficiary(uint256 id, uint256 seed) internal view returns (address) {
        (address[] memory bs,) = dms.getBeneficiaries(id);
        return bs[(seed / 5) % bs.length];
    }

    // ------------------------------------------------------------------ time

    function warp(uint256 secs) external {
        totalCalls++;
        vm.warp(block.timestamp + bound(secs, 1, 250));
        _ok("warp");
    }

    function warpToEvent(uint256 vSeed, uint256 kind) external {
        totalCalls++;
        uint256 id = _vid(vSeed);
        DMS.VaultView memory v = dms.getVault(id);
        uint256 k = kind % 5;
        uint256 target;
        if (k == 0) target = v.deadline;
        else if (k == 1) target = v.challengeEnd;
        else if (k == 2) target = v.sweepAt;
        else if (k == 3) target = dms.getPendingWithdrawal(id).executableAt;
        else target = dms.getPendingRotation(id).executableAt;
        if (target > block.timestamp) vm.warp(target);
        _ok("warpToEvent");
    }

    // ------------------------------------------------------------------ owner / delegate / anyone

    function deposit(uint256 vSeed, uint256 amt) external track {
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

    function checkIn(uint256 vSeed, uint256 rSeed) external track {
        uint256 id = _vid(vSeed);
        DMS.VaultView memory v = dms.getVault(id);
        address caller = _role(rSeed, v.owner, v.checkInDelegate == address(0) ? stranger : v.checkInDelegate);
        vm.prank(caller);
        try dms.checkIn(id) {
            _ok("checkIn");
        } catch {
            _fail("checkIn");
        }
    }

    function setDelegate(uint256 vSeed, uint256 dSeed) external track {
        uint256 id = _vid(vSeed);
        address caller = _role(dSeed, dms.getVault(id).owner, stranger);
        uint256 t = (dSeed / 7) % 3;
        address target = t == 0 ? delegateA : (t == 1 ? stranger : address(0));
        vm.prank(caller);
        try dms.setCheckInDelegate(id, target) {
            _ok("setDelegate");
        } catch {
            _fail("setDelegate");
        }
    }

    function requestWithdraw(uint256 vSeed, uint256 rSeed, uint256 amt) external track {
        uint256 id = _vid(vSeed);
        DMS.VaultView memory v = dms.getVault(id);
        amt = bound(amt, 1, v.balance == 0 ? 1 : v.balance);
        vm.prank(_role(rSeed, v.owner, stranger));
        try dms.requestWithdraw(id, amt) {
            _ok("requestWithdraw");
        } catch {
            _fail("requestWithdraw");
        }
    }

    function executeWithdraw(uint256 vSeed, uint256 rSeed) external track {
        uint256 id = _vid(vSeed);
        vm.prank(_role(rSeed, dms.getVault(id).owner, stranger));
        try dms.executeWithdraw(id) {
            _ok("executeWithdraw");
        } catch {
            _fail("executeWithdraw");
        }
    }

    function cancelWithdraw(uint256 vSeed, uint256 rSeed) external track {
        uint256 id = _vid(vSeed);
        vm.prank(_role(rSeed, dms.getVault(id).owner, stranger));
        try dms.cancelWithdraw(id) {
            _ok("cancelWithdraw");
        } catch {
            _fail("cancelWithdraw");
        }
    }

    function executeRotation(uint256 vSeed, uint256 rSeed) external track {
        uint256 id = _vid(vSeed);
        vm.prank(_any(rSeed));
        try dms.executeOwnerRotation(id) {
            _ok("executeRotation");
        } catch {
            _fail("executeRotation");
        }
    }

    /// @dev Owner / delegate / random account approves the pending rotation target (or a random wrong target).
    function approveRotation(uint256 vSeed, uint256 rSeed) external track {
        uint256 id = _vid(vSeed);
        DMS.VaultView memory v = dms.getVault(id);
        address target = rSeed % 7 == 0 ? rotTarget : dms.getPendingRotation(id).newOwner;
        vm.prank(_role(rSeed, v.owner, v.checkInDelegate == address(0) ? stranger : v.checkInDelegate));
        try dms.approveOwnerRotation(id, target) {
            _ok("approveRotation");
        } catch {
            _fail("approveRotation");
        }
    }

    function cancelRotation(uint256 vSeed, uint256 rSeed) external track {
        uint256 id = _vid(vSeed);
        vm.prank(_role(rSeed, dms.getVault(id).owner, stranger));
        try dms.cancelOwnerRotation(id) {
            _ok("cancelRotation");
        } catch {
            _fail("cancelRotation");
        }
    }

    function trigger(uint256 vSeed, uint256 rSeed) external track {
        uint256 id = _vid(vSeed);
        uint256 dl = dms.deadline(id);
        vm.prank(_any(rSeed));
        try dms.trigger(id) {
            _ok("trigger");
            if (block.timestamp < dl) triggerEarly++;
        } catch {
            _fail("trigger");
        }
    }

    function finalize(uint256 vSeed, uint256 rSeed) external track {
        uint256 id = _vid(vSeed);
        vm.prank(_any(rSeed));
        try dms.finalize(id) {
            _ok("finalize");
        } catch {
            _fail("finalize");
        }
    }

    function claim(uint256 vSeed, uint256 bSeed) external track {
        uint256 id = _vid(vSeed);
        vm.prank(_role(bSeed, _beneficiary(id, bSeed), stranger));
        try dms.claim(id) {
            _ok("claim");
        } catch {
            _fail("claim");
        }
    }

    function setPayout(uint256 vSeed, uint256 bSeed, bool useAlt) external track {
        uint256 id = _vid(vSeed);
        address payout = useAlt ? altPayout : address(0);
        vm.prank(_role(bSeed, _beneficiary(id, bSeed), stranger));
        try dms.setPayoutAddress(id, payout) {
            _ok("setPayout");
        } catch {
            _fail("setPayout");
        }
    }

    function setFallbackPayout(uint256 vSeed, uint256 rSeed, bool useAlt) external track {
        uint256 id = _vid(vSeed);
        address payout = useAlt ? altPayout : address(0);
        vm.prank(_role(rSeed, dms.getConfig(id).fallbackAddress, stranger));
        try dms.setFallbackPayout(id, payout) {
            _ok("setFallback");
        } catch {
            _fail("setFallback");
        }
    }

    function sweep(uint256 vSeed, uint256 rSeed) external track {
        uint256 id = _vid(vSeed);
        vm.prank(_any(rSeed));
        try dms.sweep(id) {
            _ok("sweep");
        } catch {
            _fail("sweep");
        }
    }

    // ------------------------------------------------------------------ compound flows (raise success rates)

    /// @dev Owner requests a withdrawal, waits the delay, executes it.
    function withdrawFlow(uint256 vSeed, uint256 amt) external track {
        uint256 id = _vid(vSeed);
        DMS.VaultView memory v = dms.getVault(id);
        amt = bound(amt, 1, v.balance == 0 ? 1 : v.balance);
        vm.prank(v.owner);
        try dms.requestWithdraw(id, amt) {
            _ok("wfRequest");
            uint256 ex = dms.getPendingWithdrawal(id).executableAt;
            if (ex > block.timestamp) vm.warp(ex);
            vm.prank(v.owner);
            try dms.executeWithdraw(id) {
                _ok("executeWithdraw");
            } catch {
                _fail("executeWithdraw");
            }
        } catch {
            _fail("wfRequest");
        }
    }

    /// @dev Guardians g1,g2 propose a rotation, time passes, a random account executes it.
    function rotateFlow(uint256 vSeed, uint256 tSeed) external track {
        uint256 id = _vid(vSeed);
        address t = tSeed % 2 == 0 ? rotTarget : stranger;
        uint256 balBefore = usdc.balanceOf(address(dms));
        vm.prank(g1);
        try dms.proposeOwnerRotation(id, t) {
            _ok("gPropose");
        } catch {
            _fail("gPropose");
        }
        vm.prank(g2);
        try dms.proposeOwnerRotation(id, t) {
            _ok("gPropose");
        } catch {
            _fail("gPropose");
        }
        // explicit approval: the current owner (or delegate) approves the exact pending newOwner
        if (dms.getPendingRotation(id).exists) {
            vm.warp(block.timestamp + 1);
            DMS.VaultView memory lv = dms.getVault(id);
            vm.prank(tSeed % 3 == 0 && lv.checkInDelegate != address(0) ? lv.checkInDelegate : lv.owner);
            try dms.approveOwnerRotation(id, dms.getPendingRotation(id).newOwner) {
                _ok("rfApprove");
            } catch {
                _fail("rfApprove");
            }
        }
        uint256 ex = dms.getPendingRotation(id).executableAt;
        if (ex > block.timestamp) vm.warp(ex);
        vm.prank(_any(tSeed));
        try dms.executeOwnerRotation(id) {
            _ok("executeRotation");
        } catch {
            _fail("executeRotation");
        }
        if (usdc.balanceOf(address(dms)) != balBefore) guardianViolations++;
    }

    // ------------------------------------------------------------------ pure-guardian actions

    function _snap(uint256 id, address g) internal view returns (Snap memory s) {
        DMS.VaultView memory v = dms.getVault(id);
        s.dmsBal = usdc.balanceOf(address(dms));
        s.gBal = usdc.balanceOf(g);
        s.paid = dms.totalPaidOut();
        s.funds = v.balance + v.claimPool;
        s.triggered = v.triggered;
    }

    function _ndFor(uint256 id, uint256 arg) internal view returns (uint64) {
        DMS.VaultView memory v = dms.getVault(id);
        uint256 lo = v.deadline > block.timestamp ? v.deadline : block.timestamp;
        uint256 hi = block.timestamp + v.interval;
        if (hi <= lo) return uint64(lo + 1);
        return uint64(lo + 1 + (arg % (hi - lo)));
    }

    /// @dev act: 0 extendDeadline, 1 cancelWithdraw, 2 proposeOwnerRotation, 3 executeOwnerRotation, 4 trigger.
    function _invokeGuardian(uint256 id, address g, uint256 act, uint256 arg) internal returns (bool ok) {
        if (act == 0) {
            uint64 nd = _ndFor(id, arg);
            vm.prank(g);
            try dms.extendDeadline(id, nd) {
                ok = true;
                _ok("gExtend");
            } catch {
                _fail("gExtend");
            }
        } else if (act == 1) {
            vm.prank(g);
            try dms.cancelWithdraw(id) {
                ok = true;
                _ok("gCancel");
            } catch {
                _fail("gCancel");
            }
        } else if (act == 2) {
            address t = arg % 2 == 0 ? rotTarget : stranger;
            vm.prank(g);
            try dms.proposeOwnerRotation(id, t) {
                ok = true;
                _ok("gPropose");
            } catch {
                _fail("gPropose");
            }
        } else if (act == 3) {
            vm.prank(g);
            try dms.executeOwnerRotation(id) {
                ok = true;
                _ok("gExecRot");
            } catch {
                _fail("gExecRot");
            }
        } else {
            vm.prank(g);
            try dms.trigger(id) {
                ok = true;
                _ok("gTrigger");
            } catch {
                _fail("gTrigger");
            }
        }
    }

    function guardianAct(uint256 vSeed, uint256 gSeed, uint256 act, uint256 arg) external track {
        uint256 id = _vid(vSeed);
        address g = _guardian(gSeed);
        act = act % 5;
        uint256 dl = dms.deadline(id);
        Snap memory b = _snap(id, g);
        bool ok = _invokeGuardian(id, g, act, arg);
        Snap memory a = _snap(id, g);

        if (a.dmsBal < b.dmsBal) ghostGuardianOutflow += b.dmsBal - a.dmsBal;
        if (a.dmsBal != b.dmsBal || a.gBal != b.gBal || a.paid != b.paid || a.funds != b.funds) {
            guardianViolations++;
        }
        if (act != 4 && !b.triggered && a.triggered) guardianTriggerFlips++;
        if (act == 4 && ok && block.timestamp < dl) triggerEarly++;
    }
}
