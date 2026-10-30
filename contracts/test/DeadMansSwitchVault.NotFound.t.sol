// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DeadMansSwitchVault as DMS} from "../DeadMansSwitchVault.sol";
import {DMSTestBase} from "./DeadMansSwitchVault.Base.t.sol";

/// @dev Every function that takes a vaultId reverts VaultNotFound for ids 0 and unknown ids,
///      even when called by privileged accounts.
contract DMSNotFoundTest is DMSTestBase {
    uint256 internal constant UNKNOWN = 999;

    function setUp() public override {
        super.setUp();
        createDefaultVault(); // vault 1 exists; 0 and 999 do not
    }

    function _nf(uint256 vid) internal {
        vm.expectRevert(abi.encodeWithSelector(DMS.VaultNotFound.selector, vid));
    }

    function _ids() internal pure returns (uint256[3] memory) {
        return [uint256(0), UNKNOWN, uint256(2)];
    }

    function test_NotFound_Deposit() public {
        for (uint256 i; i < 3; ++i) {
            uint256 vid = _ids()[i];
            _nf(vid);
            dms.deposit(vid, 1);
        }
    }

    function test_NotFound_CheckIn() public {
        for (uint256 i; i < 3; ++i) {
            uint256 vid = _ids()[i];
            _nf(vid);
            vm.prank(owner);
            dms.checkIn(vid);
        }
    }

    function test_NotFound_SetCheckInDelegate() public {
        for (uint256 i; i < 3; ++i) {
            uint256 vid = _ids()[i];
            _nf(vid);
            vm.prank(owner);
            dms.setCheckInDelegate(vid, delegate);
        }
    }

    function test_NotFound_RequestWithdraw() public {
        for (uint256 i; i < 3; ++i) {
            uint256 vid = _ids()[i];
            _nf(vid);
            vm.prank(owner);
            dms.requestWithdraw(vid, 1);
        }
    }

    function test_NotFound_ExecuteWithdraw() public {
        for (uint256 i; i < 3; ++i) {
            uint256 vid = _ids()[i];
            _nf(vid);
            vm.prank(owner);
            dms.executeWithdraw(vid);
        }
    }

    function test_NotFound_CancelWithdraw() public {
        for (uint256 i; i < 3; ++i) {
            uint256 vid = _ids()[i];
            _nf(vid);
            vm.prank(g1);
            dms.cancelWithdraw(vid);
        }
    }

    function test_NotFound_ExtendDeadline() public {
        for (uint256 i; i < 3; ++i) {
            uint256 vid = _ids()[i];
            _nf(vid);
            vm.prank(g1);
            dms.extendDeadline(vid, uint64(block.timestamp + 10));
        }
    }

    function test_NotFound_ProposeOwnerRotation() public {
        for (uint256 i; i < 3; ++i) {
            uint256 vid = _ids()[i];
            _nf(vid);
            vm.prank(g1);
            dms.proposeOwnerRotation(vid, newOwner);
        }
    }

    function test_NotFound_ExecuteOwnerRotation() public {
        for (uint256 i; i < 3; ++i) {
            uint256 vid = _ids()[i];
            _nf(vid);
            dms.executeOwnerRotation(vid);
        }
    }

    function test_NotFound_CancelOwnerRotation() public {
        for (uint256 i; i < 3; ++i) {
            uint256 vid = _ids()[i];
            _nf(vid);
            vm.prank(owner);
            dms.cancelOwnerRotation(vid);
        }
    }

    function test_NotFound_Trigger() public {
        for (uint256 i; i < 3; ++i) {
            uint256 vid = _ids()[i];
            _nf(vid);
            dms.trigger(vid);
        }
    }

    function test_NotFound_Finalize() public {
        for (uint256 i; i < 3; ++i) {
            uint256 vid = _ids()[i];
            _nf(vid);
            dms.finalize(vid);
        }
    }

    function test_NotFound_SetPayoutAddress() public {
        for (uint256 i; i < 3; ++i) {
            uint256 vid = _ids()[i];
            _nf(vid);
            vm.prank(alice);
            dms.setPayoutAddress(vid, payoutAddr);
        }
    }

    function test_NotFound_Claim() public {
        for (uint256 i; i < 3; ++i) {
            uint256 vid = _ids()[i];
            _nf(vid);
            vm.prank(alice);
            dms.claim(vid);
        }
    }

    function test_NotFound_Sweep() public {
        for (uint256 i; i < 3; ++i) {
            uint256 vid = _ids()[i];
            _nf(vid);
            dms.sweep(vid);
        }
    }

    function test_NotFound_SetFallbackPayout() public {
        for (uint256 i; i < 3; ++i) {
            uint256 vid = _ids()[i];
            _nf(vid);
            vm.prank(fallbackAddr);
            dms.setFallbackPayout(vid, payoutAddr);
        }
    }

    function test_NotFound_Views() public {
        uint256 vid = UNKNOWN;
        _nf(vid);
        dms.getVault(vid);
        _nf(vid);
        dms.getConfig(vid);
        _nf(vid);
        dms.getBeneficiaries(vid);
        _nf(vid);
        dms.getGuardians(vid);
        _nf(vid);
        dms.isGuardian(vid, g1);
        _nf(vid);
        dms.getPendingWithdrawal(vid);
        _nf(vid);
        dms.getPendingRotation(vid);
        _nf(vid);
        dms.approvalCount(vid, bytes32(0));
        _nf(vid);
        dms.hasApproved(vid, bytes32(0), g1);
        _nf(vid);
        dms.payoutAddressOf(vid, alice);
        _nf(vid);
        dms.fallbackPayoutOf(vid);
        _nf(vid);
        dms.phase(vid);
        _nf(vid);
        dms.isExpired(vid);
        _nf(vid);
        dms.deadline(vid);
        _nf(vid);
        dms.claimable(vid, alice);
        _nf(vid);
        dms.hasClaimed(vid, alice);
    }
}
