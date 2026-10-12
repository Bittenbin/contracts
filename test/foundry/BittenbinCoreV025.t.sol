// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";

import {BittenbinCoreV025} from "../../src/BittenbinCoreV025.sol";
import {Tenbinium} from "../../src/Tenbinium.sol";

contract BittenbinCoreV025Test is Test {
    string internal constant DESCRIPTION = "BTC >= 100000 USD by 31 Dec 2026";
    bytes32 internal constant EVENT_ID = keccak256(bytes(DESCRIPTION));
    bytes32 internal constant FINGERPRINT = keccak256("Alice's first report");
    bytes32 internal constant FINGERPRINT_2 = keccak256("Alice's second report");

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    Tenbinium internal tbn;
    BittenbinCoreV025 internal core;

    function setUp() public {
        tbn = new Tenbinium(owner);
        core = new BittenbinCoreV025(address(tbn));

        vm.prank(owner);
        tbn.setMinter(address(core));
    }

    function testPrefixIsXThenYThenCInBinary() public view {
        (uint256 prefix, uint256 bits) = core.prefixOf(3, 4, 5);
        assertEq(prefix, 0xE5); // 11 100 101
        assertEq(bits, 8);

        (prefix, bits) = core.prefixOf(15, 20, 25);
        assertEq(prefix, 0x3E99); // 1111 10100 11001
        assertEq(bits, 14);

        (, bits) = core.prefixOf(17193, 22924, 28655);
        assertEq(bits, 45);
    }

    function testPrefixRejectsNonTriples() public {
        vm.expectRevert(BittenbinCoreV025.InvalidPoint.selector);
        core.prefixOf(3, 4, 6);
        vm.expectRevert(BittenbinCoreV025.InvalidPoint.selector);
        core.prefixOf(0, 5, 5);
        vm.expectRevert(BittenbinCoreV025.InvalidPoint.selector);
        core.prefixOf(3, 4, uint256(type(uint64).max) + 1);
    }

    function testBroadcastRecordsOpinionAndMintsReward() public {
        bytes32 opinionId = _broadcast(alice, FINGERPRINT, 15, 20, 25);

        (address wallet, uint32 version, uint16 bits, uint64 x, uint64 y, uint64 c, bytes32 eventId) = core.opinions(opinionId);
        assertEq(wallet, alice);
        assertEq(version, 1);
        assertEq(bits, 14);
        assertEq(x, 15);
        assertEq(y, 20);
        assertEq(c, 25);
        assertEq(eventId, EVENT_ID);

        assertEq(core.fingerprintOf(opinionId, 1), FINGERPRINT);
        assertTrue(core.isUsed(15, 20));
        assertEq(core.proofCount(), 1);
        assertEq(tbn.balanceOf(alice), 0.5 ether);
    }

    function testProofIsBoundToWalletAndFingerprint() public view {
        uint128 nonce = _mine(alice, EVENT_ID, FINGERPRINT, 15, 20, 25);

        assertTrue(core.isValidProof(alice, EVENT_ID, FINGERPRINT, 15, 20, 25, nonce));
        assertFalse(core.isValidProof(bob, EVENT_ID, FINGERPRINT, 15, 20, 25, nonce));
        assertFalse(core.isValidProof(alice, EVENT_ID, FINGERPRINT_2, 15, 20, 25, nonce));
    }

    function testBroadcastRejectsInvalidProof() public {
        uint128 nonce = _mine(alice, EVENT_ID, FINGERPRINT, 15, 20, 25);

        vm.prank(bob);
        vm.expectRevert(BittenbinCoreV025.InvalidProof.selector);
        core.broadcast(DESCRIPTION, FINGERPRINT, 15, 20, 25, nonce);
    }

    function testEachPointCanOnlyBeUsedOnce() public {
        _broadcast(alice, FINGERPRINT, 15, 20, 25);

        uint128 nonce = _mine(bob, EVENT_ID, FINGERPRINT, 15, 20, 25);
        vm.prank(bob);
        vm.expectRevert(BittenbinCoreV025.PointUsed.selector);
        core.broadcast(DESCRIPTION, FINGERPRINT, 15, 20, 25, nonce);
    }

    function testOneOpinionPerWalletPerEvent() public {
        _broadcast(alice, FINGERPRINT, 15, 20, 25);

        uint128 nonce = _mine(alice, EVENT_ID, FINGERPRINT_2, 3, 4, 5);
        vm.prank(alice);
        vm.expectRevert(BittenbinCoreV025.OpinionExists.selector);
        core.broadcast(DESCRIPTION, FINGERPRINT_2, 3, 4, 5, nonce);
    }

    function testUpdateChargesSignalFeeOutOfReward() public {
        bytes32 opinionId = _broadcast(alice, FINGERPRINT, 15, 20, 25);

        (uint256 reward, uint256 fee) = _update(alice, FINGERPRINT_2, 20, 15, 25);

        assertEq(reward, 0.5 ether);
        assertEq(fee, 0.28 ether); // 64% - 36%
        assertEq(tbn.balanceOf(alice), 0.5 ether + 0.22 ether);

        (, uint32 version,, uint64 x, uint64 y,,) = core.opinions(opinionId);
        assertEq(version, 2);
        assertEq(x, 20);
        assertEq(y, 15);
        assertEq(core.fingerprintOf(opinionId, 1), FINGERPRINT);
        assertEq(core.fingerprintOf(opinionId, 2), FINGERPRINT_2);
        assertTrue(core.isUsed(15, 20));
        assertTrue(core.isUsed(20, 15));
    }

    function testUpdateBurnsFeeBeyondReward() public {
        _broadcast(alice, FINGERPRINT, 7, 24, 25);

        vm.prank(alice);
        tbn.approve(address(core), type(uint256).max);
        (uint256 reward, uint256 fee) = _update(alice, FINGERPRINT_2, 24, 7, 25);

        assertEq(reward, 0.5 ether);
        assertEq(fee, 0.8432 ether); // (24/25)^2 - (7/25)^2
        assertEq(tbn.balanceOf(alice), 0.5 ether + reward - fee);
        assertEq(tbn.totalSupply(), 0.5 ether + reward - fee);
    }

    function testUpdateRejectsWeakerProof() public {
        _broadcast(alice, FINGERPRINT, 15, 20, 25);

        uint128 nonce = _mine(alice, EVENT_ID, FINGERPRINT_2, 5, 12, 13);
        vm.prank(alice);
        vm.expectRevert(BittenbinCoreV025.WeakerProof.selector);
        core.update(EVENT_ID, FINGERPRINT_2, 5, 12, 13, nonce);
    }

    function testUpdateRequiresAnOpinion() public {
        uint128 nonce = _mine(alice, EVENT_ID, FINGERPRINT, 3, 4, 5);
        vm.prank(alice);
        vm.expectRevert(BittenbinCoreV025.NoOpinion.selector);
        core.update(EVENT_ID, FINGERPRINT, 3, 4, 5, nonce);
    }

    function testRewardSchedule() public view {
        assertEq(core.rewardAt(0), 0.5 ether);
        assertEq(core.rewardAt(999_999), 0.5 ether);
        assertEq(core.rewardAt(1_000_000), 0.6 ether);
        assertEq(core.rewardAt(4_000_000), 0.9 ether);
        assertEq(core.rewardAt(5_000_000), 1 ether);
        assertEq(core.rewardAt(17_999_999), 1 ether);
        assertEq(core.rewardAt(18_000_000), 0.9 ether);
        assertEq(core.rewardAt(22_000_000), 0.5 ether);
        assertEq(core.rewardAt(23_000_000), 0.5 ether);
        assertEq(core.rewardAt(24_000_000), 0.25 ether);
        assertEq(core.rewardAt(25_000_000), 0.125 ether);
    }

    function testTotalEmissionApproachesTwentyOneMillion() public view {
        uint256 total;
        for (uint256 era = 0; era < 100; era++) {
            total += core.rewardAt(era * 1_000_000) * 1_000_000;
        }

        assertEq(core.rewardAt(99_000_000), 0);
        assertLe(total, 21_000_000 ether);
        assertGt(total, 20_999_999 ether);
    }

    function _broadcast(address wallet, bytes32 fingerprint, uint256 x, uint256 y, uint256 c)
        internal
        returns (bytes32 opinionId)
    {
        uint128 nonce = _mine(wallet, EVENT_ID, fingerprint, x, y, c);
        vm.prank(wallet);
        (opinionId,) = core.broadcast(DESCRIPTION, fingerprint, x, y, c, nonce);
    }

    function _update(address wallet, bytes32 fingerprint, uint256 x, uint256 y, uint256 c)
        internal
        returns (uint256 reward, uint256 fee)
    {
        uint128 nonce = _mine(wallet, EVENT_ID, fingerprint, x, y, c);
        vm.prank(wallet);
        (reward, fee) = core.update(EVENT_ID, fingerprint, x, y, c, nonce);
    }

    function _mine(address wallet, bytes32 eventId, bytes32 fingerprint, uint256 x, uint256 y, uint256 c)
        internal
        view
        returns (uint128 nonce)
    {
        while (!core.isValidProof(wallet, eventId, fingerprint, x, y, c, nonce)) {
            nonce++;
        }
    }
}
