// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DeadMansSwitchVault} from "../DeadMansSwitchVault.sol";
import {DeadMansSwitchVaultTestBase} from "./DeadMansSwitchVault.Base.t.sol";

/// @dev Category 7: fuzz tests.
contract DeadMansSwitchVaultFuzzTest is DeadMansSwitchVaultTestBase {
    function _bens(uint256 n) internal pure returns (address[] memory a) {
        a = new address[](n);
        for (uint256 i; i < n; ++i) {
            a[i] = address(uint160(0xBEEF00 + i));
        }
    }

    /// @dev n shares, each >= 1, summing to exactly 10000, distributed pseudo-randomly from seed.
    function _validShares(uint256 n, uint256 seed) internal pure returns (uint16[] memory s) {
        s = new uint16[](n);
        uint256[] memory w = new uint256[](n);
        uint256 sumW;
        for (uint256 i; i < n; ++i) {
            w[i] = (uint256(keccak256(abi.encode(seed, i))) % 10_000) + 1;
            sumW += w[i];
        }
        uint256 remaining = 10_000 - n; // each starts with 1
        uint256 used;
        for (uint256 i; i < n; ++i) {
            uint256 extra = (i == n - 1) ? remaining - used : (remaining * w[i]) / sumW;
            used += (i == n - 1) ? 0 : extra;
            s[i] = uint16(1 + extra);
        }
    }

    /// @dev Fisher-Yates permutation of 0..n-1.
    function _perm(uint256 n, uint256 seed) internal pure returns (uint256[] memory p) {
        p = new uint256[](n);
        for (uint256 i; i < n; ++i) p[i] = i;
        for (uint256 i = n; i > 1; --i) {
            uint256 j = uint256(keccak256(abi.encode(seed, i))) % i;
            (p[i - 1], p[j]) = (p[j], p[i - 1]);
        }
    }

    function testFuzz_ClaimsSumToPoolExactly(uint8 nRaw, uint256 shareSeed, uint96 amountRaw, uint256 orderSeed)
        public
    {
        uint256 n = bound(nRaw, 1, 20);
        uint256 amount = bound(amountRaw, 1, type(uint96).max);
        address[] memory a = _bens(n);
        uint16[] memory s = _validShares(n, shareSeed);

        uint256 sum;
        for (uint256 i; i < n; ++i) {
            assertGt(s[i], 0);
            sum += s[i];
        }
        assertEq(sum, 10_000);

        uint256 id = _create(a, s, INTERVAL);
        // split deposit between owner and a third party
        uint256 part = amount / 3;
        if (part > 0) _deposit(id, owner, part);
        _deposit(id, stranger, amount - part);
        _expire(id);
        dms.trigger(id);

        uint256 pool = dms.getVault(id).claimPool;
        assertEq(pool, amount);
        assertLe(pool, amount); // claimPool <= deposited

        uint256[] memory order = _perm(n, orderSeed);
        uint256 total;
        for (uint256 k; k < n; ++k) {
            uint256 idx = order[k];
            uint256 paid = _claim(id, a[idx]);
            total += paid;
            assertEq(usdc.balanceOf(a[idx]), paid);
            uint256 floorAmt = (pool * s[idx]) / 10_000;
            if (k < n - 1) {
                assertEq(paid, floorAmt);
            } else {
                assertGe(paid, floorAmt);
                assertLe(paid, floorAmt + n);
            }
            DeadMansSwitchVault.VaultView memory v = dms.getVault(id);
            assertLe(v.totalClaimed, v.claimPool);
            assertEq(usdc.balanceOf(address(dms)), pool - v.totalClaimed);
        }

        assertEq(total, pool);
        assertEq(dms.getVault(id).totalClaimed, pool);
        assertEq(dms.getVault(id).claimedCount, n);
        assertEq(usdc.balanceOf(address(dms)), 0);
    }

    function testFuzz_InvalidShareSumReverts(uint8 nRaw, uint256 seed) public {
        uint256 n = bound(nRaw, 1, 20);
        address[] memory a = _bens(n);
        uint16[] memory s = new uint16[](n);
        uint256 total;
        for (uint256 i; i < n; ++i) {
            s[i] = uint16(bound(uint256(keccak256(abi.encode(seed, i))), 1, 2000));
            total += s[i];
        }
        if (total == 10_000) {
            s[0] += 1;
            total += 1;
        }
        vm.expectRevert(abi.encodeWithSelector(DeadMansSwitchVault.InvalidSharesTotal.selector, total));
        vm.prank(owner);
        dms.createVault(a, s, INTERVAL);
    }

    function testFuzz_TriggerOnlyAtOrAfterDeadline(uint64 intervalRaw, uint256 dt) public {
        uint64 interval = uint64(bound(intervalRaw, 60, dms.MAX_INTERVAL()));
        uint256 id = _create(_addrs2(), _shares2(5000, 5000), interval);
        uint256 dl = dms.deadline(id);
        dt = bound(dt, 0, uint256(interval) * 2);
        vm.warp(block.timestamp + dt);
        if (block.timestamp < dl) {
            vm.expectRevert(abi.encodeWithSelector(DeadMansSwitchVault.VaultNotExpired.selector, id));
        }
        dms.trigger(id);
    }

    function testFuzz_WithdrawNeverExceedsBalance(uint96 depositAmt, uint96 withdrawAmt) public {
        uint256 d = bound(depositAmt, 1, type(uint96).max);
        uint256 w = bound(withdrawAmt, 0, uint256(type(uint96).max) * 2);
        uint256 id = _createDefault();
        _deposit(id, owner, d);
        vm.prank(owner);
        if (w == 0) {
            vm.expectRevert(DeadMansSwitchVault.ZeroAmount.selector);
        } else if (w > d) {
            vm.expectRevert(abi.encodeWithSelector(DeadMansSwitchVault.InsufficientVaultBalance.selector, d, w));
        }
        dms.withdraw(id, w);
        if (w != 0 && w <= d) {
            assertEq(usdc.balanceOf(owner), w);
            assertEq(usdc.balanceOf(address(dms)), d - w);
        }
    }
}
