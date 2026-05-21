// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {PMMV2Base} from "./PMMV2Base.t.sol";
import {PythagoreanMarketMakerV2} from "../../src/PythagoreanMarketMakerV2.sol";

contract PMMV2IdentityTest is PMMV2Base {
    event AgentCreated(bytes32 indexed agentId, string primaryId, address indexed creator, uint256 x, uint256 y, uint256 c);

    function testDerivesAgentIdAndEmitsPrimaryId() public {
        string memory primaryId = "bittenbin-alice";
        bytes32 id = agentId(primaryId);

        vm.expectEmit(true, false, false, true, address(pmm));
        emit AgentCreated(id, primaryId, alice, 5, 12, 13);
        _create(alice, primaryId, 5, 12);

        _assertAgent(id, 5, 12, 13);
    }

    function testRejectsDuplicateAndEmptyPrimaryIds() public {
        _create(alice, "bittenbin-bob", 10, 24);

        vm.prank(alice);
        vm.expectRevert(PythagoreanMarketMakerV2.AgentAlreadyExists.selector);
        pmm.createAgent("bittenbin-bob", 15, 20);

        vm.prank(alice);
        vm.expectRevert(PythagoreanMarketMakerV2.InvalidPrimaryId.selector);
        pmm.createAgent("", 15, 20);
    }
}
