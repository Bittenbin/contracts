// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {BittenbinCoreV026} from "../../src/BittenbinCoreV026.sol";
import {BittenbinCoreV026Base} from "./BittenbinCoreV026Base.t.sol";

contract BittenbinCoreV026MemoryTest is BittenbinCoreV026Base {
    function testStoreRules() public {
        _create(alice, 15, 20, 25);
        _create(alice, 20, 15, 25);
        uint256 questionId = _ask();

        vm.prank(bob);
        vm.expectRevert(BittenbinCoreV026.NotNeuronOwner.selector);
        core.store(questionId, 15, 20, "");

        vm.startPrank(alice);
        vm.expectRevert(BittenbinCoreV026.NoQuestion.selector);
        core.store(questionId + 1, 15, 20, "");

        core.store(questionId, 15, 20, "36% on current momentum");

        vm.expectRevert(BittenbinCoreV026.AlreadyStored.selector);
        core.store(questionId, 15, 20, "");
        vm.stopPrank();

        vm.warp(block.timestamp + WINDOW);
        _create(bob, 3, 4, 5);
        vm.prank(bob);
        vm.expectRevert(BittenbinCoreV026.QuestionClosed.selector);
        core.store(questionId, 3, 4, "");
    }

    function testNeuronStoresOneQuestionPerBitOfItsProof() public {
        _create(alice, 3, 4, 5);

        // (3, 4, 5) is 11, 100 and 101 in binary, a proof of 8 bits.
        for (uint256 i = 0; i < 8; i++) {
            uint256 questionId = _ask();
            vm.prank(alice);
            core.store(questionId, 3, 4, "");
        }
        assertEq(core.memoryLeft(3, 4), 0);
        assertEq(core.memoryOf(3, 4).length, 8);

        uint256 ninth = _ask();
        vm.prank(alice);
        vm.expectRevert(BittenbinCoreV026.MemoryFull.selector);
        core.store(ninth, 3, 4, "");
    }

    function testStoreAndClaimRejectCoordinatesThatAliasAPoint() public {
        _create(alice, 15, 20, 25);
        _create(bob, 20, 15, 25);
        uint256 questionId = _ask();
        vm.prank(bob);
        core.store(questionId, 20, 15, "");

        // (0, 15 * 2^128 + 20) packs to the same key as (15, 20) and would add a huge vector to the sum.
        uint256 aliased = (uint256(15) << 128) | 20;
        vm.prank(alice);
        vm.expectRevert(BittenbinCoreV026.InvalidPoint.selector);
        core.store(questionId, 0, aliased, "");

        vm.prank(alice);
        core.store(questionId, 15, 20, "");
        vm.warp(block.timestamp + WINDOW);

        vm.prank(alice);
        vm.expectRevert(BittenbinCoreV026.InvalidPoint.selector);
        core.claim(questionId, 0, aliased);
    }

    function testStoreRecordsTheOpinion() public {
        _create(alice, 15, 20, 25);
        uint256 questionId = _ask();
        string memory opinion = string(new bytes(280));

        vm.expectEmit(true, true, false, true);
        emit BittenbinCoreV026.QuestionStored(questionId, alice, 15, 20, 25, opinion);
        vm.prank(alice);
        core.store(questionId, 15, 20, opinion);
    }

    function testOpinionLengthIsCapped() public {
        _create(alice, 15, 20, 25);
        uint256 questionId = _ask();

        vm.prank(alice);
        vm.expectRevert(BittenbinCoreV026.OpinionTooLong.selector);
        core.store(questionId, 15, 20, string(new bytes(281)));
    }
}
