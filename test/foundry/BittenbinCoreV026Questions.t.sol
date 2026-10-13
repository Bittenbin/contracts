// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {BittenbinCoreV026} from "../../src/BittenbinCoreV026.sol";
import {BittenbinCoreV026Base} from "./BittenbinCoreV026Base.t.sol";

contract BittenbinCoreV026QuestionsTest is BittenbinCoreV026Base {
    function testAskHoldsTheFee() public {
        uint256 questionId = _ask();

        (address asker, uint64 deadline, bool refunded, uint256 fee, uint256 qx, uint256 qy) = core.questions(questionId);
        assertEq(asker, customer);
        assertEq(deadline, block.timestamp + WINDOW);
        assertFalse(refunded);
        assertEq(fee, FEE);
        assertEq(qx, 0);
        assertEq(qy, 0);
        assertEq(tbn.balanceOf(address(core)), FEE);
    }

    function testAskRejectsEmptyQuestionsAndOtherDurations() public {
        vm.startPrank(customer);
        vm.expectRevert(BittenbinCoreV026.EmptyQuestion.selector);
        core.ask("", WINDOW);

        vm.expectRevert(BittenbinCoreV026.InvalidDuration.selector);
        core.ask(QUESTION, 59 minutes);

        vm.expectRevert(BittenbinCoreV026.InvalidDuration.selector);
        core.ask(QUESTION, 9 hours);

        vm.expectRevert(BittenbinCoreV026.InvalidDuration.selector);
        core.ask(QUESTION, 30 days);
        vm.stopPrank();
    }

    function testFeeIsFixedForEachOfTheFourDurations() public {
        assertEq(core.feeOf(1 hours), 1 ether);
        assertEq(core.feeOf(4 hours), 2 ether);
        assertEq(core.feeOf(1 days), 5 ether);
        assertEq(core.feeOf(7 days), 13 ether);

        uint256 before = tbn.balanceOf(customer);
        vm.prank(customer);
        uint256 questionId = core.ask(QUESTION, 7 days);

        (, uint64 deadline,, uint256 fee,,) = core.questions(questionId);
        assertEq(deadline, block.timestamp + 7 days);
        assertEq(fee, 13 ether);
        assertEq(tbn.balanceOf(customer), before - 13 ether);
    }

    function testTheSameQuestionCanBeAskedAgain() public {
        _create(alice, 15, 20, 25);
        uint256 first = _ask();
        uint256 second = _ask();
        assertEq(second, first + 1);
        assertEq(tbn.balanceOf(address(core)), 2 * FEE);

        // Each asking is a separate question with its own answer, and a neuron spends a slot on each.
        vm.startPrank(alice);
        core.store(first, 15, 20, "");
        core.store(second, 15, 20, "");
        vm.stopPrank();
        assertEq(core.memoryLeft(15, 20), 12);
    }

    function testUnansweredQuestionIsRefunded() public {
        uint256 questionId = _ask();
        uint256 before = tbn.balanceOf(customer);

        vm.expectRevert(BittenbinCoreV026.QuestionOpen.selector);
        core.refund(questionId);

        vm.warp(block.timestamp + WINDOW);
        core.refund(questionId);
        assertEq(tbn.balanceOf(customer), before + FEE);

        vm.expectRevert(BittenbinCoreV026.NothingToRefund.selector);
        core.refund(questionId);
    }

    function testAnsweredQuestionIsNotRefunded() public {
        uint256 questionId = _threeNeuronsStore();
        vm.warp(block.timestamp + WINDOW);

        vm.expectRevert(BittenbinCoreV026.NothingToRefund.selector);
        core.refund(questionId);
    }
}
