// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;


import {DeadMansSwitchVault as DMS} from "../DeadMansSwitchVault.sol";
import {DMSTestBase} from "./DeadMansSwitchVault.Base.t.sol";

/// @dev Shared fixture for the approveOwnerRotation test files (funded vault `id`, helpers).
abstract contract DMSApprovalBase is DMSTestBase {
    uint256 internal id;

    function setUp() public override {
        super.setUp();
        id = _funded(DEP);
    }

    // ------------------------------------------------------------------ helpers

    function _setDel(address d) internal {
        vm.prank(owner);
        dms.setCheckInDelegate(id, d);
    }

    function _ready() internal {
        vm.warp(dms.getPendingRotation(id).executableAt);
    }

    function _checkInAs(address who) internal {
        vm.prank(who);
        dms.checkIn(id);
    }

    function _execRevert(bytes memory err) internal {
        vm.prank(stranger);
        vm.expectRevert(err);
        dms.executeOwnerRotation(id);
    }

    function _exec() internal {
        vm.prank(stranger);
        dms.executeOwnerRotation(id);
    }

    function _approveRevert(address who, address target, bytes memory err) internal {
        vm.prank(who);
        vm.expectRevert(err);
        dms.approveOwnerRotation(id, target);
    }
}
