// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeadMansSwitchVault as DMS} from "../DeadMansSwitchVault.sol";
import {MockUSDC} from "../test-helpers/MockUSDC.sol";

/// @dev Shared fixtures for all DeadMansSwitchVault test files. Contains no test functions.
abstract contract DMSTestBase is Test {
    DMS internal dms;
    MockUSDC internal usdc;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal g1 = makeAddr("guardian1");
    address internal g2 = makeAddr("guardian2");
    address internal g3 = makeAddr("guardian3");
    address internal delegate = makeAddr("delegate");
    address internal fallbackAddr = makeAddr("fallback");
    address internal stranger = makeAddr("stranger");
    address internal newOwner = makeAddr("newOwner");
    address internal depositor = makeAddr("depositor");
    address internal payoutAddr = makeAddr("payout");

    uint256 internal constant T0 = 1_700_000_000;
    uint64 internal constant INTERVAL = 30 days;
    uint64 internal constant WD = 24 hours;
    uint64 internal constant CW = 24 hours;
    uint64 internal constant RT = 48 hours;
    uint64 internal constant SP = 180 days;
    uint64 internal constant MIN_DELAY = 60;
    uint64 internal constant MAX_DELAY = 365 days;
    uint64 internal constant MAX_SWEEP = 3650 days;
    uint64 internal constant MAX_INTERVAL = 100 * 365 days;
    uint256 internal constant DEP = 1_000e6;

    function setUp() public virtual {
        vm.warp(T0);
        usdc = new MockUSDC();
        dms = new DMS(IERC20(address(usdc)));
    }

    // ------------------------------------------------------------------ params / creation

    /// @dev alice 60% / bob 40%, guardians g1,g2,g3 with threshold 2, default delays.
    function _params() internal view returns (DMS.CreateParams memory p) {
        p.beneficiaries = new address[](2);
        p.beneficiaries[0] = alice;
        p.beneficiaries[1] = bob;
        p.sharesBps = new uint16[](2);
        p.sharesBps[0] = 6000;
        p.sharesBps[1] = 4000;
        p.interval = INTERVAL;
        p.guardians = new address[](3);
        p.guardians[0] = g1;
        p.guardians[1] = g2;
        p.guardians[2] = g3;
        p.guardianThreshold = 2;
        p.fallbackAddress = fallbackAddr;
    }

    function _create(DMS.CreateParams memory p) internal returns (uint256 id) {
        vm.prank(owner);
        id = dms.createVault(p);
    }

    function createDefaultVault() internal returns (uint256) {
        return _create(_params());
    }

    /// @dev Default vault already holding `amt` from `depositor`.
    function _funded(uint256 amt) internal returns (uint256 id) {
        id = createDefaultVault();
        _deposit(id, depositor, amt);
    }

    function _deposit(uint256 id, address from, uint256 amt) internal {
        usdc.mint(from, amt);
        vm.startPrank(from);
        usdc.approve(address(dms), amt);
        dms.deposit(id, amt);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ views / asserts

    function _v(uint256 id) internal view returns (DMS.VaultView memory) {
        return dms.getVault(id);
    }

    function _assertPhase(uint256 id, DMS.Phase ph) internal view {
        assertEq(uint8(dms.phase(id)), uint8(ph));
    }

    function _e(bytes4 sel, uint256 id) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(sel, id);
    }

    // ------------------------------------------------------------------ warp helpers

    function _toDeadline(uint256 id) internal {
        vm.warp(dms.deadline(id));
    }

    /// @dev Warp to the deadline (if not past it) and trigger as a stranger.
    function _trigger(uint256 id) internal {
        uint256 dl = dms.deadline(id);
        if (block.timestamp < dl) vm.warp(dl);
        vm.prank(stranger);
        dms.trigger(id);
    }

    function _toClaims(uint256 id) internal {
        _trigger(id);
        vm.warp(_v(id).challengeEnd);
    }

    function _toSweepTime(uint256 id) internal {
        _trigger(id);
        vm.warp(_v(id).sweepAt);
    }

    // ------------------------------------------------------------------ action helpers

    function _request(uint256 id, uint256 amt) internal {
        vm.prank(owner);
        dms.requestWithdraw(id, amt);
    }

    function _extend(uint256 id, address g, uint64 nd) internal {
        vm.prank(g);
        dms.extendDeadline(id, nd);
    }

    function _propose(uint256 id, address g, address no) internal {
        vm.prank(g);
        dms.proposeOwnerRotation(id, no);
    }

    /// @dev Quorum (g1,g2) proposes `no`, then time passes the timelock (does not execute).
    function _proposeQuorum(uint256 id, address no) internal {
        _propose(id, g1, no);
        _propose(id, g2, no);
    }

    /// @dev `who` (owner or delegate) explicitly approves the pending rotation to `no`.
    function _approveRot(uint256 id, address who, address no) internal {
        vm.prank(who);
        dms.approveOwnerRotation(id, no);
    }

    /// @dev Propose via quorum, the current owner explicitly approves `no` (a plain checkIn no longer
    ///      counts), wait the timelock, execute as a stranger.
    function _rotate(uint256 id, address no) internal {
        _proposeQuorum(id, no);
        _approveRot(id, dms.getVault(id).owner, no);
        vm.warp(dms.getPendingRotation(id).executableAt);
        vm.prank(stranger);
        dms.executeOwnerRotation(id);
    }

    // ------------------------------------------------------------------ action ids

    function _extendId(uint64 nd, uint256 nonce) internal view returns (bytes32) {
        return keccak256(abi.encode(dms.EXTEND_DEADLINE_ACTION(), nd, nonce));
    }

    function _cancelId(uint256 amt, uint64 execAt, uint256 nonce) internal view returns (bytes32) {
        return keccak256(abi.encode(dms.CANCEL_WITHDRAW_ACTION(), amt, execAt, nonce));
    }

    function _rotId(address no, uint256 nonce) internal view returns (bytes32) {
        return keccak256(abi.encode(dms.OWNER_ROTATION_ACTION(), no, nonce));
    }
}
