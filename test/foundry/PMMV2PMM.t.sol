// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {PMMV2Base} from "./PMMV2Base.t.sol";
import {PythagoreanMarketMakerV2} from "../../src/PythagoreanMarketMakerV2.sol";

contract PMMV2PMMTest is PMMV2Base {
    function testCreatesAgentWithHypotenusePricing() public {
        uint256 beforeBalance = mockUSDC.balanceOf(alice);
        bytes32 id = _create(alice, "https://agent.example/alice", 3, 4);

        _assertAgent(id, 3, 4, 5);
        assertEq(pmm.totalStakedValue(), 5);
        assertEq(beforeBalance - mockUSDC.balanceOf(alice), 5_050_000);
    }

    function testRelocatesAgentAndUpdatesExposure() public {
        bytes32 id = _create(alice, "relocated-agent", 3, 4);

        _relocate(alice, id, 3, 4, 5, 12);

        _assertAgent(id, 5, 12, 13);
        (uint256 xExposure, uint256 yExposure, bool exists) = pmm.getExposure(id, alice);
        assertTrue(exists);
        assertEq(xExposure, 5);
        assertEq(yExposure, 12);
    }

    function testNormalTransactionsDoNotSolveWhenConditionsFail() public {
        _create(alice, "not-square-delta", 5, 12);
        _create(alice, "seed", 3, 4);
        _create(alice, "not-square-tvl", 15, 20);

        assertEq(pmm.nMax(), 0);
        (uint256 power,,) = pmm.solverRewards(alice);
        assertEq(power, 0);
    }

    function testFreesOldCoordinateAfterRelocation() public {
        bytes32 first = _create(alice, "coordinate-lifecycle-first", 3, 4);
        _relocate(alice, first, 3, 4, 5, 12);

        bytes32 second = _create(bob, "coordinate-lifecycle-second", 3, 4);

        (,, uint256 firstC,) = pmm.getAgentState(first);
        (,, uint256 secondC,) = pmm.getAgentState(second);
        assertEq(firstC, 13);
        assertEq(secondC, 5);
        assertEq(pmm.totalStakedValue(), 18);
    }

    function testRejectsOccupiedCoordinate() public {
        bytes32 first = _create(alice, "occupied-first", 3, 4);
        _create(bob, "occupied-second", 5, 12);

        vm.prank(alice);
        vm.expectRevert(PythagoreanMarketMakerV2.CoordinateOccupied.selector);
        pmm.relocateAgent(first, 3, 4, 5, 12);
    }

    function testRejectsInvalidAndOversizedCoordinates() public {
        vm.prank(alice);
        vm.expectRevert(PythagoreanMarketMakerV2.InvalidPythagoreanCoordinate.selector);
        pmm.createAgent("zero-axis", 0, 4);

        vm.prank(alice);
        vm.expectRevert(PythagoreanMarketMakerV2.InvalidPythagoreanCoordinate.selector);
        pmm.createAgent("non-pythagorean", 2, 3);

        vm.prank(alice);
        vm.expectRevert(PythagoreanMarketMakerV2.CoordinateTooLarge.selector);
        pmm.createAgent("oversized", 1_000_000_001, 4);

        bytes32 id = _create(alice, "invalid-coordinate-agent", 3, 4);
        vm.prank(alice);
        vm.expectRevert(PythagoreanMarketMakerV2.InvalidPythagoreanCoordinate.selector);
        pmm.relocateAgent(id, 3, 4, 2, 3);
    }

    function testRejectsRelocatingToOrigin() public {
        bytes32 id = _create(alice, "origin-relocation-agent", 3, 4);

        vm.prank(alice);
        vm.expectRevert(PythagoreanMarketMakerV2.InvalidPythagoreanCoordinate.selector);
        pmm.relocateAgent(id, 3, 4, 0, 0);

        _assertAgent(id, 3, 4, 5);
        assertEq(pmm.totalStakedValue(), 5);
    }

    function testTotalStakedValueTracksCurrentHypotenuses() public {
        bytes32 a = _create(alice, "tvl-a", 3, 4);
        assertEq(pmm.totalStakedValue(), 5);

        bytes32 b = _create(bob, "tvl-b", 5, 12);
        assertEq(pmm.totalStakedValue(), 18);

        bytes32 c = _create(alice, "tvl-c", 8, 15);
        assertEq(pmm.totalStakedValue(), 35);

        _relocate(alice, a, 3, 4, 7, 24);
        assertEq(pmm.totalStakedValue(), 55);

        _relocate(bob, b, 5, 12, 20, 21);
        assertEq(pmm.totalStakedValue(), 71);

        _relocate(alice, c, 8, 15, 3, 4);
        assertEq(pmm.totalStakedValue(), 59);
    }
}
