// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {PMMV2Base} from "./PMMV2Base.t.sol";

contract PMMV2ProofTest is PMMV2Base {
    event ProofOfProximitySolved(
        address indexed solver,
        bytes32 indexed agentId,
        uint256 x,
        uint256 y,
        uint256 deltaC,
        uint256 n,
        uint256 newTVL,
        uint256 nMax
    );
    event TbnBurnedForUsedDestination(address indexed payer, bytes32 indexed destinationHash, uint256 amount);

    function testListingProofUpdatesPowerAndNMax() public {
        _create(alice, "bob", 6, 8);
        _create(alice, "charlie", 18, 24);
        _create(alice, "david", 21, 28);

        bytes32 eric = agentId("eric");
        vm.expectEmit(true, true, false, true, address(pmm));
        emit ProofOfProximitySolved(alice, eric, 15, 20, 25, 5, 100, 5);
        _create(alice, "eric", 15, 20);

        assertEq(pmm.totalStakedValue(), 100);
        assertEq(pmm.nMax(), 5);
        (uint256 power,,) = pmm.solverRewards(alice);
        assertEq(power, 25);
    }

    function testNMaxDeterminesConnections() public {
        _create(alice, "bob", 6, 8);
        _create(alice, "charlie", 18, 24);
        _create(alice, "david", 21, 28);
        _create(alice, "eric", 15, 20);

        assertTrue(pmm.areConnected(agentId("charlie"), agentId("david")));
        assertFalse(pmm.areConnected(agentId("bob"), agentId("eric")));
    }

    function testRelocationProofAndReusedDestinationBurn() public {
        bytes32 mover = _create(alice, "mover", 20, 21);
        _create(alice, "helper", 21, 28);

        vm.expectEmit(true, true, false, true, address(pmm));
        emit ProofOfProximitySolved(alice, mover, 16, 63, 36, 6, 100, 6);
        _relocate(alice, mover, 20, 21, 16, 63);

        assertEq(pmm.nMax(), 6);
        (uint256 power,,) = pmm.solverRewards(alice);
        assertEq(power, 36);

        vm.warp(block.timestamp + YEAR);
        _claim(alice);
        _relocate(alice, mover, 16, 63, 20, 21);
        _approveTbnBurn(alice, 1 ether);

        bytes32 destHash = pmm.destinationHash(16, 63, 65);
        vm.expectEmit(true, true, false, true, address(pmm));
        emit TbnBurnedForUsedDestination(alice, destHash, 1 ether);
        _relocate(alice, mover, 20, 21, 16, 63);
    }

    function testRecordsUsedPuzzleDestinationsDirectly() public {
        bytes32 destHash = pmm.destinationHash(15, 20, 25);
        assertFalse(pmm.usedPuzzleDestinations(destHash));

        _create(alice, "used-destination-direct", 15, 20);

        assertTrue(pmm.usedPuzzleDestinations(destHash));
    }

    function testNMaxMonotonicAcrossSolutions() public {
        bytes32 mover = _create(alice, "monotonic-mover", 20, 21);
        bytes32 helper = _create(alice, "monotonic-helper", 21, 28);
        _relocate(alice, mover, 20, 21, 16, 63);
        assertEq(pmm.nMax(), 6);

        vm.warp(block.timestamp + YEAR);
        _claim(alice);
        _approveTbnBurn(alice, 1 ether);

        _relocate(alice, helper, 21, 28, 6, 8);
        _create(alice, "smaller-solution", 15, 20);
        assertEq(pmm.nMax(), 6);

        _create(alice, "tvl-adjuster", 3, 4);
        _relocate(alice, helper, 6, 8, 24, 70);
        assertEq(pmm.nMax(), 8);
    }
}
