// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeadMansSwitchVault} from "../DeadMansSwitchVault.sol";
import {MockUSDC} from "./DeadMansSwitchVault.Base.t.sol";

/// @dev Handler driving a single vault (owned by the handler) through random lifecycle steps.
contract DMSHandler is Test {
    DeadMansSwitchVault public dms;
    MockUSDC public usdc;
    uint256 public vaultId;
    address[3] public bens;

    uint256 public ghostDeposited;
    uint256 public ghostWithdrawn;
    uint256 public ghostPaid;

    constructor(DeadMansSwitchVault _dms, MockUSDC _usdc) {
        dms = _dms;
        usdc = _usdc;
        bens[0] = makeAddr("hb0");
        bens[1] = makeAddr("hb1");
        bens[2] = makeAddr("hb2");
        address[] memory a = new address[](3);
        uint16[] memory s = new uint16[](3);
        for (uint256 i; i < 3; ++i) a[i] = bens[i];
        s[0] = 3333;
        s[1] = 3333;
        s[2] = 3334;
        vaultId = dms.createVault(a, s, 1 days);
    }

    function deposit(uint256 amount, bool fromThirdParty) external {
        amount = bound(amount, 1, 1e12);
        address from = fromThirdParty ? address(0xD00D) : address(this);
        usdc.mint(from, amount);
        vm.startPrank(from);
        usdc.approve(address(dms), amount);
        try dms.deposit(vaultId, amount) {
            ghostDeposited += amount;
        } catch {}
        vm.stopPrank();
    }

    function withdraw(uint256 amount) external {
        amount = bound(amount, 1, 1e12);
        try dms.withdraw(vaultId, amount) {
            ghostWithdrawn += amount;
        } catch {}
    }

    function checkIn() external {
        try dms.checkIn(vaultId) {} catch {}
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 12 hours));
    }

    function trigger(uint256 callerSeed) external {
        vm.prank(address(uint160(bound(callerSeed, 1, type(uint160).max))));
        try dms.trigger(vaultId) {} catch {}
    }

    function claim(uint256 idx) external {
        address who = bens[bound(idx, 0, 2)];
        uint256 beforeBal = usdc.balanceOf(who);
        vm.prank(who);
        try dms.claim(vaultId) {
            ghostPaid += usdc.balanceOf(who) - beforeBal;
        } catch {}
    }
}

contract DeadMansSwitchVaultInvariantTest is Test {
    DeadMansSwitchVault internal dms;
    MockUSDC internal usdc;
    DMSHandler internal handler;

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc = new MockUSDC();
        dms = new DeadMansSwitchVault(IERC20(address(usdc)));
        handler = new DMSHandler(dms, usdc);
        targetContract(address(handler));
    }

    /// totalClaimed never exceeds the snapshotted claimPool.
    function invariant_TotalClaimedLeqClaimPool() public view {
        DeadMansSwitchVault.VaultView memory v = dms.getVault(handler.vaultId());
        assertLe(v.totalClaimed, v.claimPool);
    }

    /// Token balance always covers unclaimed liabilities (live balance + unclaimed pool).
    function invariant_BalanceCoversLiabilities() public view {
        DeadMansSwitchVault.VaultView memory v = dms.getVault(handler.vaultId());
        uint256 liabilities = v.balance + (v.claimPool - v.totalClaimed);
        assertGe(usdc.balanceOf(address(dms)), liabilities);
    }

    /// Conservation: token balance == deposited - withdrawn - paid out.
    function invariant_TokenConservation() public view {
        assertEq(
            usdc.balanceOf(address(dms)),
            handler.ghostDeposited() - handler.ghostWithdrawn() - handler.ghostPaid()
        );
    }

    /// Paid out to beneficiaries always equals aggregate booked claims.
    function invariant_PaidMatchesTotalClaimed() public view {
        assertEq(handler.ghostPaid(), dms.getVault(handler.vaultId()).totalClaimed);
    }
}
