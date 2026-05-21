// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {PMMV2Base} from "./PMMV2Base.t.sol";
import {PythagoreanMarketMakerV2} from "../../src/PythagoreanMarketMakerV2.sol";

contract PMMV2FeesTest is PMMV2Base {
    function testChargesOnePercentUsdcFeeOnPositiveDelta() public {
        uint256 beforeBalance = mockUSDC.balanceOf(alice);
        _create(alice, "fee-agent", 3, 4);

        assertEq(beforeBalance - mockUSDC.balanceOf(alice), 5_050_000);
        assertEq(pmm.accumulatedProtocolFees(), 50_000);
    }

    function testDoesNotChargeFeeOnZeroDeltaRelocations() public {
        bytes32 id = _create(alice, "zero-delta-agent", 3, 4);
        uint256 feeBefore = pmm.accumulatedProtocolFees();
        uint256 balanceBefore = mockUSDC.balanceOf(alice);

        _relocate(alice, id, 3, 4, 4, 3);

        assertEq(pmm.accumulatedProtocolFees(), feeBefore);
        assertEq(mockUSDC.balanceOf(alice), balanceBefore);
    }

    function testBurnsTbnForUsedPuzzleDestination() public {
        bytes32 mover = _create(alice, "mover", 20, 21);
        _create(alice, "helper", 21, 28);
        _relocate(alice, mover, 20, 21, 16, 63);

        vm.warp(block.timestamp + YEAR);
        _claim(alice);
        uint256 balanceBefore = tbn.balanceOf(alice);
        _relocate(alice, mover, 16, 63, 20, 21);
        _approveTbnBurn(alice, 1 ether);

        _relocate(alice, mover, 20, 21, 16, 63);
        assertEq(balanceBefore - tbn.balanceOf(alice), 1 ether);
    }

    function testAccumulatesFeesFromPositiveAndNegativeDelta() public {
        bytes32 id = _create(alice, "positive-and-negative-fees", 20, 21);
        assertEq(pmm.accumulatedProtocolFees(), 290_000);

        _relocate(alice, id, 20, 21, 3, 4);
        assertEq(pmm.accumulatedProtocolFees(), 530_000);
    }

    function testRedeemsFullFeeVaultByBurningTbn() public {
        _create(alice, "fee-vault-solver", 15, 20);
        vm.warp(block.timestamp + YEAR);
        _claim(alice);

        uint256 vaultBalance = pmm.accumulatedProtocolFees();
        vm.prank(alice);
        tbn.transfer(bob, 100 ether);
        uint256 bobUsdcBefore = mockUSDC.balanceOf(bob);
        _approveTbnBurn(bob, 100 ether);

        vm.prank(bob);
        pmm.redeemFeeVault();

        assertEq(mockUSDC.balanceOf(bob), bobUsdcBefore + vaultBalance);
        assertEq(pmm.accumulatedProtocolFees(), 0);
    }

    function testRejectsFeeVaultRedemptionWithNoOrInsufficientApproval() public {
        _create(alice, "insufficient-approval-redemption", 15, 20);
        vm.warp(block.timestamp + YEAR);
        _claim(alice);
        vm.prank(alice);
        tbn.transfer(bob, 100 ether);

        vm.prank(bob);
        vm.expectRevert();
        pmm.redeemFeeVault();

        _approveTbnBurn(bob, 99 ether);
        vm.prank(bob);
        vm.expectRevert();
        pmm.redeemFeeVault();
    }

    function testBurnsExactly100TbnEvenWithHigherApproval() public {
        _create(alice, "over-approval-redemption", 15, 20);
        vm.warp(block.timestamp + YEAR);
        _claim(alice);
        vm.prank(alice);
        tbn.transfer(bob, 200 ether);
        _approveTbnBurn(bob, 200 ether);

        vm.prank(bob);
        pmm.redeemFeeVault();

        assertEq(tbn.balanceOf(bob), 100 ether);
    }

    function testRejectsEmptyOrUnfundedFeeVaultRedemptions() public {
        vm.prank(bob);
        vm.expectRevert(PythagoreanMarketMakerV2.InvalidFeeAmount.selector);
        pmm.redeemFeeVault();

        _create(alice, "unfunded-redemption", 15, 20);
        vm.prank(bob);
        vm.expectRevert();
        pmm.redeemFeeVault();
    }
}
