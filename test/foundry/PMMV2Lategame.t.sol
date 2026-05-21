// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {PMMV2Base} from "./PMMV2Base.t.sol";

contract PMMV2LategameTest is PMMV2Base {
    function testEmissionScheduleAcrossYear20Boundary() public {
        _create(alice, "year-20-solver", 15, 20);
        vm.warp(block.timestamp + (20 * YEAR) + YEAR);
        _claim(alice);

        assertApproxEqAbs(tbn.balanceOf(alice), 20_500_000 ether, 2 ether);
        assertEq(tbn.totalSupply(), tbn.balanceOf(alice));
    }

    function testNoNewRewardsWhileTotalPowerIsZero() public {
        _create(alice, "zero-power-later", 3, 4);

        vm.warp(block.timestamp + YEAR);
        assertEq(pmm.pendingTBN(alice), 0);
    }

    function testUsedDestinationsPersistentAndNMaxMonotonic() public {
        bytes32 id = _create(alice, "persistent-destination", 15, 20);
        bytes32 destHash = pmm.destinationHash(15, 20, 25);
        assertTrue(pmm.usedPuzzleDestinations(destHash));
        assertEq(pmm.nMax(), 5);

        _relocate(alice, id, 15, 20, 3, 4);
        assertTrue(pmm.usedPuzzleDestinations(destHash));
        assertEq(pmm.nMax(), 5);
    }

    function testTotalEmissionIsBoundedNearCapOverLongHorizon() public {
        _create(alice, "bounded-supply", 15, 20);
        vm.warp(block.timestamp + 40 * YEAR);
        _claim(alice);

        assertLe(tbn.totalSupply(), 21_000_000 ether);
        assertEq(pmm.totalTbnEmitted(), tbn.totalSupply());
    }

    function testNoPostCapRewardsForLaterSolverAfterTailDecay() public {
        _create(alice, "cap-solver", 15, 20);
        vm.warp(block.timestamp + 100 * YEAR);
        _claim(alice);
        uint256 supplyAtCap = tbn.totalSupply();

        _create(bob, "late-solver", 10, 24);
        vm.warp(block.timestamp + YEAR);

        assertEq(pmm.pendingTBN(bob), 0);
        assertEq(tbn.totalSupply(), supplyAtCap);
    }

    function testUsesPhaseTwoRateImmediatelyAfterYear20Boundary() public {
        _create(alice, "phase-two-boundary", 15, 20);
        vm.warp(block.timestamp + 20 * YEAR);
        _claim(alice);
        assertApproxEqAbs(tbn.balanceOf(alice), 20_000_000 ether, 2 ether);

        vm.warp(block.timestamp + YEAR);
        _claim(alice);
        assertApproxEqAbs(tbn.balanceOf(alice), 20_500_000 ether, 2 ether);
    }
}
