// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {PythagoreanMarketMakerV2} from "../../src/PythagoreanMarketMakerV2.sol";
import {Tenbinium} from "../../src/Tenbinium.sol";

abstract contract PMMV2Base is Test {
    uint256 internal constant YEAR = 365 days;
    uint256 internal constant USDC = 1e6;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal charlie = makeAddr("charlie");

    MockUSDC internal mockUSDC;
    Tenbinium internal tbn;
    PythagoreanMarketMakerV2 internal pmm;

    function setUp() public virtual {
        mockUSDC = new MockUSDC();
        tbn = new Tenbinium(owner);
        pmm = new PythagoreanMarketMakerV2(address(mockUSDC), address(tbn), owner);

        vm.prank(owner);
        tbn.setMinter(address(pmm));

        _fundAndApprove(alice);
        _fundAndApprove(bob);
        _fundAndApprove(charlie);
    }

    function agentId(string memory primaryId) internal pure returns (bytes32) {
        return keccak256(bytes(primaryId));
    }

    function _fundAndApprove(address user) internal {
        mockUSDC.mint(user, 1_000_000 * USDC);
        vm.prank(user);
        mockUSDC.approve(address(pmm), type(uint256).max);
    }

    function _create(address user, string memory primaryId, uint256 x, uint256 y) internal returns (bytes32 id) {
        id = agentId(primaryId);
        vm.prank(user);
        pmm.createAgent(primaryId, x, y);
    }

    function _relocate(
        address user,
        bytes32 id,
        uint256 currentX,
        uint256 currentY,
        uint256 newX,
        uint256 newY
    ) internal {
        vm.prank(user);
        pmm.relocateAgent(id, currentX, currentY, newX, newY);
    }

    function _claim(address user) internal {
        vm.prank(user);
        pmm.claimTBN();
    }

    function _approveTbnBurn(address user, uint256 amount) internal {
        vm.prank(user);
        tbn.approve(address(pmm), amount);
    }

    function _assertAgent(bytes32 id, uint256 x, uint256 y, uint256 c) internal view {
        (uint256 actualX, uint256 actualY, uint256 actualC, bool exists) = pmm.getAgentState(id);
        assertTrue(exists);
        assertEq(actualX, x);
        assertEq(actualY, y);
        assertEq(actualC, c);
    }

    function _expectOwnableUnauthorized(address caller) internal {
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", caller));
    }
}
