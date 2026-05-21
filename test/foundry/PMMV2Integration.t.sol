// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {PMMV2Base} from "./PMMV2Base.t.sol";

contract PMMV2IntegrationTest is PMMV2Base {
    function testEndToEndSolverLifecycle() public {
        bytes32 aliceId = _create(alice, "integration-alice", 15, 20);
        _create(bob, "integration-bob", 18, 24);

        assertEq(pmm.nMax(), 5);
        assertTrue(pmm.areConnected(aliceId, agentId("integration-bob")));

        vm.warp(block.timestamp + YEAR);
        _claim(alice);
        assertApproxEqAbs(tbn.balanceOf(alice), 1_000_000 ether, 2 ether);

        _approveTbnBurn(alice, 100 ether);
        uint256 vaultBalance = pmm.accumulatedProtocolFees();
        uint256 usdcBefore = mockUSDC.balanceOf(alice);
        vm.prank(alice);
        pmm.redeemFeeVault();

        assertEq(mockUSDC.balanceOf(alice), usdcBefore + vaultBalance);
        assertEq(pmm.accumulatedProtocolFees(), 0);
    }

    function testMaintainsTvlAndCoordinateLifecycleInMixedSequence() public {
        bytes32 a = _create(alice, "mixed-a", 3, 4);
        bytes32 b = _create(bob, "mixed-b", 5, 12);
        bytes32 c = _create(charlie, "mixed-c", 8, 15);
        assertEq(pmm.totalStakedValue(), 35);

        _relocate(alice, a, 3, 4, 7, 24);
        _relocate(bob, b, 5, 12, 20, 21);
        _relocate(charlie, c, 8, 15, 3, 4);

        assertEq(pmm.totalStakedValue(), 59);
        _assertAgent(a, 7, 24, 25);
        _assertAgent(b, 20, 21, 29);
        _assertAgent(c, 3, 4, 5);
    }
}
