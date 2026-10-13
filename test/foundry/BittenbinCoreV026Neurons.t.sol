// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {BittenbinCoreV026} from "../../src/BittenbinCoreV026.sol";
import {BittenbinCoreV026Base} from "./BittenbinCoreV026Base.t.sol";

contract BittenbinCoreV026NeuronsTest is BittenbinCoreV026Base {
    function testPrefixIsXThenYThenCInBinary() public view {
        (uint256 prefix, uint256 bits) = core.prefixOf(15, 20, 25);
        assertEq(prefix, 0x3E99); // 1111 10100 11001
        assertEq(bits, 14);
    }

    function testCreateNeuronMintsRewardAndUsesPoint() public {
        _create(alice, 15, 20, 25);

        (address wallet, uint64 c, uint8 bits) = core.neurons((uint256(15) << 128) | 20);
        assertEq(wallet, alice);
        assertEq(c, 25);
        assertEq(bits, 14);
        assertTrue(core.isUsed(15, 20));
        assertEq(core.memoryLeft(15, 20), 14);
        assertEq(core.memoryOf(15, 20).length, 0);
        assertEq(core.neuronCount(), 1);
        assertEq(tbn.balanceOf(alice), 2 ether);
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

    function testCreateNeuronRejectsInvalidPoints() public {
        vm.startPrank(alice);
        vm.expectRevert(BittenbinCoreV026.InvalidPoint.selector);
        core.createNeuron(0, 5, 5, 0);

        vm.expectRevert(BittenbinCoreV026.InvalidPoint.selector);
        core.createNeuron(5, 0, 5, 0);

        vm.expectRevert(BittenbinCoreV026.InvalidPoint.selector);
        core.createNeuron(3, 4, uint256(type(uint64).max) + 1, 0);
        vm.stopPrank();
    }

    function testMirroredPointsAreDifferentNeurons() public {
        _create(alice, 15, 20, 25);
        _create(bob, 20, 15, 25);

        (address first,,) = core.neurons((uint256(15) << 128) | 20);
        (address second,,) = core.neurons((uint256(20) << 128) | 15);
        assertEq(first, alice);
        assertEq(second, bob);
        assertEq(core.neuronCount(), 2);
    }

    function testProofHashPacksWalletPointAndNonce() public view {
        bytes32 expected = keccak256(abi.encodePacked(alice, uint64(15), uint64(20), uint64(25), uint128(7)));
        assertEq(core.proofHash(alice, 15, 20, 25, 7), expected);
    }

    function testConstructorRejectsZeroAddress() public {
        vm.expectRevert(BittenbinCoreV026.InvalidAddress.selector);
        new BittenbinCoreV026(address(0));
    }
}
