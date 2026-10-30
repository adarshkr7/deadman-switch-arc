// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeadMansSwitchVault as DMS} from "../DeadMansSwitchVault.sol";
import {DMSTestBase} from "./DeadMansSwitchVault.Base.t.sol";

contract DMSCreateTest is DMSTestBase {
    // ------------------------------------------------------------------ helpers

    function _expectCreateRevert(bytes memory err, DMS.CreateParams memory p) internal {
        vm.prank(owner);
        vm.expectRevert(err);
        dms.createVault(p);
    }

    function _addrs(uint256 n, uint160 base) internal pure returns (address[] memory a) {
        a = new address[](n);
        for (uint256 i; i < n; ++i) a[i] = address(base + uint160(i));
    }

    function _equalShares(uint256 n, uint16 each) internal pure returns (uint16[] memory s) {
        s = new uint16[](n);
        for (uint256 i; i < n; ++i) s[i] = each;
    }

    function _setDelay(DMS.CreateParams memory p, uint8 idx, uint64 v) internal pure {
        if (idx == 0) p.withdrawDelay = v;
        else if (idx == 1) p.challengeWindow = v;
        else if (idx == 2) p.rotationTimelock = v;
        else p.sweepPeriod = v;
    }

    function _readDelay(DMS.ConfigView memory c, uint8 idx) internal pure returns (uint64) {
        if (idx == 0) return c.withdrawDelay;
        if (idx == 1) return c.challengeWindow;
        if (idx == 2) return c.rotationTimelock;
        return c.sweepPeriod;
    }

    function _checkDelayBounds(uint8 idx, uint64 max) internal {
        DMS.CreateParams memory p = _params();
        _setDelay(p, idx, 59);
        _expectCreateRevert(abi.encodeWithSelector(DMS.InvalidDelay.selector, uint64(59)), p);
        _setDelay(p, idx, 1);
        _expectCreateRevert(abi.encodeWithSelector(DMS.InvalidDelay.selector, uint64(1)), p);
        _setDelay(p, idx, 60);
        uint256 id = _create(p);
        assertEq(_readDelay(dms.getConfig(id), idx), 60);
        _setDelay(p, idx, max);
        id = _create(p);
        assertEq(_readDelay(dms.getConfig(id), idx), max);
        _setDelay(p, idx, max + 1);
        _expectCreateRevert(abi.encodeWithSelector(DMS.InvalidDelay.selector, max + 1), p);
    }

    // ------------------------------------------------------------------ constructor / success

    function test_Constructor_ZeroTokenReverts() public {
        vm.expectRevert(DMS.ZeroTokenAddress.selector);
        new DMS(IERC20(address(0)));
    }

    function test_Constructor_StoresToken() public view {
        assertEq(address(dms.usdc()), address(usdc));
        assertEq(dms.nextVaultId(), 1);
        assertEq(dms.vaultCount(), 0);
    }

    function test_CreateVault_StoresStateAndDefaults() public {
        uint256 id = createDefaultVault();
        assertEq(id, 1);
        assertEq(dms.vaultCount(), 1);
        assertEq(dms.nextVaultId(), 2);
        DMS.VaultView memory v = _v(id);
        assertEq(v.owner, owner);
        assertEq(v.lastCheckIn, T0);
        assertEq(v.interval, INTERVAL);
        assertEq(v.deadline, T0 + INTERVAL);
        assertEq(v.balance, 0);
        assertEq(v.claimPool, 0);
        assertFalse(v.triggered);
        assertFalse(v.finalized);
        assertFalse(v.swept);
        assertEq(v.checkInDelegate, address(0));
        assertEq(v.guardianNonce, 0);
        assertEq(v.beneficiaryCount, 2);
        _assertPhase(id, DMS.Phase.Active);
        DMS.ConfigView memory c = dms.getConfig(id);
        assertEq(c.withdrawDelay, 24 hours);
        assertEq(c.challengeWindow, 24 hours);
        assertEq(c.rotationTimelock, 48 hours);
        assertEq(c.sweepPeriod, 180 days);
        assertEq(c.fallbackAddress, fallbackAddr);
        assertEq(c.guardianThreshold, 2);
        assertEq(c.guardianCount, 3);
        (address[] memory bens, uint16[] memory shares) = dms.getBeneficiaries(id);
        assertEq(bens[0], alice);
        assertEq(bens[1], bob);
        assertEq(shares[0], 6000);
        assertEq(shares[1], 4000);
        address[] memory gs = dms.getGuardians(id);
        assertEq(gs.length, 3);
        assertEq(gs[2], g3);
        assertTrue(dms.isGuardian(id, g1));
        assertFalse(dms.isGuardian(id, owner));
        assertFalse(dms.isGuardian(id, stranger));
    }

    function test_CreateVault_EmitsVaultCreatedWithResolvedDelays() public {
        DMS.CreateParams memory expected = _params();
        expected.withdrawDelay = WD;
        expected.challengeWindow = CW;
        expected.rotationTimelock = RT;
        expected.sweepPeriod = SP;
        vm.expectEmit(true, true, false, true, address(dms));
        emit DMS.VaultCreated(1, owner, expected);
        createDefaultVault();
    }

    function test_CreateVault_ExplicitDelaysStoredAndEmitted() public {
        DMS.CreateParams memory p = _params();
        p.withdrawDelay = 100;
        p.challengeWindow = 200;
        p.rotationTimelock = 300;
        p.sweepPeriod = 400;
        vm.expectEmit(true, true, false, true, address(dms));
        emit DMS.VaultCreated(1, owner, p);
        uint256 id = _create(p);
        DMS.ConfigView memory c = dms.getConfig(id);
        assertEq(c.withdrawDelay, 100);
        assertEq(c.challengeWindow, 200);
        assertEq(c.rotationTimelock, 300);
        assertEq(c.sweepPeriod, 400);
    }

    function test_CreateVault_IdsIncrementAndVaultsIndependent() public {
        uint256 a = createDefaultVault();
        uint256 b = createDefaultVault();
        assertEq(a, 1);
        assertEq(b, 2);
        _deposit(a, depositor, 5e6);
        assertEq(_v(a).balance, 5e6);
        assertEq(_v(b).balance, 0);
    }

    function test_CreateVault_AnyoneCanCreateAndBecomesOwner() public {
        vm.prank(stranger);
        uint256 id = dms.createVault(_params());
        assertEq(_v(id).owner, stranger);
    }

    function test_CreateVault_MaxBeneficiariesAllowed() public {
        DMS.CreateParams memory p = _params();
        p.beneficiaries = _addrs(20, 0x1000);
        p.sharesBps = _equalShares(20, 500);
        uint256 id = _create(p);
        assertEq(_v(id).beneficiaryCount, 20);
    }

    function test_CreateVault_MaxGuardiansAllowed() public {
        DMS.CreateParams memory p = _params();
        p.guardians = _addrs(10, 0x2000);
        p.guardianThreshold = 10;
        uint256 id = _create(p);
        assertEq(dms.getConfig(id).guardianCount, 10);
        assertEq(dms.getConfig(id).guardianThreshold, 10);
    }

    function test_CreateVault_NoGuardiansZeroThresholdAllowed() public {
        DMS.CreateParams memory p = _params();
        p.guardians = new address[](0);
        p.guardianThreshold = 0;
        uint256 id = _create(p);
        assertEq(dms.getConfig(id).guardianCount, 0);
        assertFalse(dms.isGuardian(id, g1));
    }

    function test_CreateVault_SixtySecondsEverywhereWorks() public {
        DMS.CreateParams memory p = _params();
        p.interval = 60;
        p.withdrawDelay = 60;
        p.challengeWindow = 60;
        p.rotationTimelock = 60;
        p.sweepPeriod = 60;
        uint256 id = _create(p);
        _deposit(id, depositor, 100e6);
        assertEq(_v(id).deadline, T0 + 60);
        vm.warp(T0 + 60);
        vm.prank(stranger);
        dms.trigger(id);
        DMS.VaultView memory v = _v(id);
        assertEq(v.challengeEnd, T0 + 120);
        assertEq(v.sweepAt, T0 + 180);
        vm.warp(T0 + 120);
        vm.prank(alice);
        dms.claim(id);
        assertEq(usdc.balanceOf(alice), 60e6);
        vm.warp(T0 + 180);
        dms.sweep(id);
        assertEq(usdc.balanceOf(fallbackAddr), 40e6);
        _assertPhase(id, DMS.Phase.Swept);
    }

    function test_CreateVault_MaxIntervalAllowed() public {
        DMS.CreateParams memory p = _params();
        p.interval = MAX_INTERVAL;
        uint256 id = _create(p);
        assertEq(_v(id).deadline, T0 + MAX_INTERVAL);
    }

    // ------------------------------------------------------------------ beneficiary reverts

    function test_RevertCreate_EmptyBeneficiaries() public {
        DMS.CreateParams memory p = _params();
        p.beneficiaries = new address[](0);
        p.sharesBps = new uint16[](0);
        _expectCreateRevert(abi.encodeWithSelector(DMS.EmptyBeneficiaries.selector), p);
    }

    function test_RevertCreate_LengthMismatch() public {
        DMS.CreateParams memory p = _params();
        p.sharesBps = new uint16[](1);
        p.sharesBps[0] = 10_000;
        _expectCreateRevert(abi.encodeWithSelector(DMS.LengthMismatch.selector), p);
    }

    function test_RevertCreate_TooManyBeneficiaries() public {
        DMS.CreateParams memory p = _params();
        p.beneficiaries = _addrs(21, 0x1000);
        p.sharesBps = _equalShares(21, 476);
        _expectCreateRevert(abi.encodeWithSelector(DMS.TooManyBeneficiaries.selector), p);
    }

    function test_RevertCreate_ZeroBeneficiary() public {
        DMS.CreateParams memory p = _params();
        p.beneficiaries[1] = address(0);
        _expectCreateRevert(abi.encodeWithSelector(DMS.ZeroBeneficiary.selector), p);
    }

    function test_RevertCreate_DuplicateBeneficiary() public {
        DMS.CreateParams memory p = _params();
        p.beneficiaries[1] = alice;
        _expectCreateRevert(abi.encodeWithSelector(DMS.DuplicateBeneficiary.selector, alice), p);
    }

    function test_RevertCreate_ZeroShare() public {
        DMS.CreateParams memory p = _params();
        p.sharesBps[0] = 10_000;
        p.sharesBps[1] = 0;
        _expectCreateRevert(abi.encodeWithSelector(DMS.ZeroShare.selector, bob), p);
    }

    function test_RevertCreate_SharesTotalUnder() public {
        DMS.CreateParams memory p = _params();
        p.sharesBps[1] = 3999;
        _expectCreateRevert(abi.encodeWithSelector(DMS.InvalidSharesTotal.selector, uint256(9999)), p);
    }

    function test_RevertCreate_SharesTotalOver() public {
        DMS.CreateParams memory p = _params();
        p.sharesBps[1] = 4001;
        _expectCreateRevert(abi.encodeWithSelector(DMS.InvalidSharesTotal.selector, uint256(10_001)), p);
    }

    // ------------------------------------------------------------------ interval / overflow / fallback

    function test_RevertCreate_Interval59() public {
        DMS.CreateParams memory p = _params();
        p.interval = 59;
        _expectCreateRevert(abi.encodeWithSelector(DMS.InvalidInterval.selector, uint64(59)), p);
        p.interval = 0;
        _expectCreateRevert(abi.encodeWithSelector(DMS.InvalidInterval.selector, uint64(0)), p);
    }

    function test_CreateVault_Interval60Ok() public {
        DMS.CreateParams memory p = _params();
        p.interval = 60;
        uint256 id = _create(p);
        assertEq(_v(id).deadline, T0 + 60);
    }

    function test_RevertCreate_IntervalOverMax() public {
        DMS.CreateParams memory p = _params();
        p.interval = MAX_INTERVAL + 1;
        _expectCreateRevert(abi.encodeWithSelector(DMS.InvalidInterval.selector, MAX_INTERVAL + 1), p);
    }

    function test_RevertCreate_TimestampOverflow() public {
        DMS.CreateParams memory p = _params();
        p.interval = 60;
        vm.warp(uint256(type(uint64).max) - 60 + 1);
        _expectCreateRevert(abi.encodeWithSelector(DMS.TimestampOverflow.selector), p);
    }

    function test_CreateVault_TimestampBoundaryOk() public {
        DMS.CreateParams memory p = _params();
        p.interval = 60;
        vm.warp(uint256(type(uint64).max) - 60);
        uint256 id = _create(p);
        assertEq(_v(id).deadline, type(uint64).max);
    }

    function test_RevertCreate_FallbackZero() public {
        DMS.CreateParams memory p = _params();
        p.fallbackAddress = address(0);
        _expectCreateRevert(abi.encodeWithSelector(DMS.InvalidFallbackAddress.selector), p);
    }

    function test_RevertCreate_FallbackIsVaultContract() public {
        DMS.CreateParams memory p = _params();
        p.fallbackAddress = address(dms);
        _expectCreateRevert(abi.encodeWithSelector(DMS.InvalidFallbackAddress.selector), p);
    }

    function test_RevertCreate_FallbackIsToken() public {
        DMS.CreateParams memory p = _params();
        p.fallbackAddress = address(usdc);
        _expectCreateRevert(abi.encodeWithSelector(DMS.InvalidFallbackAddress.selector), p);
    }

    // ------------------------------------------------------------------ guardian reverts

    function test_RevertCreate_TooManyGuardians() public {
        DMS.CreateParams memory p = _params();
        p.guardians = _addrs(11, 0x2000);
        p.guardianThreshold = 1;
        _expectCreateRevert(abi.encodeWithSelector(DMS.TooManyGuardians.selector), p);
    }

    function test_RevertCreate_ZeroGuardian() public {
        DMS.CreateParams memory p = _params();
        p.guardians[1] = address(0);
        _expectCreateRevert(abi.encodeWithSelector(DMS.ZeroGuardian.selector), p);
    }

    function test_RevertCreate_DuplicateGuardian() public {
        DMS.CreateParams memory p = _params();
        p.guardians[1] = g1;
        _expectCreateRevert(abi.encodeWithSelector(DMS.DuplicateGuardian.selector, g1), p);
    }

    function test_RevertCreate_GuardianIsOwner() public {
        DMS.CreateParams memory p = _params();
        p.guardians[2] = owner;
        _expectCreateRevert(abi.encodeWithSelector(DMS.GuardianIsOwner.selector), p);
    }

    function test_RevertCreate_ThresholdZeroWithGuardians() public {
        DMS.CreateParams memory p = _params();
        p.guardianThreshold = 0;
        _expectCreateRevert(abi.encodeWithSelector(DMS.InvalidGuardianThreshold.selector, uint8(0)), p);
    }

    function test_RevertCreate_ThresholdAboveCount() public {
        DMS.CreateParams memory p = _params();
        p.guardianThreshold = 4;
        _expectCreateRevert(abi.encodeWithSelector(DMS.InvalidGuardianThreshold.selector, uint8(4)), p);
    }

    function test_RevertCreate_ThresholdWithoutGuardians() public {
        DMS.CreateParams memory p = _params();
        p.guardians = new address[](0);
        p.guardianThreshold = 1;
        _expectCreateRevert(abi.encodeWithSelector(DMS.InvalidGuardianThreshold.selector, uint8(1)), p);
    }

    function test_CreateVault_ThresholdEqualsCountOk() public {
        DMS.CreateParams memory p = _params();
        p.guardianThreshold = 3;
        uint256 id = _create(p);
        assertEq(dms.getConfig(id).guardianThreshold, 3);
    }

    // ------------------------------------------------------------------ delay bounds

    function test_DelayBounds_WithdrawDelay() public {
        _checkDelayBounds(0, MAX_DELAY);
    }

    function test_DelayBounds_ChallengeWindow() public {
        _checkDelayBounds(1, MAX_DELAY);
    }

    function test_DelayBounds_RotationTimelock() public {
        _checkDelayBounds(2, MAX_DELAY);
    }

    function test_DelayBounds_SweepPeriod() public {
        _checkDelayBounds(3, MAX_SWEEP);
    }

    function test_FailedCreateDoesNotConsumeId() public {
        DMS.CreateParams memory p = _params();
        p.interval = 59;
        _expectCreateRevert(abi.encodeWithSelector(DMS.InvalidInterval.selector, uint64(59)), p);
        assertEq(dms.vaultCount(), 0);
        assertEq(createDefaultVault(), 1);
    }
}
