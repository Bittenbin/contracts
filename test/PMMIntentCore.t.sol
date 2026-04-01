// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {PythagoreanMarketMaker} from "../src/PythagoreanMarketMaker.sol";
import {PMMIntentTestBase} from "./helpers/PMMIntentTestBase.sol";

contract PMMIntentCoreTest is PMMIntentTestBase {
    function test_createMarket_initializesHypotenusePricedState() public {
        string memory url = "https://alpha.test";
        uint256 pageId = _pageId(url);
        uint256 aliceBalanceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        pmm.createMarket(url, 3, 4);

        uint256 aliceBalanceAfter = usdc.balanceOf(alice);
        (uint256 x, uint256 y, uint256 pageScore, uint256 totalVotes) = pmm.getMarketState(pageId);
        (uint256 marketX, uint256 marketY) = pmm.marketCoordinates(pageId);
        (uint256 yVotes, uint256 xVotes, bool exists) = pmm.getVoterPosition(pageId, alice);
        (uint256 yCost, uint256 xCost) = pmm.holdings(pageId, alice);

        assertEq(aliceBalanceBefore - aliceBalanceAfter, 5_050_000);
        assertTrue(pmm.marketExists(pageId));
        assertTrue(pmm.marketExistsFor(pageId));
        assertEq(pmm.marketCreator(pageId), alice);
        assertEq(pmm.totalMarkets(), 1);
        assertEq(pmm.totalC(), 5);
        assertEq(pmm.totalVoteVolume(pageId), 7);
        assertEq(pmm.accumulatedProtocolFees(), 50_000);
        assertEq(x, 3);
        assertEq(y, 4);
        assertEq(marketX, 3);
        assertEq(marketY, 4);
        assertEq(totalVotes, 7);
        assertEq(pageScore, 640_000_000_000_000_000);
        assertEq(yVotes, 4);
        assertEq(xVotes, 3);
        assertTrue(exists);
        assertEq(yCost, 4_000_000);
        assertEq(xCost, 1_000_000);
        assertEq(pmm.userTotalStake(alice), 5_000_000);
        assertEq(pmm.totalStaked(), 5_000_000);
        assertEq(pmm.emissionStartTime(), block.timestamp);
        assertTrue(pmm.isCoordinatePowerUpClaimed(3, 4));
        assertEq(pmm.totalPowerUpsClaimed(), 1);
    }

    function test_createMarket_requiresUniqueUrlAndCoordinate() public {
        _createMarketAs(alice, "https://duplicate.test", 3, 4);

        vm.prank(bob);
        vm.expectRevert(PythagoreanMarketMaker.MarketAlreadyExists.selector);
        pmm.createMarket("https://duplicate.test", 5, 12);

        vm.prank(bob);
        vm.expectRevert(PythagoreanMarketMaker.CoordinateOccupied.selector);
        pmm.createMarket("https://fresh-url.test", 3, 4);
    }

    function test_createMarket_rejectsEmptyUrl() public {
        vm.expectRevert(PythagoreanMarketMaker.InvalidUrl.selector);
        vm.prank(alice);
        pmm.createMarket("", 3, 4);
    }

    function test_createMarket_rejectsNonPythagoreanTriples() public {
        vm.expectRevert(PythagoreanMarketMaker.InvalidCoordinate.selector);
        vm.prank(alice);
        pmm.createMarket("https://invalid.test", 2, 3);
    }

    function test_createMarket_rejectsZeroAxisCoordinates() public {
        vm.expectRevert(PythagoreanMarketMaker.InvalidCoordinate.selector);
        vm.prank(alice);
        pmm.createMarket("https://zero-axis.test", 0, 4);
    }

    function test_createMarket_rejectsOversizedCoordinates() public {
        uint256 oversizedX = pmm.MAX_COORDINATE_VALUE() + 1;

        vm.expectRevert(PythagoreanMarketMaker.CoordinateTooLarge.selector);
        vm.prank(alice);
        pmm.createMarket(
            "https://too-large.test",
            oversizedX,
            4
        );
    }

    function test_createMarketWithSlippage_rejectsInvalidBasisPoints() public {
        vm.prank(alice);
        vm.expectRevert(PythagoreanMarketMaker.InvalidSlippage.selector);
        pmm.createMarketWithSlippage("https://slippage.test", 3, 4, 10_001);
    }

    function test_rebalanceOnSameHypotenuse_preservesCashStakeAndFees() public {
        uint256 pageId = _createMarketAs(alice, "https://rebalance.test", 3, 4);
        uint256 aliceBalanceBefore = usdc.balanceOf(alice);
        uint256 stakeBefore = pmm.userTotalStake(alice);
        uint256 feesBefore = pmm.accumulatedProtocolFees();

        vm.prank(alice);
        pmm.voteOnMarket(pageId, 4, 3);

        uint256 aliceBalanceAfter = usdc.balanceOf(alice);
        (uint256 x, uint256 y, , uint256 totalVotes) = pmm.getMarketState(pageId);
        (uint256 yVotes, uint256 xVotes, bool exists) = pmm.getVoterPosition(pageId, alice);

        assertEq(aliceBalanceAfter, aliceBalanceBefore);
        assertEq(pmm.userTotalStake(alice), stakeBefore);
        assertEq(pmm.accumulatedProtocolFees(), feesBefore);
        assertEq(pmm.totalC(), 5);
        assertEq(x, 4);
        assertEq(y, 3);
        assertEq(totalVotes, 7);
        assertEq(yVotes, 3);
        assertEq(xVotes, 4);
        assertTrue(exists);
    }

    function test_buyAndSell_chargeOnePercentOnHypotenuseDelta() public {
        uint256 pageId = _createMarketAs(alice, "https://buy-sell.test", 3, 4);
        uint256 aliceBalanceBeforeBuy = usdc.balanceOf(alice);

        vm.prank(alice);
        pmm.voteOnMarket(pageId, 5, 12);

        uint256 aliceBalanceAfterBuy = usdc.balanceOf(alice);
        assertEq(aliceBalanceBeforeBuy - aliceBalanceAfterBuy, 8_080_000);
        assertEq(pmm.accumulatedProtocolFees(), 130_000);
        assertEq(pmm.totalC(), 13);
        assertEq(pmm.userTotalStake(alice), 13_000_000);

        vm.prank(alice);
        pmm.voteOnMarket(pageId, 3, 4);

        uint256 aliceBalanceAfterSell = usdc.balanceOf(alice);
        assertEq(aliceBalanceAfterSell - aliceBalanceAfterBuy, 7_920_000);
        assertEq(pmm.accumulatedProtocolFees(), 210_000);
        assertEq(pmm.totalC(), 5);
    }

    function test_userCanOnlySellVotesTheyPersonallyContributed() public {
        uint256 pageId = _createMarketAs(alice, "https://alice-only.test", 5, 12);

        vm.prank(bob);
        vm.expectRevert(PythagoreanMarketMaker.InsufficientVotesToSell.selector);
        pmm.voteOnMarket(pageId, 3, 4);
    }

    function test_movingMarket_freesOldCoordinateForAnotherMarket() public {
        uint256 firstPageId = _createMarketAs(alice, "https://first.test", 3, 4);

        vm.prank(alice);
        pmm.voteOnMarket(firstPageId, 5, 12);

        uint256 secondPageId = _createMarketAs(bob, "https://second.test", 3, 4);

        assertTrue(pmm.marketExists(firstPageId));
        assertTrue(pmm.marketExists(secondPageId));
        assertEq(pmm.totalMarkets(), 2);
        assertEq(pmm.totalPowerUpsClaimed(), 2);
        assertEq(pmm.totalC(), 18);
    }

    function test_powerUps_onlyCountFreshCoordinatesAcrossAllMarkets() public {
        uint256 firstPageId = _createMarketAs(alice, "https://power-1.test", 3, 4);

        vm.prank(alice);
        pmm.voteOnMarket(firstPageId, 5, 12);
        assertEq(pmm.totalPowerUpsClaimed(), 2);

        vm.prank(alice);
        pmm.voteOnMarket(firstPageId, 3, 4);
        assertEq(pmm.totalPowerUpsClaimed(), 2);

        uint256 secondPageId = _createMarketAs(bob, "https://power-2.test", 8, 15);
        assertEq(pmm.totalPowerUpsClaimed(), 3);

        vm.prank(bob);
        pmm.voteOnMarket(secondPageId, 5, 12);
        assertEq(pmm.totalPowerUpsClaimed(), 3);
    }

    function test_pauseAndUnpause_gateStateChangingActions() public {
        uint256 pageId = _createMarketAs(alice, "https://pause.test", 3, 4);
        _warpForward(1 days);

        pmm.pause("testing");

        vm.prank(bob);
        vm.expectRevert();
        pmm.createMarket("https://paused-create.test", 5, 12);

        vm.prank(alice);
        vm.expectRevert();
        pmm.voteOnMarket(pageId, 4, 3);

        vm.prank(alice);
        vm.expectRevert();
        pmm.claimRewards();

        pmm.unpause();

        vm.prank(alice);
        pmm.claimRewards();
        assertGt(tbn.balanceOf(alice), 0);
    }
}
