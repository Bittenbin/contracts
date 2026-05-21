// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {PMMV2Base} from "./PMMV2Base.t.sol";
import {PythagoreanMarketMakerV2} from "../../src/PythagoreanMarketMakerV2.sol";

contract PMMV2SecurityTest is PMMV2Base {
    function testRevertsStaleRelocations() public {
        bytes32 id = _create(alice, "stale-agent", 3, 4);
        _relocate(alice, id, 3, 4, 5, 12);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PythagoreanMarketMakerV2.StaleLocation.selector, 5, 12));
        pmm.relocateAgent(id, 3, 4, 8, 15);
    }

    function testPreventsSellingExposureCallerDoesNotOwn() public {
        bytes32 id = _create(alice, "exposure-agent", 15, 20);

        vm.prank(bob);
        vm.expectRevert(PythagoreanMarketMakerV2.InsufficientExposure.selector);
        pmm.relocateAgent(id, 15, 20, 3, 4);
    }

    function testRestrictsOwnershipActionsToOwner() public {
        vm.prank(alice);
        _expectOwnableUnauthorized(alice);
        pmm.renounceOwnership();

        vm.prank(alice);
        _expectOwnableUnauthorized(alice);
        tbn.setMinter(alice);

        vm.prank(alice);
        _expectOwnableUnauthorized(alice);
        tbn.freezeMinter();
    }

    function testAnyTbnHolderCanRedeemFeeVault() public {
        _create(alice, "fee-vault-agent", 15, 20);
        vm.warp(block.timestamp + YEAR);
        _claim(alice);
        vm.prank(alice);
        tbn.transfer(bob, 100 ether);

        uint256 vaultBalance = pmm.accumulatedProtocolFees();
        uint256 bobUsdcBefore = mockUSDC.balanceOf(bob);
        _approveTbnBurn(bob, 100 ether);

        vm.prank(bob);
        pmm.redeemFeeVault();

        assertEq(mockUSDC.balanceOf(bob), bobUsdcBefore + vaultBalance);
    }

    function testTrustMaximizedOwnershipRenounceAfterFreezingMinter() public {
        vm.startPrank(owner);
        tbn.freezeMinter();
        pmm.renounceOwnership();
        tbn.renounceOwnership();
        vm.stopPrank();

        assertEq(pmm.owner(), address(0));
        assertEq(tbn.owner(), address(0));
        assertEq(tbn.minter(), address(pmm));
        assertTrue(tbn.minterFrozen());

        _create(alice, "renounced-ownership-agent", 15, 20);
        vm.warp(block.timestamp + YEAR);
        _claim(alice);
        assertGt(tbn.balanceOf(alice), 0);
    }
}
