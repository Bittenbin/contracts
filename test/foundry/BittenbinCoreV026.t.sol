// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";

import {BittenbinCoreV026} from "../../src/BittenbinCoreV026.sol";
import {Tenbinium} from "../../src/Tenbinium.sol";

contract BittenbinCoreV026Test is Test {
    string internal constant QUESTION = "BTC >= 100000 USD by 31 Dec 2026";
    uint256 internal constant WINDOW = 1 hours;
    // A question that stays open for one hour costs 1 TBN.
    uint256 internal constant FEE = 1 ether;

    address internal owner = makeAddr("owner");
    address internal customer = makeAddr("customer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    Tenbinium internal tbn;
    BittenbinCoreV026 internal core;

    function setUp() public {
        tbn = new Tenbinium(owner);
        core = new BittenbinCoreV026(address(tbn));

        // The customer needs TBN before any neuron has earned some, so mint it directly for the tests.
        vm.prank(owner);
        tbn.setMinter(address(this));
        tbn.mint(customer, 1_000 ether);
        vm.prank(owner);
        tbn.setMinter(address(core));

        vm.prank(customer);
        tbn.approve(address(core), type(uint256).max);
    }

    function testPrefixIsXThenYThenCInBinary() public view {
        (uint256 prefix, uint256 bits) = core.prefixOf(15, 20, 25);
        assertEq(prefix, 0x3E99); // 1111 10100 11001
        assertEq(bits, 14);
    }

    function testCreateNeuronMintsRewardAndUsesPoint() public {
        _create(alice, 15, 20, 25);

        (address wallet, uint64 c) = core.neurons((uint256(15) << 128) | 20);
        assertEq(wallet, alice);
        assertEq(c, 25);
        assertTrue(core.isUsed(15, 20));
        assertEq(core.memoryLeft(15, 20), 25);
        assertEq(core.memoryOf(15, 20).length, 0);
        assertEq(core.neuronCount(), 1);
        assertEq(tbn.balanceOf(alice), 1 ether);
    }

    function testNeuronProofIsBoundToWallet() public {
        uint128 nonce = _mine(alice, 15, 20, 25);
        assertFalse(core.isValidProof(bob, 15, 20, 25, nonce));

        vm.prank(bob);
        vm.expectRevert(BittenbinCoreV026.InvalidProof.selector);
        core.createNeuron(15, 20, 25, nonce);
    }

    function testEachPointHoldsOneNeuron() public {
        _create(alice, 15, 20, 25);

        uint128 nonce = _mine(bob, 15, 20, 25);
        vm.prank(bob);
        vm.expectRevert(BittenbinCoreV026.PointUsed.selector);
        core.createNeuron(15, 20, 25, nonce);
    }

    function testCreateNeuronRejectsNonTriples() public {
        vm.prank(alice);
        vm.expectRevert(BittenbinCoreV026.InvalidPoint.selector);
        core.createNeuron(3, 4, 6, 0);
    }

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

    function testAskEnforcesMinimumWindow() public {
        vm.startPrank(customer);
        vm.expectRevert(BittenbinCoreV026.WindowTooShort.selector);
        core.ask(QUESTION, block.timestamp + 59 minutes);

        vm.expectRevert(BittenbinCoreV026.EmptyQuestion.selector);
        core.ask("", block.timestamp + WINDOW);
        vm.stopPrank();
    }

    function testFeeGrowsWithTheSquareRootOfTheWindow() public {
        assertEq(core.feeOf(1 hours), 1 ether);
        assertEq(core.feeOf(4 hours), 2 ether);
        assertEq(core.feeOf(9 hours), 3 ether);
        assertApproxEqAbs(core.feeOf(1 days), 4.898979 ether, 0.000001 ether);

        uint256 before = tbn.balanceOf(customer);
        vm.prank(customer);
        uint256 questionId = core.ask(QUESTION, block.timestamp + 4 hours);

        (,,, uint256 fee,,) = core.questions(questionId);
        assertEq(fee, 2 ether);
        assertEq(tbn.balanceOf(customer), before - 2 ether);
    }

    function testFeeHalvesEveryMillionQuestions() public view {
        assertEq(core.rateAt(0), 1 ether);
        assertEq(core.rateAt(999_999), 1 ether);
        assertEq(core.rateAt(1_000_000), 0.5 ether);
        assertEq(core.rateAt(2_000_000), 0.25 ether);
        assertEq(core.feeAt(1_000_000, 4 hours), 1 ether);
    }

    function testStoringCombinesVectorsIntoOneProbability() public {
        uint256 questionId = _threeNeuronsStore();

        (uint256 qx, uint256 qy, uint256 probability) = core.answerOf(questionId);
        assertEq(qx, 59);
        assertEq(qy, 48);
        assertEq(probability, uint256(59 * 59) * 1 ether / 5785);

        assertEq(core.memoryLeft(15, 20), 24);
        uint256[] memory stored = core.memoryOf(15, 20);
        assertEq(stored.length, 1);
        assertEq(stored[0], questionId);
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

    function testNeuronStoresAtMostCQuestions() public {
        _create(alice, 3, 4, 5);

        for (uint256 i = 0; i < 5; i++) {
            uint256 questionId = _ask();
            vm.prank(alice);
            core.store(questionId, 3, 4, "");
        }
        assertEq(core.memoryLeft(3, 4), 0);
        assertEq(core.memoryOf(3, 4).length, 5);

        uint256 sixth = _ask();
        vm.prank(alice);
        vm.expectRevert(BittenbinCoreV026.MemoryFull.selector);
        core.store(sixth, 3, 4, "");
    }

    function testOpinionLengthIsCapped() public {
        _create(alice, 15, 20, 25);
        uint256 questionId = _ask();

        vm.prank(alice);
        vm.expectRevert(BittenbinCoreV026.OpinionTooLong.selector);
        core.store(questionId, 15, 20, string(new bytes(281)));
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

    function testRewardSchedule() public view {
        assertEq(core.rewardAt(0), 1 ether);
        assertEq(core.rewardAt(99_999), 1 ether);
        assertEq(core.rewardAt(100_000), 4 ether);
        assertEq(core.rewardAt(200_000), 9 ether);
        assertEq(core.rewardAt(300_000), 16 ether);
        assertEq(core.rewardAt(400_000), 25 ether);
        assertEq(core.rewardAt(999_999), 25 ether);
        assertEq(core.rewardAt(1_000_000), 16 ether);
        assertEq(core.rewardAt(1_100_000), 9 ether);
        assertEq(core.rewardAt(1_200_000), 4 ether);
        assertEq(core.rewardAt(1_300_000), 1 ether);
        assertEq(core.rewardAt(1_350_000), 0.5 ether);
        assertEq(core.rewardAt(1_400_000), 0.25 ether);
    }

    function testEmissionTotalsTwentyOneMillion() public view {
        uint256 ramp;
        for (uint256 era = 0; era < 13; era++) {
            ramp += core.rewardAt(era * 100_000) * 100_000;
        }
        assertEq(ramp, 20_900_000 ether);

        uint256 tail;
        for (uint256 halving = 0; halving < 100; halving++) {
            tail += core.rewardAt(1_300_000 + halving * 50_000) * 50_000;
        }
        assertLe(tail, 100_000 ether);
        assertGt(tail, 99_999 ether);
    }

    function _threeNeuronsStore() internal returns (uint256 questionId) {
        _create(alice, 15, 20, 25);
        _create(carol, 24, 7, 25);
        _create(bob, 20, 21, 29);
        questionId = _ask();

        vm.prank(alice);
        core.store(questionId, 15, 20, "");
        vm.prank(carol);
        core.store(questionId, 24, 7, "");
        vm.prank(bob);
        core.store(questionId, 20, 21, "");
    }

    function _ask() internal returns (uint256 questionId) {
        vm.prank(customer);
        questionId = core.ask(QUESTION, block.timestamp + WINDOW);
    }

    function _create(address wallet, uint256 x, uint256 y, uint256 c) internal {
        uint128 nonce = _mine(wallet, x, y, c);
        vm.prank(wallet);
        core.createNeuron(x, y, c, nonce);
    }

    function _mine(address wallet, uint256 x, uint256 y, uint256 c) internal view returns (uint128 nonce) {
        while (!core.isValidProof(wallet, x, y, c, nonce)) {
            nonce++;
        }
    }
}
