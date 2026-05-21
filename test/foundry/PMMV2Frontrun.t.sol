// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {PMMV2Base} from "./PMMV2Base.t.sol";
import {PythagoreanMarketMakerV2} from "../../src/PythagoreanMarketMakerV2.sol";

contract PMMV2FrontrunTest is PMMV2Base {
    function testSameDestinationFrontrunnerGetsSolverPowerAndVictimReverts() public {
        _create(alice, "seed-bob", 6, 8);
        _create(alice, "seed-charlie", 18, 24);
        _create(alice, "seed-david", 21, 28);

        _create(bob, "frontrunner", 15, 20);

        vm.prank(alice);
        vm.expectRevert(PythagoreanMarketMakerV2.CoordinateOccupied.selector);
        pmm.createAgent("victim", 15, 20);

        assertEq(pmm.nMax(), 5);
        (uint256 bobPower,,) = pmm.solverRewards(bob);
        (uint256 alicePower,,) = pmm.solverRewards(alice);
        assertEq(bobPower, 25);
        assertEq(alicePower, 0);
    }
}
