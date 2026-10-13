// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";

import {BittenbinCoreV026} from "../../src/BittenbinCoreV026.sol";
import {Tenbinium} from "../../src/Tenbinium.sol";

abstract contract BittenbinCoreV026Base is Test {
    string internal constant QUESTION = "BTC >= 100000 USD by 31 Dec 2026";
    uint256 internal constant WINDOW = 1 hours;
    // A question that stays open for one hour costs 1 TBN.
    uint256 internal constant FEE = 1 ether;

    address internal owner = makeAddr("owner");
    address internal customer = makeAddr("customer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    Tenbinium internal tbn;
    BittenbinCoreV026 internal core;

    function setUp() public virtual {
        tbn = new Tenbinium(owner);
        core = new BittenbinCoreV026(address(tbn));

        // The customer needs TBN before any neuron has earned some, so mint it directly for the tests.
        vm.prank(owner);
        tbn.setMinter(address(this));
        tbn.mint(customer, 1_000 ether);
        vm.prank(owner);
        tbn.setMinter(address(core));

        vm.prank(customer);
        tbn.approve(address(core), type(uint256).max);
    }

    function _threeNeuronsStore() internal returns (uint256 questionId) {
        _create(alice, 15, 20, 25);
        _create(carol, 24, 7, 25);
        _create(bob, 20, 21, 29);
        questionId = _ask();

        vm.prank(alice);
        core.store(questionId, 15, 20, "");
        vm.prank(carol);
        core.store(questionId, 24, 7, "");
        vm.prank(bob);
        core.store(questionId, 20, 21, "");
    }

    function _ask() internal returns (uint256 questionId) {
        vm.prank(customer);
        questionId = core.ask(QUESTION, WINDOW);
    }

    function _create(address wallet, uint256 x, uint256 y, uint256 c) internal {
        uint128 nonce = _mine(wallet, x, y, c);
        vm.prank(wallet);
        core.createNeuron(x, y, c, nonce);
    }

    function _mine(address wallet, uint256 x, uint256 y, uint256 c) internal view returns (uint128 nonce) {
        while (!core.isValidProof(wallet, x, y, c, nonce)) {
            nonce++;
        }
    }
}
