// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Vm.sol";

import {PythagoreanMarketMaker} from "../src/PythagoreanMarketMaker.sol";
import {PMMIntentTestBase} from "./helpers/PMMIntentTestBase.sol";

contract PMMIntentSpecGapsTest is PMMIntentTestBase {
    function test_spec_zeroSlippageRejectsStaleExecution() public {
        uint256 pageId = _createMarketAs(alice, "https://stale-slippage.test", 3, 4);
        uint256 aliceBalanceBefore = usdc.balanceOf(alice);

        vm.prank(bob);
        pmm.voteOnMarket(pageId, 8, 15);

        // Alice signed her transaction observing the market at (3, 4) and is
        // willing to accept zero deviation from that observation.
        vm.prank(alice);
        vm.expectRevert(PythagoreanMarketMaker.SlippageExceeded.selector);
        pmm.voteOnMarketSafe(pageId, 3, 4, 5, 12, 0);

        // The reverted call must not have moved any USDC.
        assertEq(usdc.balanceOf(alice), aliceBalanceBefore);
    }

    function test_spec_marketCreationRequiresPerfectSquareTotalC() public {
        // The optional puzzle gate (README §7) is opt-in; once enabled, every
        // transition must keep `totalC` a perfect integer square.
        pmm.setPuzzleGateEnabled(true);

        vm.prank(alice);
        vm.expectRevert(PythagoreanMarketMaker.PuzzleGateFailed.selector);
        pmm.createMarket("https://non-square-total-c.test", 3, 4);
    }

    function test_spec_marketCreatedEventEmitsHypotenuseCost() public {
        string memory url = "https://event-cost.test";
        uint256 pageId = _pageId(url);

        vm.recordLogs();
        vm.prank(alice);
        pmm.createMarket(url, 3, 4);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 marketCreatedSig = keccak256("MarketCreated(uint256,address,uint256,uint256,uint256)");
        bool found;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == marketCreatedSig) {
                assertEq(logs[i].topics[1], bytes32(pageId));
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(alice))));

                (uint256 x, uint256 y, uint256 cost) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                assertEq(x, 3);
                assertEq(y, 4);
                assertEq(cost, 5);

                found = true;
                break;
            }
        }

        assertTrue(found, "MarketCreated event not found");
    }

    function test_spec_mixedAxisMoveKeepsStakeEqualToCurrentHypotenuseCost() public {
        uint256 pageId = _createMarketAs(alice, "https://mixed-axis.test", 6, 8);

        vm.prank(alice);
        pmm.voteOnMarket(pageId, 5, 12);

        assertEq(pmm.userTotalStake(alice), 13_000_000);
        assertEq(pmm.totalStaked(), 13_000_000);
    }

    function test_spec_tailEmissionsUseEntireTwentyOneMillionBudget() public {
        _createMarketAs(alice, "https://max-emission.test", 3, 4);

        _warpForward(300 * 365 days);

        vm.prank(alice);
        pmm.claimRewards();

        assertEq(pmm.totalEmitted(), pmm.MAX_EMISSION());
        assertEq(tbn.balanceOf(alice), pmm.MAX_EMISSION());
        assertEq(pmm.remainingEmission(), 0);
    }
}
