// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {PMMV2Base} from "./PMMV2Base.t.sol";
import {Tenbinium} from "../../src/Tenbinium.sol";

contract PMMV2TBNTest is PMMV2Base {
    function testAccruesAndClaimsRewardsProRataByPower() public {
        _create(alice, "solver-agent", 15, 20);
        vm.warp(block.timestamp + YEAR);
        _claim(alice);

        uint256 balance = tbn.balanceOf(alice);
        assertApproxEqAbs(balance, 1_000_000 ether, 2 ether);
        assertEq(tbn.totalSupply(), balance);
    }

    function testReducesSolverPowerAfterNegativeDeltaRelocations() public {
        bytes32 id = _create(alice, "solver-agent", 15, 20);

        _relocate(alice, id, 15, 20, 3, 4);

        (uint256 power,,) = pmm.solverRewards(alice);
        assertEq(power, 5);
        assertEq(pmm.totalPower(), 5);
    }

    function testFreezeMinterDoesNotBlockRewardClaims() public {
        vm.prank(owner);
        tbn.freezeMinter();
        assertTrue(tbn.minterFrozen());

        vm.prank(owner);
        vm.expectRevert(Tenbinium.MinterFrozen.selector);
        tbn.setMinter(bob);

        _create(alice, "frozen-minter-solver", 15, 20);
        vm.warp(block.timestamp + YEAR);
        _claim(alice);
        assertGt(tbn.balanceOf(alice), 0);
    }

    function testDoesNotAccrueBeforeFirstSolverPowerExists() public {
        vm.warp(block.timestamp + 30 days);
        _create(alice, "first-power-after-delay", 15, 20);

        assertEq(pmm.pendingTBN(alice), 0);
        vm.warp(block.timestamp + 1 days);
        assertGt(pmm.pendingTBN(alice), 0);
    }

    function testSplitsRewardsByTimeWeightedPower() public {
        _create(alice, "alice-solver", 15, 20);
        _create(alice, "tvl-helper", 15, 36);
        vm.warp(block.timestamp + 10 days);

        _create(bob, "bob-solver", 135, 180);
        vm.warp(block.timestamp + 20 days);

        _claim(alice);
        _claim(bob);

        uint256 firstWindow = (10 days * 1_000_000 ether) / YEAR;
        uint256 secondWindow = (20 days * 1_000_000 ether) / YEAR;
        uint256 expectedAlice = firstWindow + ((secondWindow * 25) / 250);
        uint256 expectedBob = (secondWindow * 225) / 250;

        assertApproxEqAbs(tbn.balanceOf(alice), expectedAlice, 2 ether);
        assertApproxEqAbs(tbn.balanceOf(bob), expectedBob, 2 ether);
    }

    function testNoPendingRewardsImmediatelyAfterClaimSettlement() public {
        _create(alice, "second-claim", 15, 20);
        vm.warp(block.timestamp + YEAR);
        _claim(alice);

        assertEq(pmm.pendingTBN(alice), 0);
    }
}
