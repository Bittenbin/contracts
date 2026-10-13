// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {BittenbinCoreV026} from "../../src/BittenbinCoreV026.sol";
import {BittenbinCoreV026Base} from "./BittenbinCoreV026Base.t.sol";

contract BittenbinCoreV026ProbabilityTest is BittenbinCoreV026Base {
    function testAnswerIsEmptyUntilANeuronStores() public {
        uint256 questionId = _ask();

        (uint256 qx, uint256 qy, uint256 probability) = core.answerOf(questionId);
        assertEq(qx, 0);
        assertEq(qy, 0);
        assertEq(probability, 0);
        assertEq(core.shareOf(questionId, 15, 20), 0);
    }

    function testStoringCombinesVectorsIntoOneProbability() public {
        uint256 questionId = _threeNeuronsStore();

        (uint256 qx, uint256 qy, uint256 probability) = core.answerOf(questionId);
        assertEq(qx, 59);
        assertEq(qy, 48);
        assertEq(probability, uint256(59 * 59) * 1 ether / 5785);

        assertEq(core.memoryLeft(15, 20), 13);
        uint256[] memory stored = core.memoryOf(15, 20);
        assertEq(stored.length, 1);
        assertEq(stored[0], questionId);
    }

    function testWalletCanStoreUnderSeveralNeurons() public {
        _create(alice, 15, 20, 25);
        _create(alice, 20, 15, 25);
        uint256 questionId = _ask();

        vm.startPrank(alice);
        core.store(questionId, 15, 20, "");
        core.store(questionId, 20, 15, "");
        vm.stopPrank();

        // 36% and 64% of equal size combine to (35, 35), an even chance.
        (uint256 qx, uint256 qy, uint256 probability) = core.answerOf(questionId);
        assertEq(qx, 35);
        assertEq(qy, 35);
        assertEq(probability, 0.5 ether);

        vm.warp(block.timestamp + WINDOW);
        uint256 before = tbn.balanceOf(alice);
        vm.startPrank(alice);
        uint256 first = core.claim(questionId, 15, 20);
        uint256 second = core.claim(questionId, 20, 15);
        vm.stopPrank();

        assertEq(first, FEE / 2);
        assertEq(second, FEE / 2);
        assertEq(tbn.balanceOf(alice), before + FEE);
    }

    function testFeeIsSharedByContributionToTheSum() public {
        uint256 questionId = _threeNeuronsStore();
        vm.warp(block.timestamp + WINDOW);

        uint256 aliceBefore = tbn.balanceOf(alice);
        vm.prank(alice);
        uint256 aliceShare = core.claim(questionId, 15, 20);
        vm.prank(carol);
        uint256 carolShare = core.claim(questionId, 24, 7);
        vm.prank(bob);
        uint256 bobShare = core.claim(questionId, 20, 21);

        // q = (59, 48), and the contributions (x q_x + y q_y) are 1845, 1752 and 2188 out of 5785.
        assertEq(aliceShare, FEE * 1845 / 5785);
        assertEq(carolShare, FEE * 1752 / 5785);
        assertEq(bobShare, FEE * 2188 / 5785);
        assertApproxEqAbs(aliceShare + carolShare + bobShare, FEE, 2);
        assertEq(tbn.balanceOf(alice), aliceBefore + aliceShare);
        assertLe(tbn.balanceOf(address(core)), 2);

        vm.prank(alice);
        vm.expectRevert(BittenbinCoreV026.NothingToClaim.selector);
        core.claim(questionId, 15, 20);

        vm.prank(bob);
        vm.expectRevert(BittenbinCoreV026.NotNeuronOwner.selector);
        core.claim(questionId, 15, 20);
    }

    function testClaimWaitsForTheDeadline() public {
        uint256 questionId = _threeNeuronsStore();

        vm.prank(alice);
        vm.expectRevert(BittenbinCoreV026.QuestionOpen.selector);
        core.claim(questionId, 15, 20);
    }

    function testNeuronThatDidNotStoreHasNothingToClaim() public {
        uint256 questionId = _threeNeuronsStore();
        _create(alice, 3, 4, 5);
        vm.warp(block.timestamp + WINDOW);

        vm.prank(alice);
        vm.expectRevert(BittenbinCoreV026.NothingToClaim.selector);
        core.claim(questionId, 3, 4);
    }

    function testClaimAndRefundNeedAQuestion() public {
        _create(alice, 15, 20, 25);

        vm.prank(alice);
        vm.expectRevert(BittenbinCoreV026.NoQuestion.selector);
        core.claim(1, 15, 20);

        vm.expectRevert(BittenbinCoreV026.NoQuestion.selector);
        core.refund(1);
    }
}
