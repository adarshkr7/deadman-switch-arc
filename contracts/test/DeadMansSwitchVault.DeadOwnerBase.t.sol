// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DeadMansSwitchVault as DMS} from "../DeadMansSwitchVault.sol";
import {MockUSDC} from "../test-helpers/MockUSDC.sol";

/// @dev "Dead owner" campaign handler. The three vault owners create their vaults in the constructor, configure
///      ONE check-in delegate (`dlg`) at creation time, and are NEVER used again (no owner pranks afterwards,
///      owners are not in the actor pool). The delegate is not in the actor pool either: its only action is
///      `delegateCheckIn` (plus rejected owner-only attempts); it never approves or cancels a rotation.
///      Guardians are distinct from beneficiaries/fallbacks. Every action is try/catch with bounded inputs.
///      strictClock: time never skips past an untriggered vault's deadline (a watcher is always present).
abstract contract DeadOwnerHandlerBase is Test {
    DMS public dms;
    MockUSDC public usdc;
    bool public strictClock;

    address public ownerA = makeAddr("doOwnerA");
    address public ownerB = makeAddr("doOwnerB");
    address public ownerC = makeAddr("doOwnerC");
    address public g1 = makeAddr("doG1");
    address public g2 = makeAddr("doG2");
    address public g3 = makeAddr("doG3");
    address public alice = makeAddr("doAlice");
    address public bob = makeAddr("doBob");
    address public carol = makeAddr("doCarol");
    address public fb = makeAddr("doFallback");
    address public fb2 = makeAddr("doFallback2");
    address public att1 = makeAddr("doAttacker1");
    address public att2 = makeAddr("doAttacker2");
    address public att3 = makeAddr("doAttacker3");
    address public bPay1 = makeAddr("doBenPayout1");
    address public bPay2 = makeAddr("doBenPayout2");
    address public bPay3 = makeAddr("doBenPayout3");
    address public fbDest1 = makeAddr("doFbDest1");
    address public fbDest2 = makeAddr("doFbDest2");
    address public depositor = makeAddr("doDepositor");
    address public dlg = makeAddr("doDelegate"); // check-in delegate set at creation; routine check-ins only

    uint256[] public vaultIds;
    mapping(uint256 => address) public originalOwner;
    mapping(uint256 => uint256) public createdAt;
    mapping(uint256 => uint256) public extExecuted; // total executed extensions (informational)
    mapping(uint256 => uint256) public extThisPeriod; // executed extensions since the last delegate check-in
    mapping(uint256 => uint256) public maxExtPeriod; // max of extThisPeriod ever observed
    mapping(uint256 => uint256) public ghostLastCheckIn; // creation time, then the last successful delegate check-in

    address[] internal actors; // random-prank pool: never contains an owner key
    address[] public monitored; // attackers / guardians / strangers / owners: balance may never rise
    mapping(address => bool) public isMonitored;
    mapping(address => uint256) public startBal;
    mapping(address => uint256) public maxBal;
    address[] public allowedList; // beneficiaries, their payouts, fallbacks and fallback destinations
    mapping(address => bool) public isAllowed;
    uint256 public freshCount;

    uint256 public ghostIn;
    uint256 public ghostOut;
    uint256 public ghostClaimed;
    uint256 public ghostSwept;
    uint256 public illegalOut;
    uint256 public badRecipient;
    uint256 public unexpectedSuccess;
    uint256 public triggerEarly;
    uint256 public totalCalls;
    mapping(bytes32 => uint256) public okCount;
    mapping(bytes32 => uint256) public failCount;

    constructor(DMS dms_, MockUSDC usdc_, bool strict_) {
        dms = dms_;
        usdc = usdc_;
        strictClock = strict_;

        address[16] memory pool = [g1, g2, g3, alice, bob, carol, fb, fb2, att1, att2, att3, bPay1, bPay2, bPay3, fbDest1, depositor];
        for (uint256 i; i < pool.length; ++i) actors.push(pool[i]);
        address[10] memory mon = [g1, g2, g3, att1, att2, att3, ownerA, ownerB, ownerC, dlg];
        for (uint256 i; i < mon.length; ++i) _monitor(mon[i]);
        address[10] memory allowed = [alice, bob, carol, bPay1, bPay2, bPay3, fb, fb2, fbDest1, fbDest2];
        for (uint256 i; i < allowed.length; ++i) {
            isAllowed[allowed[i]] = true;
            allowedList.push(allowed[i]);
        }

        // V0: 3 beneficiaries, 2-of-3 guardians
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
        _create(ownerA, p);

        // V1: 2 beneficiaries, 1-of-1 guardian (a single colluding guardian is enough)
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
        p.sweepPeriod = 200;
        _create(ownerB, p);

        // V2: single beneficiary, 2-of-2 guardians, other fallback
        p.beneficiaries = new address[](1);
        p.beneficiaries[0] = alice;
        p.sharesBps = new uint16[](1);
        p.sharesBps[0] = 10_000;
        p.interval = 120;
        p.guardians = new address[](2);
        p.guardians[0] = g2;
        p.guardians[1] = g3;
        p.guardianThreshold = 2;
        p.sweepPeriod = 60;
        p.fallbackAddress = fb2;
        _create(ownerC, p);
    }

    function _create(address who, DMS.CreateParams memory p) internal {
        vm.prank(who);
        uint256 id = dms.createVault(p);
        vaultIds.push(id);
        originalOwner[id] = who;
        createdAt[id] = block.timestamp;
        ghostLastCheckIn[id] = block.timestamp;
        // the owner's only post-creation act: configure the routine check-in delegate
        vm.prank(who);
        dms.setCheckInDelegate(id, dlg);
    }

    function vaultCount() external view returns (uint256) {
        return vaultIds.length;
    }

    function monitoredCount() external view returns (uint256) {
        return monitored.length;
    }

    function allowedCount() external view returns (uint256) {
        return allowedList.length;
    }

    // ------------------------------------------------------------------ plumbing

    /// @dev Roles that are legitimately paid (beneficiary/fallback/depositor) are never monitored.
    function _monitor(address a) internal {
        if (isMonitored[a] || isAllowed[a] || a == depositor || monitored.length >= 40) return;
        isMonitored[a] = true;
        monitored.push(a);
        startBal[a] = usdc.balanceOf(a);
    }

    function _sample() internal {
        for (uint256 i; i < monitored.length; ++i) {
            uint256 b = usdc.balanceOf(monitored[i]);
            if (b > maxBal[monitored[i]]) maxBal[monitored[i]] = b;
        }
    }

    modifier track(bool outAllowed) {
        totalCalls++;
        uint256 b = usdc.balanceOf(address(dms));
        _;
        uint256 a = usdc.balanceOf(address(dms));
        if (a > b) {
            ghostIn += a - b;
        } else if (b > a) {
            ghostOut += b - a;
            if (!outAllowed) illegalOut += b - a;
        }
        _sample();
    }

    function _ok(bytes32 k) internal {
        okCount[k]++;
    }

    function _fail(bytes32 k) internal {
        failCount[k]++;
    }

    function _vid(uint256 s) internal view returns (uint256) {
        return vaultIds[s % vaultIds.length];
    }

    function _actor(uint256 s) internal view returns (address) {
        return actors[s % actors.length];
    }

    function _isBen(uint256 id, address a) internal view returns (bool) {
        (address[] memory bs,) = dms.getBeneficiaries(id);
        for (uint256 i; i < bs.length; ++i) if (bs[i] == a) return true;
        return false;
    }

    function _ben(uint256 id, uint256 s) internal view returns (address) {
        (address[] memory bs,) = dms.getBeneficiaries(id);
        return bs[s % bs.length];
    }

    function _callerOrBen(uint256 id, uint256 aSeed) internal view returns (address) {
        return aSeed % 3 != 0 ? _ben(id, aSeed / 3) : _actor(aSeed / 3);
    }

    /// @dev Rotation / delegate target: attackers, a fresh derived address, or assorted roles.
    function _target(uint256 s) internal returns (address t) {
        uint256 r = s % 8;
        if (r == 0) t = att1;
        else if (r == 1) t = att2;
        else if (r == 2) t = att3;
        else if (r == 3) t = address(uint160(uint256(keccak256(abi.encode("fresh-target", s)))));
        else if (r == 4) t = alice;
        else if (r == 5) t = g1;
        else if (r == 6) t = fb;
        else t = depositor;
        _monitor(t);
    }

    function _ndFor(uint256 id, uint256 arg) internal view returns (uint64) {
        DMS.VaultView memory v = dms.getVault(id);
        uint256 lo = v.deadline > block.timestamp ? v.deadline : block.timestamp;
        uint256 hi = block.timestamp + v.interval;
        if (hi <= lo) return uint64(lo + 1); // out of range on purpose (expected revert)
        return uint64(lo + 1 + (arg % (hi - lo)));
    }

    // ------------------------------------------------------------------ time

    /// @dev Returns true if some untriggered vault is already past its deadline ("stuck" under strictClock).
    function _advance(uint256 target) internal {
        if (strictClock) {
            for (uint256 i; i < vaultIds.length; ++i) {
                DMS.VaultView memory v = dms.getVault(vaultIds[i]);
                if (v.triggered) continue;
                if (v.deadline <= block.timestamp) return; // watcher: stop the clock on an expired vault
                if (v.deadline < target) target = v.deadline;
            }
        }
        if (target > block.timestamp) vm.warp(target);
    }

    function warp(uint256 secs) external {
        totalCalls++;
        if (strictClock && secs % 2 == 0) {
            // the watcher resolves an expired-untriggered vault by triggering it
            for (uint256 i; i < vaultIds.length; ++i) {
                DMS.VaultView memory v = dms.getVault(vaultIds[i]);
                if (!v.triggered && v.deadline <= block.timestamp) {
                    vm.prank(att1);
                    try dms.trigger(vaultIds[i]) {
                        _ok("watcherTrigger");
                    } catch {
                        _fail("watcherTrigger");
                    }
                }
            }
        }
        _advance(block.timestamp + bound(secs, 1, 250));
        _ok("warp");
    }

    function warpToEvent(uint256 vSeed, uint256 kind) external {
        totalCalls++;
        uint256 id = _vid(vSeed);
        DMS.VaultView memory v = dms.getVault(id);
        uint256 k = kind % 3;
        uint256 target = k == 0 ? v.deadline : (k == 1 ? v.challengeEnd : v.sweepAt);
        if (kind % 7 == 3) target = dms.getPendingRotation(id).executableAt;
        _advance(target);
        _ok("warpToEvent");
    }

}
