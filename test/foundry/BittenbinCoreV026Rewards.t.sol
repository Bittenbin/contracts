// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {BittenbinCoreV026Base} from "./BittenbinCoreV026Base.t.sol";

contract BittenbinCoreV026RewardsTest is BittenbinCoreV026Base {
    function testRewardSchedule() public view {
        assertEq(core.rewardAt(0), 2 ether);
        assertEq(core.rewardAt(8_999_999), 2 ether);
        assertEq(core.rewardAt(9_000_000), 1 ether);
        assertEq(core.rewardAt(9_999_999), 1 ether);
        assertEq(core.rewardAt(10_000_000), 0.5 ether);
        assertEq(core.rewardAt(11_999_999), 0.5 ether);
        assertEq(core.rewardAt(12_000_000), 0.25 ether);
        assertEq(core.rewardAt(14_000_000), 0.125 ether);
        assertEq(core.nextReward(), 2 ether);
    }

    function testEmissionTotalsTwentyOneMillion() public view {
        uint256 flat = core.rewardAt(0) * 9_000_000 + core.rewardAt(9_000_000) * 1_000_000;
        assertEq(flat, 19_000_000 ether);

        uint256 tail;
        for (uint256 halving = 0; halving < 100; halving++) {
            tail += core.rewardAt(10_000_000 + halving * 2_000_000) * 2_000_000;
        }
        assertLe(tail, 2_000_000 ether);
        assertGt(tail, 1_999_999 ether);
    }
}
