// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {PythagoreanMarketMaker} from "../src/PythagoreanMarketMaker.sol";
import {PMMIntentTestBase} from "./helpers/PMMIntentTestBase.sol";

contract PMMIntentRewardsAndAdminTest is PMMIntentTestBase {
    function test_rewardsStartOnFirstStake_withoutRetroactiveAccrual() public {
        assertEq(pmm.emissionStartTime(), 0);

        _warpForward(7 days);
        assertEq(pmm.emissionStartTime(), 0);

        _createMarketAs(alice, "https://rewards-start.test", 3, 4);
        assertEq(pmm.emissionStartTime(), block.timestamp);
        assertEq(pmm.earned(alice), 0);

        _warpForward(1 days);
        assertEq(pmm.earned(alice), _phaseOneReward(1 days));
    }

    function test_claimRewards_isGlobalAcrossAllUserMarkets() public {
        _createMarketAs(alice, "https://claim-a.test", 3, 4);
        _createMarketAs(alice, "https://claim-b.test", 8, 15);

        assertEq(pmm.userTotalStake(alice), 22_000_000);

        _warpForward(1 days);

        uint256 dailyEmission = _phaseOneReward(1 days);
        uint256 rewardPerTokenDelta = Math.mulDiv(dailyEmission, 1e18, pmm.totalStaked());
        uint256 expectedReward = Math.mulDiv(pmm.userTotalStake(alice), rewardPerTokenDelta, 1e18);
        assertEq(pmm.earned(alice), expectedReward);

        vm.prank(alice);
        pmm.claimRewards();

        assertEq(tbn.balanceOf(alice), expectedReward);
        assertEq(pmm.totalEmitted(), expectedReward);
        assertEq(pmm.pendingRewards(alice), 0);
    }

    function test_rewardsSplitProportionallyAcrossUsersByTrackedStake() public {
        _createMarketAs(alice, "https://split-a.test", 3, 4);

        _warpForward(10 days);

        _createMarketAs(bob, "https://split-b.test", 5, 12);

        _warpForward(20 days);

        uint256 firstWindowReward = _phaseOneReward(10 days);
        uint256 secondWindowReward = _phaseOneReward(20 days);
        uint256 secondWindowRPT = Math.mulDiv(secondWindowReward, 1e18, 18_000_000);

        uint256 expectedAlice = firstWindowReward + Math.mulDiv(5_000_000, secondWindowRPT, 1e18);
        uint256 expectedBob = Math.mulDiv(13_000_000, secondWindowRPT, 1e18);

        assertEq(pmm.earned(alice), expectedAlice);
        assertEq(pmm.earned(bob), expectedBob);
        assertEq(expectedAlice + expectedBob, pmm.earned(alice) + pmm.earned(bob));
    }

    function test_emissionRate_transitionsFromPhaseOneToHalvingTail() public {
        _createMarketAs(alice, "https://phase-transition.test", 3, 4);

        uint256 phaseOneRate = _annualToPerSecond(pmm.PHASE_ONE_ANNUAL_EMISSION());
        uint256 tailInitialRate = _annualToPerSecond(pmm.PHASE_TWO_INITIAL_ANNUAL_EMISSION());
        uint256 tailSecondYearRate = _annualToPerSecond(pmm.PHASE_TWO_INITIAL_ANNUAL_EMISSION() / 2);

        assertEq(pmm.getEmissionRate(), phaseOneRate);

        _warpForward(pmm.PHASE_ONE_DURATION() - 1);
        assertEq(pmm.getEmissionRate(), phaseOneRate);

        _warpForward(1);
        assertEq(pmm.getEmissionRate(), tailInitialRate);

        _warpForward(pmm.PHASE_TWO_HALVING_PERIOD());
        assertEq(pmm.getEmissionRate(), tailSecondYearRate);
    }

    function test_distributeProtocolFees_splitsEvenlyBetweenRecipients() public {
        _createMarketAs(alice, "https://fees.test", 3, 4);

        address ownerRecipient = pmm.ownerFeeRecipient();
        address protocolRecipient = pmm.protocolFeeRecipient();
        uint256 ownerBalanceBefore = usdc.balanceOf(ownerRecipient);
        uint256 protocolBalanceBefore = usdc.balanceOf(protocolRecipient);

        pmm.distributeProtocolFees(0);

        assertEq(usdc.balanceOf(ownerRecipient) - ownerBalanceBefore, 25_000);
        assertEq(usdc.balanceOf(protocolRecipient) - protocolBalanceBefore, 25_000);
        assertEq(pmm.accumulatedProtocolFees(), 0);
    }

    function test_ownerCanUpdateRecipientsAndWithdrawFeesIndividually() public {
        _createMarketAs(alice, "https://withdraw.test", 3, 4);

        address newOwnerRecipient = makeAddr("newOwnerRecipient");
        address newProtocolRecipient = makeAddr("newProtocolRecipient");

        pmm.updateFeeRecipients(newOwnerRecipient, newProtocolRecipient);
        assertEq(pmm.ownerFeeRecipient(), newOwnerRecipient);
        assertEq(pmm.protocolFeeRecipient(), newProtocolRecipient);

        pmm.withdrawToOwner(20_000);
        pmm.withdrawToProtocol(30_000);

        assertEq(usdc.balanceOf(newOwnerRecipient), 20_000);
        assertEq(usdc.balanceOf(newProtocolRecipient), 30_000);
        assertEq(pmm.accumulatedProtocolFees(), 0);
    }

    function test_adminControls_requireOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        pmm.pause("nope");

        vm.prank(alice);
        vm.expectRevert();
        pmm.distributeProtocolFees(0);

        vm.prank(alice);
        vm.expectRevert();
        pmm.updateFeeRecipients(alice, bob);
    }

    function test_disableUpgrades_blocksFurtherProxyUpgrades() public {
        PythagoreanMarketMaker newImplementation = new PythagoreanMarketMaker();

        pmm.disableUpgrades();

        assertTrue(pmm.isImmutable());

        vm.expectRevert(PythagoreanMarketMaker.UpgradesDisabled.selector);
        pmm.upgradeToAndCall(address(newImplementation), bytes(""));
    }
}
