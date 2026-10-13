// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {BittenbinCoreV026} from "../../src/BittenbinCoreV026.sol";
import {Tenbinium} from "../../src/Tenbinium.sol";
import {BittenbinCoreV026Base} from "./BittenbinCoreV026Base.t.sol";

contract BittenbinCoreV026SecurityTest is BittenbinCoreV026Base {
    uint256 internal constant NEURONS = 6;

    uint256[3][NEURONS] internal points =
        [[uint256(3), 4, 5], [uint256(4), 3, 5], [uint256(5), 12, 13], [uint256(12), 5, 13], [uint256(8), 15, 17], [uint256(15), 8, 17]];
    address[NEURONS] internal owners;
    uint256[4] internal durations = [1 hours, 4 hours, 1 days, 7 days];

    function setUp() public override {
        super.setUp();
        owners = [alice, bob, carol, alice, bob, carol];
        for (uint256 i = 0; i < NEURONS; i++) {
            _create(owners[i], points[i][0], points[i][1], points[i][2]);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Funds
    // ---------------------------------------------------------------------------------------------

    /// Whichever neurons store a question, their claims never exceed its fee and leave at most one
    /// unit of rounding behind for each of them.
    function testFuzzClaimsNeverExceedTheFee(uint8 mask, uint8 tier) public {
        uint256 duration = durations[tier % 4];
        uint256 fee = core.feeOf(duration);
        vm.prank(customer);
        uint256 questionId = core.ask(QUESTION, duration);

        uint256 stored;
        for (uint256 i = 0; i < NEURONS; i++) {
            if ((mask >> i) & 1 == 0) continue;
            vm.prank(owners[i]);
            core.store(questionId, points[i][0], points[i][1], "");
            stored++;
        }
        vm.warp(block.timestamp + duration);

        if (stored == 0) {
            assertEq(core.refund(questionId), fee);
            assertEq(tbn.balanceOf(address(core)), 0);
            return;
        }

        uint256 claimed;
        for (uint256 i = 0; i < NEURONS; i++) {
            if ((mask >> i) & 1 == 0) continue;
            vm.prank(owners[i]);
            claimed += core.claim(questionId, points[i][0], points[i][1]);
        }
        assertLe(claimed, fee);
        assertGe(claimed + stored, fee);
        assertEq(tbn.balanceOf(address(core)), fee - claimed);

        vm.expectRevert(BittenbinCoreV026.NothingToRefund.selector);
        core.refund(questionId);
    }

    function testClaimsOnOneQuestionCannotTakeTheFeeOfAnother() public {
        vm.startPrank(customer);
        uint256 small = core.ask(QUESTION, 1 hours);
        uint256 large = core.ask(QUESTION, 7 days);
        vm.stopPrank();

        vm.prank(alice);
        core.store(small, 3, 4, "");
        vm.prank(bob);
        core.store(large, 4, 3, "");

        vm.warp(block.timestamp + 1 hours);
        vm.prank(alice);
        assertEq(core.claim(small, 3, 4), 1 ether);
        assertEq(tbn.balanceOf(address(core)), 13 ether);

        // Alice's neuron never stored the larger question, open or closed.
        vm.prank(alice);
        vm.expectRevert(BittenbinCoreV026.QuestionOpen.selector);
        core.claim(large, 3, 4);

        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        vm.expectRevert(BittenbinCoreV026.NothingToClaim.selector);
        core.claim(large, 3, 4);

        vm.prank(bob);
        assertEq(core.claim(large, 4, 3), 13 ether);
        assertEq(tbn.balanceOf(address(core)), 0);
    }

    function testStoringClosesAndClaimingOpensAtTheDeadline() public {
        uint256 questionId = _ask();
        uint256 deadline = block.timestamp + WINDOW;

        vm.warp(deadline - 1);
        vm.startPrank(alice);
        core.store(questionId, 3, 4, "");
        vm.expectRevert(BittenbinCoreV026.QuestionOpen.selector);
        core.claim(questionId, 3, 4);
        vm.stopPrank();

        vm.warp(deadline);
        vm.prank(bob);
        vm.expectRevert(BittenbinCoreV026.QuestionClosed.selector);
        core.store(questionId, 4, 3, "");

        vm.prank(alice);
        assertEq(core.claim(questionId, 3, 4), FEE);
    }

    function testAShareCanBeClaimedLongAfterTheDeadline() public {
        uint256 questionId = _ask();
        vm.prank(alice);
        core.store(questionId, 3, 4, "");

        vm.warp(block.timestamp + 3650 days);
        vm.prank(alice);
        assertEq(core.claim(questionId, 3, 4), FEE);
    }

    /// A customer that answers its own question is paid like any other neuron, so it only gets back
    /// the part of the fee that its own neuron earned.
    function testCustomerAnsweringItsOwnQuestionOnlyEarnsItsShare() public {
        _create(customer, 6, 8, 10);
        uint256 questionId = _ask();

        vm.prank(customer);
        core.store(questionId, 6, 8, "");
        vm.prank(alice);
        core.store(questionId, 3, 4, "");
        vm.warp(block.timestamp + WINDOW);

        // q = (9, 12), and the contributions are 150 and 75 out of 225.
        vm.prank(customer);
        assertEq(core.claim(questionId, 6, 8), FEE * 150 / 225);
        vm.prank(alice);
        assertEq(core.claim(questionId, 3, 4), FEE * 75 / 225);
    }

    // ---------------------------------------------------------------------------------------------
    // Proofs and points
    // ---------------------------------------------------------------------------------------------

    function testFuzzPrefixIsTheBinaryOfXThenYThenC(uint16 k) public view {
        uint256 scale = bound(k, 1, type(uint16).max);
        uint256 x = 3 * scale;
        uint256 y = 4 * scale;
        uint256 c = 5 * scale;
        (uint256 prefix, uint256 bits) = core.prefixOf(x, y, c);

        uint256 bitsY = _bitLength(y);
        uint256 bitsC = _bitLength(c);
        assertEq(bits, _bitLength(x) + bitsY + bitsC);
        assertEq(prefix & ((1 << bitsC) - 1), c);
        assertEq((prefix >> bitsC) & ((1 << bitsY) - 1), y);
        assertEq(prefix >> (bitsC + bitsY), x);
    }

    function testFuzzOnlyPythagoreanTriplesAreValidPoints(uint64 x, uint64 y, uint64 c) public {
        bool triple = x != 0 && y != 0 && uint256(x) * x + uint256(y) * y == uint256(c) * c;
        if (!triple) vm.expectRevert(BittenbinCoreV026.InvalidPoint.selector);
        core.prefixOf(x, y, c);
    }

    function testFuzzAProofForOneWalletIsNotAProofForAnother(address other) public view {
        vm.assume(other != alice);
        uint128 nonce = _mine(alice, 9, 12, 15);
        // Twelve leading bits must match, so another wallet passes with the same nonce once in 4,096 tries.
        if (core.isValidProof(other, 9, 12, 15, nonce)) return;
        assertFalse(core.isValidProof(other, 9, 12, 15, nonce));
        assertTrue(core.isValidProof(alice, 9, 12, 15, nonce));
    }

    function testANeuronCannotBeCreatedTwiceByItsOwnWallet() public {
        uint128 nonce = _mine(alice, 3, 4, 5);
        vm.prank(alice);
        vm.expectRevert(BittenbinCoreV026.PointUsed.selector);
        core.createNeuron(3, 4, 5, nonce);
    }

    // ---------------------------------------------------------------------------------------------
    // Emission and the token
    // ---------------------------------------------------------------------------------------------

    function testRewardIsMintedAtEachStepOfTheSchedule() public {
        _setNeuronCount(8_999_999);
        assertEq(_createAndMeasure(alice, 6, 8, 10), 2 ether);
        assertEq(_createAndMeasure(alice, 8, 6, 10), 1 ether);

        _setNeuronCount(9_999_999);
        assertEq(_createAndMeasure(alice, 9, 12, 15), 1 ether);
        assertEq(_createAndMeasure(alice, 12, 9, 15), 0.5 ether);

        // Once the reward has halved to nothing, a neuron can still be created.
        _setNeuronCount(10_000_000 + 62 * 2_000_000);
        assertEq(_createAndMeasure(alice, 12, 16, 20), 0);
        assertTrue(core.isUsed(12, 16));
    }

    function testNeuronCreationNeedsTheCoreToBeTheMinter() public {
        vm.prank(owner);
        tbn.setMinter(address(this));

        uint128 nonce = _mine(alice, 6, 8, 10);
        vm.prank(alice);
        vm.expectRevert(Tenbinium.UnauthorizedMinter.selector);
        core.createNeuron(6, 8, 10, nonce);
    }

    /// The token owner can replace the minter until it is frozen, so a deployment has to freeze it.
    function testFrozenMinterCannotBeReplaced() public {
        vm.startPrank(owner);
        tbn.freezeMinter();
        vm.expectRevert(Tenbinium.MinterFrozen.selector);
        tbn.setMinter(address(this));
        vm.stopPrank();

        assertEq(_createAndMeasure(alice, 6, 8, 10), 2 ether);
    }

    // ---------------------------------------------------------------------------------------------
    // Known behaviours of the design, recorded so that a change to any of them is noticed
    // ---------------------------------------------------------------------------------------------

    /// A single small neuron that stores an otherwise ignored question earns its whole fee, and the
    /// customer is not refunded.
    function testKnownALoneNeuronEarnsTheWholeFee() public {
        vm.prank(customer);
        uint256 questionId = core.ask(QUESTION, 7 days);
        vm.prank(alice);
        core.store(questionId, 3, 4, "");
        vm.warp(block.timestamp + 7 days);

        vm.expectRevert(BittenbinCoreV026.NothingToRefund.selector);
        core.refund(questionId);
        vm.prank(alice);
        assertEq(core.claim(questionId, 3, 4), 13 ether);
    }

    /// A larger neuron that stores in the last second moves the answer and nobody can respond.
    function testKnownALateLargeNeuronMovesTheAnswer() public {
        _create(carol, 20, 21, 29);
        uint256 questionId = _ask();
        vm.prank(alice);
        core.store(questionId, 3, 4, "");
        (,, uint256 before) = core.answerOf(questionId);
        assertEq(before, 0.36 ether);

        vm.warp(block.timestamp + WINDOW - 1);
        vm.prank(carol);
        core.store(questionId, 20, 21, "");
        (uint256 qx, uint256 qy, uint256 afterwards) = core.answerOf(questionId);
        assertEq(qx, 23);
        assertEq(qy, 25);
        assertEq(afterwards, uint256(23 * 23) * 1 ether / 1154);

        vm.warp(block.timestamp + 1);
        vm.prank(carol);
        assertEq(core.claim(questionId, 20, 21), FEE * 985 / 1154);
    }

    /// The hash covers the wallet and the point but not the contract or the chain, so a proof found
    /// for one deployment is also a proof for any other.
    function testKnownAProofIsNotBoundToADeployment() public {
        BittenbinCoreV026 other = new BittenbinCoreV026(address(tbn));
        uint128 nonce = _mine(alice, 9, 12, 15);
        assertTrue(other.isValidProof(alice, 9, 12, 15, nonce));
        assertEq(other.proofHash(alice, 9, 12, 15, nonce), core.proofHash(alice, 9, 12, 15, nonce));
    }

    // ---------------------------------------------------------------------------------------------

    function _createAndMeasure(address wallet, uint256 x, uint256 y, uint256 c) internal returns (uint256 minted) {
        uint256 before = tbn.balanceOf(wallet);
        _create(wallet, x, y, c);
        minted = tbn.balanceOf(wallet) - before;
    }

    /// neuronCount is the first storage variable of the core.
    function _setNeuronCount(uint256 count) internal {
        vm.store(address(core), bytes32(uint256(0)), bytes32(count));
        assertEq(core.neuronCount(), count);
    }

    function _bitLength(uint256 value) internal pure returns (uint256 length) {
        while (value != 0) {
            length++;
            value >>= 1;
        }
    }
}
