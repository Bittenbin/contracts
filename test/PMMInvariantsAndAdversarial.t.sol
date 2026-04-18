// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {PythagoreanMarketMaker} from "../src/PythagoreanMarketMaker.sol";
import {PMMIntentTestBase} from "./helpers/PMMIntentTestBase.sol";

/**
 * @title PMMInvariantsAndAdversarialTest
 * @notice Targeted "I bet it can break here" scenarios: multi-user mixed-axis
 *         races, round-trip stake reconciliation, liquidity safety, pause +
 *         reward interactions, and the leg-decomposition cascade in extreme
 *         (gain-on-sell) configurations.
 */
contract PMMInvariantsAndAdversarialTest is PMMIntentTestBase {

    // ---------------------------------------------------------------
    // Multi-user, mixed-axis cost basis
    // ---------------------------------------------------------------

    function test_invariant_marketHoldingsEqualScaledHypotenuse_basic() public {
        // Two users, two consecutive same-direction votes. Sum of holdings
        // across both users must always equal the current scaled hypotenuse.
        uint256 pageId = _createMarketAs(alice, "https://inv-basic.test", 3, 4);
        _assertMarketInvariant(pageId, /*expectedHypScaled=*/ 5 * USDC_UNIT);

        vm.prank(bob);
        pmm.voteOnMarket(pageId, 5, 12);
        _assertMarketInvariant(pageId, 13 * USDC_UNIT);

        vm.prank(bob);
        pmm.voteOnMarket(pageId, 8, 15);
        _assertMarketInvariant(pageId, 17 * USDC_UNIT);
    }

    function test_invariant_marketHoldingsEqualScaledHypotenuse_underMixedSell() public {
        // Set up a shared market then have the original creator sell across
        // both axes simultaneously while the other user's contribution stays
        // intact. The leg-decomp cascade must not break the invariant.
        uint256 pageId = _createMarketAs(alice, "https://inv-mixed-sell.test", 8, 15);
        vm.prank(bob);
        pmm.voteOnMarket(pageId, 20, 21); // c = 29, bob adds y = 6, x = 12

        _assertMarketInvariant(pageId, 29 * USDC_UNIT);

        // Alice exits part of her position via a mixed-axis SELL inside her
        // own contribution: (20, 21) -> (12, 16) means yDelta = -5 (within
        // alice's 15 yVotes) and xDelta = -8 (exactly her 8 xVotes).
        vm.prank(alice);
        pmm.voteOnMarket(pageId, 12, 16);

        _assertMarketInvariant(pageId, 20 * USDC_UNIT);
    }

    function test_invariant_marketHoldingsEqualScaledHypotenuse_underAdversarialExit() public {
        // The cascade scenario: alice's per-axis cost basis is smaller than
        // the marginal refund she receives on a mixed-axis sell, so the
        // leg-decomp must cascade between axes (and finally clamp at zero
        // when needed) without breaking the sum-of-holdings invariant.
        uint256 pageId = _createMarketAs(alice, "https://inv-adversarial.test", 8, 15);
        vm.prank(bob);
        pmm.voteOnMarket(pageId, 20, 21); // bob runs the market up

        // Alice fully exits her contribution via the rebalance-style swap
        // (20, 21) -> (15, 8) which subtracts exactly her 13 yVotes and her
        // 5 xVotes, both within bounds. Hypotenuse drops 29 -> 17, which is
        // a 12 USDC refund to alice (greater than her per-axis basis but
        // within her total 17 USDC basis), exercising both cascade paths.
        vm.prank(alice);
        pmm.voteOnMarket(pageId, 15, 8);

        // Alice's net spend is 17 (initial create) - 12 (refund) = 5 USDC.
        (uint256 ay, uint256 ax) = pmm.holdings(pageId, alice);
        assertEq(ay + ax, 5 * USDC_UNIT);

        // Market-level invariant: sum of users' holdings == current scaled hypotenuse.
        _assertMarketInvariant(pageId, 17 * USDC_UNIT);
    }

    function test_invariant_userTotalStakeMatchesSumOfHoldings() public {
        // userTotalStake should always equal the sum of (yCost + xCost)
        // across every market the user has participated in.
        uint256 pageA = _createMarketAs(alice, "https://stake-sum-a.test", 3, 4);
        uint256 pageB = _createMarketAs(alice, "https://stake-sum-b.test", 5, 12);
        uint256 pageC = _createMarketAs(alice, "https://stake-sum-c.test", 8, 15);

        (uint256 ay1, uint256 ax1) = pmm.holdings(pageA, alice);
        (uint256 ay2, uint256 ax2) = pmm.holdings(pageB, alice);
        (uint256 ay3, uint256 ax3) = pmm.holdings(pageC, alice);

        assertEq(pmm.userTotalStake(alice), ay1 + ax1 + ay2 + ax2 + ay3 + ax3);

        // Mutate one of the markets (mixed-axis) and re-check.
        vm.prank(alice);
        pmm.voteOnMarket(pageB, 12, 5); // axis swap, same hypotenuse

        (ay2, ax2) = pmm.holdings(pageB, alice);
        assertEq(pmm.userTotalStake(alice), ay1 + ax1 + ay2 + ax2 + ay3 + ax3);
    }

    function test_costBasis_fullExitDropsStakeToZero() public {
        // Single-user lifecycle: create + buy up + sell back exactly to
        // origin must leave userTotalStake == original creation cost.
        uint256 pageId = _createMarketAs(alice, "https://full-exit.test", 3, 4);
        uint256 baseStake = pmm.userTotalStake(alice);

        vm.prank(alice);
        pmm.voteOnMarket(pageId, 5, 12);
        vm.prank(alice);
        pmm.voteOnMarket(pageId, 8, 15);
        vm.prank(alice);
        pmm.voteOnMarket(pageId, 3, 4);

        assertEq(pmm.userTotalStake(alice), baseStake);
        assertEq(pmm.totalStaked(), baseStake);
    }

    // ---------------------------------------------------------------
    // Liquidity safety
    // ---------------------------------------------------------------

    function test_invariant_contractBalanceEqualsHoldingsPlusFees() public {
        // Whatever sequence of moves we run, the contract's USDC balance
        // must equal sum of all market holdings (= sum of all user stakes)
        // plus the accumulated protocol fees.
        uint256 pageA = _createMarketAs(alice, "https://liq-a.test", 3, 4);
        uint256 pageB = _createMarketAs(bob, "https://liq-b.test", 5, 12);

        vm.prank(alice);
        pmm.voteOnMarket(pageA, 8, 15); // pageA: (3,4) -> (8,15), c: 5 -> 17

        vm.prank(carol);
        pmm.voteOnMarket(pageB, 7, 24); // pageB: (5,12) -> (7,24), c: 13 -> 25

        vm.prank(alice);
        pmm.voteOnMarket(pageA, 3, 4); // pageA: (8,15) -> (3,4), c: 17 -> 5

        uint256 totalHoldingsScaled = _sumScaledHypotenuses(pageA, pageB);
        uint256 expectedBalance = totalHoldingsScaled + pmm.accumulatedProtocolFees();
        assertEq(pmm.getContractBalance(), expectedBalance);
        assertEq(pmm.getAvailableLiquidity(), totalHoldingsScaled);
    }

    function test_distributeProtocolFees_drainsExactlyAccumulated() public {
        _createMarketAs(alice, "https://drain.test", 3, 4);
        vm.prank(alice);
        pmm.voteOnMarket(pageIdFromUrl("https://drain.test"), 5, 12);

        uint256 feesBefore = pmm.accumulatedProtocolFees();
        address ownerR = pmm.ownerFeeRecipient();
        address protocolR = pmm.protocolFeeRecipient();
        uint256 ownerBefore = usdc.balanceOf(ownerR);
        uint256 protocolBefore = usdc.balanceOf(protocolR);

        pmm.distributeProtocolFees(0);

        assertEq(pmm.accumulatedProtocolFees(), 0);
        assertEq(usdc.balanceOf(ownerR) + usdc.balanceOf(protocolR) - ownerBefore - protocolBefore, feesBefore);
    }

    // ---------------------------------------------------------------
    // Pause + reward interactions
    // ---------------------------------------------------------------

    function test_pauseWindow_doesNotForfeitAccruedRewards() public {
        _createMarketAs(alice, "https://pause-rewards.test", 3, 4);

        // Accrue 1 day of rewards.
        _warpForward(1 days);
        uint256 dailyEmission = _phaseOneReward(1 days);
        uint256 earnedBefore = pmm.earned(alice);
        assertEq(earnedBefore, dailyEmission);

        // Pause for a week, then unpause and claim. Emission accrues even
        // while paused (block.timestamp keeps advancing) -- that is the
        // contract's documented behaviour because emissions are based on
        // wall-clock seconds, not on a "running" flag.
        pmm.pause("");
        _warpForward(7 days);
        pmm.unpause();

        vm.prank(alice);
        pmm.claimRewards();
        assertEq(tbn.balanceOf(alice), _phaseOneReward(8 days));
    }

    function test_secondClaim_inSameBlockIsNoOp() public {
        _createMarketAs(alice, "https://second-claim.test", 3, 4);
        _warpForward(1 days);

        vm.prank(alice);
        pmm.claimRewards();
        uint256 firstBalance = tbn.balanceOf(alice);
        uint256 firstTotal = pmm.totalEmitted();

        vm.prank(alice);
        pmm.claimRewards();
        assertEq(tbn.balanceOf(alice), firstBalance);
        assertEq(pmm.totalEmitted(), firstTotal);
        assertEq(pmm.pendingRewards(alice), 0);
    }

    // ---------------------------------------------------------------
    // Phase boundary precision
    // ---------------------------------------------------------------

    function test_phaseBoundary_emittedAmountAtExactlyTwentyYears() public {
        _createMarketAs(alice, "https://phase-boundary.test", 3, 4);

        // Warp to exactly the end of phase 1 and claim.
        _warpForward(20 * 365 days);
        vm.prank(alice);
        pmm.claimRewards();
        assertEq(tbn.balanceOf(alice), 20_000_000 * 1e6);

        // One additional second should pull a tiny phase-2 chunk (rounded
        // down by mulDiv but bounded above by the per-second tail rate).
        _warpForward(1);
        vm.prank(alice);
        pmm.claimRewards();
        assertGe(tbn.balanceOf(alice), 20_000_000 * 1e6);
        assertLe(tbn.balanceOf(alice), 20_000_001 * 1e6);
    }

    // ---------------------------------------------------------------
    // Power-up uniqueness across market lifecycles
    // ---------------------------------------------------------------

    function test_powerUp_doesNotReissueWhenCoordinateIsRevisited() public {
        // Once a coordinate's power-up is claimed it must stay claimed
        // forever, even if the market hosting it moves and another market
        // later moves into that coordinate.
        uint256 firstPage = _createMarketAs(alice, "https://power-revisit-1.test", 3, 4);
        assertEq(pmm.totalPowerUpsClaimed(), 1);

        vm.prank(alice);
        pmm.voteOnMarket(firstPage, 5, 12); // (3, 4) is now free
        assertEq(pmm.totalPowerUpsClaimed(), 2);

        uint256 secondPage = _createMarketAs(bob, "https://power-revisit-2.test", 3, 4);
        assertTrue(pmm.marketExists(secondPage));
        // Power-up at (3, 4) was already claimed once; revisiting it
        // produces a new market but no new power-up.
        assertEq(pmm.totalPowerUpsClaimed(), 2);
    }

    function test_powerUp_isCoordinateClaimedReportsTrueAfterClaim() public {
        assertFalse(pmm.isCoordinatePowerUpClaimed(3, 4));
        _createMarketAs(alice, "https://power-claim-getter.test", 3, 4);
        assertTrue(pmm.isCoordinatePowerUpClaimed(3, 4));
        assertFalse(pmm.isCoordinatePowerUpClaimed(4, 3));
    }

    // ---------------------------------------------------------------
    // Adversarial / safety
    // ---------------------------------------------------------------

    function test_disableUpgrades_isIdempotent() public {
        pmm.disableUpgrades();
        pmm.disableUpgrades(); // second call should not revert
        assertTrue(pmm.isImmutable());
    }

    function test_initializerCannotBeCalledTwice() public {
        vm.expectRevert();
        pmm.initialize(address(usdc), address(tbn));
    }

    function test_marketState_returnsZeroForUnknownMarket() public view {
        uint256 unknown = uint256(keccak256("ghost"));
        (uint256 x, uint256 y, uint256 score, uint256 votes) = pmm.getMarketState(unknown);
        assertEq(x, 0);
        assertEq(y, 0);
        assertEq(score, 0);
        assertEq(votes, 0);
        assertFalse(pmm.marketExistsFor(unknown));
    }

    function test_calculatePageScore_returnsZeroAtOrigin() public view {
        assertEq(pmm.calculatePageScore(0, 0), 0);
    }

    function test_calculatePageScore_isHalfForFortyFiveDegree() public view {
        // (3, 3): score = 9 / 18 = 0.5. We tolerate 1 wei rounding.
        assertApproxEqAbs(pmm.calculatePageScore(3, 3), 5e17, 1);
    }

    function test_safeVote_emittedTransferReflectsRealCost() public {
        uint256 pageId = _createMarketAs(alice, "https://safe-vote-cost.test", 3, 4);
        uint256 balBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        pmm.voteOnMarketSafe(pageId, 3, 4, 5, 12, 250);

        // (3, 4) -> (5, 12) is a buy of 8 USDC + 1% fee = 8.08 USDC.
        assertEq(balBefore - usdc.balanceOf(alice), 8_080_000);
    }

    function test_safeVote_rejectsOversizedNewCoordinatesEarly() public {
        uint256 pageId = _createMarketAs(alice, "https://safe-vote-oversize.test", 3, 4);

        uint256 oversized = pmm.MAX_COORDINATE_VALUE() + 1;
        vm.prank(alice);
        vm.expectRevert(PythagoreanMarketMaker.CoordinateTooLarge.selector);
        pmm.voteOnMarketSafe(pageId, 3, 4, oversized, 4, 250);
    }

    function test_safeVote_rejectsOversizedExpectedCoordinatesEarly() public {
        uint256 pageId = _createMarketAs(alice, "https://safe-vote-oversize-expected.test", 3, 4);

        uint256 oversized = pmm.MAX_COORDINATE_VALUE() + 1;
        vm.prank(alice);
        vm.expectRevert(PythagoreanMarketMaker.CoordinateTooLarge.selector);
        pmm.voteOnMarketSafe(pageId, oversized, 4, 5, 12, 250);
    }

    // ---------------------------------------------------------------
    // Stress test: drive many transitions and re-verify every invariant
    // ---------------------------------------------------------------

    function test_stress_sequenceOfTransitionsKeepsAllInvariants() public {
        uint256 pageA = _createMarketAs(alice, "https://stress-a.test", 3, 4);
        uint256 pageB = _createMarketAs(bob, "https://stress-b.test", 5, 12);
        uint256 pageC = _createMarketAs(carol, "https://stress-c.test", 8, 15);

        // Sequence of legal Pythagorean transitions, mixing buys, sells,
        // mixed-axis rebalances, and a third-party vote on each market.
        // Coordinates were picked to avoid global collisions with other markets.
        vm.prank(alice);
        pmm.voteOnMarket(pageA, 7, 24);            // buy: c 5 -> 25

        vm.prank(bob);
        pmm.voteOnMarket(pageB, 20, 21);           // buy: c 13 -> 29

        vm.prank(carol);
        pmm.voteOnMarket(pageC, 15, 8);            // axis swap: same c

        vm.prank(alice);
        pmm.voteOnMarket(pageA, 12, 35);           // buy: c 25 -> 37

        vm.prank(alice);
        pmm.voteOnMarket(pageA, 3, 4);             // sell back: c 37 -> 5

        vm.prank(dave);
        pmm.voteOnMarket(pageB, 28, 45);           // buy: c 29 -> 53

        // All markets must still satisfy the per-market invariant.
        _assertMarketInvariant(pageA, _hypScaled(3, 4));
        _assertMarketInvariant(pageB, _hypScaled(28, 45));
        _assertMarketInvariant(pageC, _hypScaled(15, 8));

        // userTotalStake must equal the sum of every (yCost + xCost) for that user.
        _assertUserStakeMatchesHoldings(alice, pageA, pageB, pageC);
        _assertUserStakeMatchesHoldings(bob, pageA, pageB, pageC);
        _assertUserStakeMatchesHoldings(carol, pageA, pageB, pageC);
        _assertUserStakeMatchesHoldings(dave, pageA, pageB, pageC);

        // totalStaked must equal the sum of all userTotalStake.
        assertEq(
            pmm.totalStaked(),
            pmm.userTotalStake(alice)
                + pmm.userTotalStake(bob)
                + pmm.userTotalStake(carol)
                + pmm.userTotalStake(dave)
        );

        // Liquidity safety: contract balance == sum of scaled hypotenuses + accumulated fees.
        uint256 totalHoldings = _hypScaled(3, 4) + _hypScaled(28, 45) + _hypScaled(15, 8);
        assertEq(pmm.getContractBalance(), totalHoldings + pmm.accumulatedProtocolFees());
    }

    function _assertUserStakeMatchesHoldings(
        address user,
        uint256 pageA,
        uint256 pageB,
        uint256 pageC
    ) internal view {
        (uint256 ay, uint256 ax) = pmm.holdings(pageA, user);
        (uint256 by, uint256 bx) = pmm.holdings(pageB, user);
        (uint256 cy, uint256 cx) = pmm.holdings(pageC, user);
        assertEq(pmm.userTotalStake(user), ay + ax + by + bx + cy + cx);
    }

    // ---------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------

    function pageIdFromUrl(string memory url) internal pure returns (uint256) {
        return _pageId(url);
    }

    /// @dev Recomputes the sum of the scaled hypotenuses for the given
    ///      markets. Acts as the "expected" liquidity-side value when the
    ///      contract is invariant-healthy.
    function _sumScaledHypotenuses(uint256 pageA, uint256 pageB) internal view returns (uint256) {
        (uint256 xa, uint256 ya, , ) = pmm.getMarketState(pageA);
        (uint256 xb, uint256 yb, , ) = pmm.getMarketState(pageB);
        return _hypScaled(xa, ya) + _hypScaled(xb, yb);
    }

    function _hypScaled(uint256 x, uint256 y) internal pure returns (uint256) {
        if (x == 0 && y == 0) return 0;
        uint256 sumSquares = x * x + y * y;
        return Math.sqrt(sumSquares * (USDC_UNIT * USDC_UNIT));
    }

    function _assertMarketInvariant(uint256 pageId, uint256 expectedScaled) internal view {
        // Sum of (yCost + xCost) across all known users for this market.
        uint256 totalHoldings = 0;
        address[4] memory accounts = [alice, bob, carol, dave];
        for (uint256 i = 0; i < accounts.length; i++) {
            (uint256 yc, uint256 xc) = pmm.holdings(pageId, accounts[i]);
            totalHoldings += yc + xc;
        }
        assertEq(totalHoldings, expectedScaled);
    }
}
