// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeadMansSwitchVault} from "../DeadMansSwitchVault.sol";

/// @dev Simple 6-decimal mock USDC with open mint.
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

abstract contract DeadMansSwitchVaultTestBase is Test {
    DeadMansSwitchVault internal dms;
    MockUSDC internal usdc;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal stranger = makeAddr("stranger");

    uint64 internal constant INTERVAL = 1 days;

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        usdc = new MockUSDC();
        dms = new DeadMansSwitchVault(IERC20(address(usdc)));
    }

    // ---- helpers ----

    function _addrs2() internal view returns (address[] memory a) {
        a = new address[](2);
        a[0] = alice;
        a[1] = bob;
    }

    function _shares2(uint16 x, uint16 y) internal pure returns (uint16[] memory s) {
        s = new uint16[](2);
        s[0] = x;
        s[1] = y;
    }

    function _addrs3() internal view returns (address[] memory a) {
        a = new address[](3);
        a[0] = alice;
        a[1] = bob;
        a[2] = carol;
    }

    function _shares3(uint16 x, uint16 y, uint16 z) internal pure returns (uint16[] memory s) {
        s = new uint16[](3);
        s[0] = x;
        s[1] = y;
        s[2] = z;
    }

    /// @dev Create a vault as `owner`.
    function _create(address[] memory a, uint16[] memory s, uint64 interval) internal returns (uint256 id) {
        vm.prank(owner);
        id = dms.createVault(a, s, interval);
    }

    /// @dev Default 2-beneficiary (60/40) vault with a 1-day interval.
    function _createDefault() internal returns (uint256 id) {
        id = _create(_addrs2(), _shares2(6000, 4000), INTERVAL);
    }

    /// @dev Mint `amount` to `from`, approve, and deposit into `id`.
    function _deposit(uint256 id, address from, uint256 amount) internal {
        usdc.mint(from, amount);
        vm.startPrank(from);
        usdc.approve(address(dms), amount);
        dms.deposit(id, amount);
        vm.stopPrank();
    }

    function _claim(uint256 id, address who) internal returns (uint256 paid) {
        uint256 beforeBal = usdc.balanceOf(who);
        vm.prank(who);
        dms.claim(id);
        paid = usdc.balanceOf(who) - beforeBal;
    }

    function _expire(uint256 id) internal {
        vm.warp(dms.deadline(id));
    }
}
