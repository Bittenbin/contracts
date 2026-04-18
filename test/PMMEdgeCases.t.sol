// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {PythagoreanMarketMaker} from "../src/PythagoreanMarketMaker.sol";
import {PMMIntentTestBase, MockUSDC6} from "./helpers/PMMIntentTestBase.sol";

/**
 * @title PMMEdgeCasesTest
 * @notice Edge-case tests covering the new safe-slippage API, the optional
 *         puzzle gate, leg-decomposition cost basis tracking, the tail
 *         emission cap, and other invariants. Each test is intentionally
 *         narrow so a regression points at one specific behaviour.
 */
contract PMMEdgeCasesTest is PMMIntentTestBase {
    // ---------------------------------------------------------------
    // Safe-slippage API: voteOnMarketSafe(...)
    // ---------------------------------------------------------------

    function test_safeVote_passesWhenCurrentMatchesExpected() public {
        uint256 pageId = _createMarketAs(alice, "https://safe-vote-stable.test", 3, 4);

        uint256 aliceBalanceBefore = usdc.balanceOf(alice);

        // No drift, zero tolerance is allowed.
        vm.prank(alice);
        pmm.voteOnMarketSafe(pageId, 3, 4, 5, 12, 0);

        (uint256 x, uint256 y, , ) = pmm.getMarketState(pageId);
        assertEq(x, 5);
        assertEq(y, 12);
        // Buy of 8 USDC + 1% fee.
        assertEq(aliceBalanceBefore - usdc.balanceOf(alice), 8_080_000);
    }

    function test_safeVote_passesWhenDriftIsWithinTolerance() public {
        uint256 pageId = _createMarketAs(alice, "https://safe-vote-tolerance.test", 3, 4);

        // Bob nudges the market a tiny bit: (3, 4) -> (4, 3) is a same-c rebalance.
        // The hypotenuse cost is unchanged, so even strict 0% tolerance would pass.
        // Use (3, 4) -> (5, 12) drift instead to exercise a real deviation.
        vm.prank(bob);
        pmm.voteOnMarket(pageId, 5, 12);

        // Alice expected (3, 4); actual is (5, 12). Expected payment for
        // her (3,4) -> (8, 15) move is 12 USDC; actual payment from (5, 12)
        // -> (8, 15) is 4 USDC. Deviation magnitude is 8 USDC = ~67% of
        // the expected magnitude, so anything >= 6700 bps of tolerance
        // should accept; below that, it should reject.
        vm.prank(alice);
        pmm.voteOnMarketSafe(pageId, 3, 4, 8, 15, 7000);

        (uint256 x, uint256 y, , ) = pmm.getMarketState(pageId);
        assertEq(x, 8);
        assertEq(y, 15);
    }

    function test_safeVote_revertsWhenDriftExceedsTolerance() public {
        uint256 pageId = _createMarketAs(alice, "https://safe-vote-strict.test", 3, 4);

        vm.prank(bob);
        pmm.voteOnMarket(pageId, 5, 12);

        // Same setup as above; tolerance below the actual deviation (~67%) must revert.
        vm.prank(alice);
        vm.expectRevert(PythagoreanMarketMaker.SlippageExceeded.selector);
        pmm.voteOnMarketSafe(pageId, 3, 4, 8, 15, 5000);
    }

    function test_safeVote_rejectsInvalidSlippageBasisPoints() public {
        uint256 pageId = _createMarketAs(alice, "https://safe-vote-bad-bps.test", 3, 4);

        vm.prank(alice);
        vm.expectRevert(PythagoreanMarketMaker.InvalidSlippage.selector);
        pmm.voteOnMarketSafe(pageId, 3, 4, 5, 12, 10_001);
    }

    function test_safeVote_revertsForUnknownMarket() public {
        uint256 unknownPageId = _pageId("https://does-not-exist.test");

        vm.prank(alice);
        vm.expectRevert(PythagoreanMarketMaker.MarketDoesNotExist.selector);
        pmm.voteOnMarketSafe(unknownPageId, 3, 4, 5, 12, 250);
    }

    function test_safeVote_acceptsDriftUpToOneHundredPercentOfExpected() public {
        // At the max slippage of 10000 bps the contract accepts any drift up to
        // the magnitude of the user's *expected* payment. With a larger drift
        // they must use a different mitigation (split the trade, retry, etc.).
        uint256 pageId = _createMarketAs(alice, "https://safe-vote-max.test", 3, 4);

        // Drift the market within the user's tolerance: (3, 4) -> (5, 12)
        // changes the hypotenuse from 5 to 13, a drift of 8 USDC. Alice's
        // expected payment for (3, 4) -> (8, 15) is 12 USDC, so the drift
        // (8) is below 100% of expected (12) and the safe vote accepts.
        vm.prank(bob);
        pmm.voteOnMarket(pageId, 5, 12);

        vm.prank(alice);
        pmm.voteOnMarketSafe(pageId, 3, 4, 8, 15, 10_000);

        (uint256 x, uint256 y, , ) = pmm.getMarketState(pageId);
        assertEq(x, 8);
        assertEq(y, 15);
    }

    function test_safeVote_revertsEvenAtMaxSlippageWhenDriftTooLarge() public {
        // Sanity check: the 100% bound is real, not a free pass. A drift
        // bigger than the expected magnitude must still revert at 10000 bps.
        uint256 pageId = _createMarketAs(alice, "https://safe-vote-max-fail.test", 3, 4);

        vm.prank(bob);
        pmm.voteOnMarket(pageId, 8, 15); // drift = 12 USDC

        // Expected payment magnitude for (3, 4) -> (5, 12) is 8 USDC; the
        // 12 USDC drift exceeds 100% of that.
        vm.prank(alice);
        vm.expectRevert(PythagoreanMarketMaker.SlippageExceeded.selector);
        pmm.voteOnMarketSafe(pageId, 3, 4, 5, 12, 10_000);
    }

    // ---------------------------------------------------------------
    // Puzzle gate: setPuzzleGateEnabled and gate enforcement
    // ---------------------------------------------------------------

    function test_puzzleGate_defaultsDisabled() public view {
        assertFalse(pmm.puzzleGateEnabled());
    }

    function test_puzzleGate_onlyOwnerCanToggle() public {
        vm.prank(alice);
        vm.expectRevert();
        pmm.setPuzzleGateEnabled(true);
    }

    function test_puzzleGate_emitsEventOnTransition() public {
        vm.recordLogs();
        pmm.setPuzzleGateEnabled(true);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("PuzzleGateToggled(address,bool)");
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) {
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(address(this)))));
                bool enabled = abi.decode(logs[i].data, (bool));
                assertTrue(enabled);
                found = true;
            }
        }
        assertTrue(found, "PuzzleGateToggled not emitted");

        // Idempotent: setting to the same value emits no event.
        vm.recordLogs();
        pmm.setPuzzleGateEnabled(true);
        Vm.Log[] memory noopLogs = vm.getRecordedLogs();
        for (uint256 i = 0; i < noopLogs.length; i++) {
            assertTrue(noopLogs[i].topics[0] != sig, "duplicate toggle should be silent");
        }
    }

    function test_puzzleGate_acceptsPerfectSquareGenesis() public {
        pmm.setPuzzleGateEnabled(true);

        // (7, 24) gives c = 25 = 5², so totalC after creation is a perfect square.
        vm.prank(alice);
        pmm.createMarket("https://square-genesis.test", 7, 24);

        assertEq(pmm.totalC(), 25);
        assertEq(pmm.totalMarkets(), 1);
    }

    function test_puzzleGate_rejectsNonSquareVote() public {
        // First create a market without the gate so totalC = 25 (square).
        _createMarketAs(alice, "https://square-base.test", 7, 24);

        // Now enable the gate and try a vote that would push totalC to 26.
        pmm.setPuzzleGateEnabled(true);

        vm.prank(alice);
        vm.expectRevert(PythagoreanMarketMaker.PuzzleGateFailed.selector);
        pmm.voteOnMarket(pageIdFromUrl("https://square-base.test"), 5, 12); // c=13, totalC -> 13
    }

    function test_puzzleGate_canBeDisabledAgain() public {
        pmm.setPuzzleGateEnabled(true);

        // Gate enabled blocks (3, 4) (totalC would be 5, not a square).
        vm.prank(alice);
        vm.expectRevert(PythagoreanMarketMaker.PuzzleGateFailed.selector);
        pmm.createMarket("https://disable-loop.test", 3, 4);

        // Disable, retry, succeed.
        pmm.setPuzzleGateEnabled(false);
        vm.prank(alice);
        pmm.createMarket("https://disable-loop.test", 3, 4);

        assertEq(pmm.totalMarkets(), 1);
    }

    // ---------------------------------------------------------------
    // Cost-basis leg decomposition: full lifecycle, mixed axes, multi-user
    // ---------------------------------------------------------------

    function test_costBasis_singleUserMixedAxisSell() public {
        // Create at (5, 12) (c = 13), then mixed-axis SELL to (6, 8) (c = 10).
        uint256 pageId = _createMarketAs(alice, "https://mixed-axis-sell.test", 5, 12);
        assertEq(pmm.userTotalStake(alice), 13_000_000);

        vm.prank(alice);
        pmm.voteOnMarket(pageId, 6, 8);

        // After the move alice owns the entire (6, 8) market: stake must
        // collapse to 10 USDC, matching the new hypotenuse cost.
        assertEq(pmm.userTotalStake(alice), 10_000_000);
        assertEq(pmm.totalStaked(), 10_000_000);
    }

    function test_costBasis_axisSwapRebalanceKeepsTotal() public {
        // (3, 4) -> (4, 3) is a pure rebalance: same hypotenuse, no payment.
        uint256 pageId = _createMarketAs(alice, "https://axis-swap.test", 3, 4);
        (uint256 yCostBefore, uint256 xCostBefore) = pmm.holdings(pageId, alice);
        uint256 stakeBefore = pmm.userTotalStake(alice);

        vm.prank(alice);
        pmm.voteOnMarket(pageId, 4, 3);

        // The y/x split changes (because the new (currentX, newY) midpoint
        // is different) but the total cost basis must stay identical and
        // the user's USDC balance must be untouched.
        (uint256 yCostAfter, uint256 xCostAfter) = pmm.holdings(pageId, alice);
        assertTrue(yCostAfter != yCostBefore || xCostAfter != xCostBefore);
        assertEq(yCostAfter + xCostAfter, yCostBefore + xCostBefore);
        assertEq(pmm.userTotalStake(alice), stakeBefore);
    }

    function test_costBasis_buySellRoundTripReturnsToOriginalStake() public {
        uint256 pageId = _createMarketAs(alice, "https://round-trip.test", 3, 4);
        uint256 stakeAfterCreate = pmm.userTotalStake(alice);

        vm.prank(alice);
        pmm.voteOnMarket(pageId, 5, 12);
        assertEq(pmm.userTotalStake(alice), 13_000_000);

        vm.prank(alice);
        pmm.voteOnMarket(pageId, 3, 4);

        // Round-trip should land exactly back on the original stake.
        assertEq(pmm.userTotalStake(alice), stakeAfterCreate);
        assertEq(pmm.totalStaked(), stakeAfterCreate);
    }

    function test_costBasis_invariantHoldsAcrossMultiUserMarket() public {
        uint256 pageId = _createMarketAs(alice, "https://multi-user-invariant.test", 3, 4);

        vm.prank(bob);
        pmm.voteOnMarket(pageId, 5, 12);

        // Invariant: sum(yCost + xCost across users) == current scaled hypotenuse
        // (= 13 USDC in raw units for (5, 12)).
        (uint256 ay, uint256 ax) = pmm.holdings(pageId, alice);
        (uint256 by, uint256 bx) = pmm.holdings(pageId, bob);
        assertEq(ay + ax + by + bx, 13_000_000);
        assertEq(pmm.userTotalStake(alice) + pmm.userTotalStake(bob), 13_000_000);
        assertEq(pmm.totalStaked(), 13_000_000);
    }

    function test_costBasis_doubleClaimSameMoveStaysConsistent() public {
        // Two consecutive mixed-axis buys by the same user must keep the
        // user's stake equal to the current hypotenuse the whole way.
        uint256 pageId = _createMarketAs(alice, "https://double-claim.test", 6, 8);
        assertEq(pmm.userTotalStake(alice), 10_000_000);

        vm.prank(alice);
        pmm.voteOnMarket(pageId, 5, 12);
        assertEq(pmm.userTotalStake(alice), 13_000_000);

        vm.prank(alice);
        pmm.voteOnMarket(pageId, 8, 15);
        assertEq(pmm.userTotalStake(alice), 17_000_000);
    }

    // ---------------------------------------------------------------
    // Tail emission cap
    // ---------------------------------------------------------------

    function test_emission_capExhaustsCleanlyForSecondClaim() public {
        _createMarketAs(alice, "https://emission-cap.test", 3, 4);
        _warpForward(300 * 365 days);

        vm.prank(alice);
        pmm.claimRewards();
        assertEq(pmm.totalEmitted(), pmm.MAX_EMISSION());
        assertEq(pmm.pendingRewards(alice), 0);

        // A second claim should be a silent no-op (pending == 0), never a
        // permanent EmissionExhausted lockout.
        vm.prank(alice);
        pmm.claimRewards();
        assertEq(pmm.totalEmitted(), pmm.MAX_EMISSION());
        assertEq(tbn.balanceOf(alice), pmm.MAX_EMISSION());
    }

    function test_emission_capSplitsAcrossUsers() public {
        _createMarketAs(alice, "https://emission-cap-a.test", 3, 4);
        _createMarketAs(bob, "https://emission-cap-b.test", 5, 12);

        _warpForward(300 * 365 days);

        // Both users claim. Sum of their TBN must exactly equal MAX_EMISSION
        // and their split must reflect their 5 : 13 stake share.
        vm.prank(alice);
        pmm.claimRewards();
        vm.prank(bob);
        pmm.claimRewards();

        assertEq(tbn.balanceOf(alice) + tbn.balanceOf(bob), pmm.MAX_EMISSION());

        // Allow 1000 raw-unit (1e-3 TBN) drift: claim-order rounding plus the
        // ceilDiv tail overshoot above 21M concentrates a few dust units in
        // whichever account claims first. The split is still well within
        // 0.001 TBN of perfect proportionality on a 21M TBN cap.
        uint256 expectedAlice = (uint256(pmm.MAX_EMISSION()) * 5) / 18;
        uint256 expectedBob = (uint256(pmm.MAX_EMISSION()) * 13) / 18;
        assertApproxEqAbs(tbn.balanceOf(alice), expectedAlice, 1000);
        assertApproxEqAbs(tbn.balanceOf(bob), expectedBob, 1000);
    }

    function test_emission_thirdPartyCannotClaimAfterCapHit() public {
        _createMarketAs(alice, "https://exhausted-third.test", 3, 4);
        _warpForward(300 * 365 days);

        vm.prank(alice);
        pmm.claimRewards();

        // A new staker arriving after the cap is hit gets 0 even if they
        // try to claim (their pending starts at 0).
        _createMarketAs(carol, "https://carol-late.test", 5, 12);
        vm.prank(carol);
        pmm.claimRewards();
        assertEq(tbn.balanceOf(carol), 0);
    }

    function test_emission_phaseTransitionReturnsExpectedTwentyOneMillion() public {
        _createMarketAs(alice, "https://phase-transition-cap.test", 3, 4);

        // Walk through phase 1, then a few halving epochs, claim incrementally.
        _warpForward(20 * 365 days); // end of phase 1
        vm.prank(alice);
        pmm.claimRewards();
        assertEq(tbn.balanceOf(alice), 20_000_000 * 1e6);

        _warpForward(50 * 365 days); // well into the tail
        vm.prank(alice);
        pmm.claimRewards();
        // Tail should accumulate close to the full 1M TBN budget but never
        // exceed it.
        assertLe(tbn.balanceOf(alice), pmm.MAX_EMISSION());
        assertGt(tbn.balanceOf(alice), 20_999_900 * 1e6);
    }

    // ---------------------------------------------------------------
    // Other invariants and gates
    // ---------------------------------------------------------------

    function test_disableUpgrades_blocksToggleAfterFreeze() public {
        // disableUpgrades is one-way; subsequent upgrade attempts revert.
        pmm.disableUpgrades();
        assertTrue(pmm.isImmutable());

        PythagoreanMarketMaker fresh = new PythagoreanMarketMaker();
        vm.expectRevert(PythagoreanMarketMaker.UpgradesDisabled.selector);
        pmm.upgradeToAndCall(address(fresh), bytes(""));

        // Toggling the puzzle gate is unaffected (it's not an upgrade).
        pmm.setPuzzleGateEnabled(true);
        assertTrue(pmm.puzzleGateEnabled());
    }

    function test_distributeFees_revertsWhenNothingAccumulated() public {
        vm.expectRevert(PythagoreanMarketMaker.InvalidFeeAmount.selector);
        pmm.distributeProtocolFees(0);
    }

    function test_withdrawToOwner_revertsWhenAmountExceedsAccumulated() public {
        _createMarketAs(alice, "https://withdraw-too-much.test", 3, 4);
        uint256 fees = pmm.accumulatedProtocolFees();

        vm.expectRevert(PythagoreanMarketMaker.InvalidFeeAmount.selector);
        pmm.withdrawToOwner(fees + 1);
    }

    function test_updateFeeRecipients_rejectsZeroAddress() public {
        vm.expectRevert(PythagoreanMarketMaker.InvalidAddress.selector);
        pmm.updateFeeRecipients(address(0), bob);

        vm.expectRevert(PythagoreanMarketMaker.InvalidAddress.selector);
        pmm.updateFeeRecipients(alice, address(0));
    }

    function test_marketCreated_eventCarriesIntegerHypotenuseForOtherTriples() public {
        // Re-run the spec event check with a different triple (5, 12, 13)
        // to make sure the cost field is the integer hypotenuse generally.
        string memory url = "https://event-cost-other.test";
        uint256 pageId = _pageId(url);

        vm.recordLogs();
        vm.prank(alice);
        pmm.createMarket(url, 5, 12);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("MarketCreated(uint256,address,uint256,uint256,uint256)");
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) {
                assertEq(logs[i].topics[1], bytes32(pageId));
                (uint256 x, uint256 y, uint256 cost) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                assertEq(x, 5);
                assertEq(y, 12);
                assertEq(cost, 13);
                found = true;
            }
        }
        assertTrue(found);
    }

    function test_voteOnMarket_rejectsNoOpUpdates() public {
        uint256 pageId = _createMarketAs(alice, "https://noop.test", 3, 4);

        vm.prank(alice);
        vm.expectRevert(PythagoreanMarketMaker.InvalidCoordinate.selector);
        pmm.voteOnMarket(pageId, 3, 4);
    }

    function test_voteOnMarket_rejectsNonPythagoreanTarget() public {
        uint256 pageId = _createMarketAs(alice, "https://bad-target.test", 3, 4);

        vm.prank(alice);
        vm.expectRevert(PythagoreanMarketMaker.InvalidCoordinate.selector);
        pmm.voteOnMarket(pageId, 2, 3); // c² = 13, not a perfect square
    }

    function test_voteOnMarket_rejectsCoordinateOccupiedByAnotherMarket() public {
        _createMarketAs(alice, "https://collision-source.test", 3, 4);
        uint256 secondPage = _createMarketAs(bob, "https://collision-target.test", 5, 12);

        // Bob can't move his (5, 12) to (3, 4) because that coordinate is
        // already occupied by another market.
        vm.prank(bob);
        vm.expectRevert(PythagoreanMarketMaker.CoordinateOccupied.selector);
        pmm.voteOnMarket(secondPage, 3, 4);
    }

    function test_pause_blocksSafeVote() public {
        uint256 pageId = _createMarketAs(alice, "https://pause-safe.test", 3, 4);

        pmm.pause("");

        vm.prank(alice);
        vm.expectRevert();
        pmm.voteOnMarketSafe(pageId, 3, 4, 5, 12, 250);
    }

    // ---------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------

    function pageIdFromUrl(string memory url) internal pure returns (uint256) {
        return _pageId(url);
    }
}
