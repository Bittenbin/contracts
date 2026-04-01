// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";

import {TenbinToken} from "../src/tokens/TenbinToken.sol";

contract TenbinTokenIntentTest is Test {
    TenbinToken internal tbn;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        tbn = new TenbinToken(address(this));
    }

    function test_constructor_setsRolesDecimalsAndRemainingSupply() public view {
        assertEq(tbn.name(), "TENBINIUM");
        assertEq(tbn.symbol(), "TBN");
        assertEq(tbn.decimals(), 6);
        assertEq(tbn.minter(), address(this));
        assertEq(tbn.burner(), address(this));
        assertEq(tbn.remainingMintableSupply(), tbn.MAX_SUPPLY());
    }

    function test_onlyOwnerCanRotateMinterAndBurnerRoles() public {
        vm.prank(alice);
        vm.expectRevert();
        tbn.setMinter(alice);

        vm.prank(alice);
        vm.expectRevert();
        tbn.setBurner(bob);

        tbn.setMinter(alice);
        tbn.setBurner(bob);

        assertEq(tbn.minter(), alice);
        assertEq(tbn.burner(), bob);
    }

    function test_onlyMinterCanMintWithinCap() public {
        tbn.setMinter(alice);

        vm.expectRevert(TenbinToken.NotMinter.selector);
        tbn.mint(bob, 1);

        vm.prank(alice);
        tbn.mint(bob, 123_456_789);

        assertEq(tbn.balanceOf(bob), 123_456_789);
        assertEq(tbn.totalSupply(), 123_456_789);
        assertEq(tbn.remainingMintableSupply(), tbn.MAX_SUPPLY() - 123_456_789);
    }

    function test_mintCannotExceedMaxSupply() public {
        tbn.mint(address(this), tbn.MAX_SUPPLY());

        vm.expectRevert(TenbinToken.ExceedsMaxSupply.selector);
        tbn.mint(address(this), 1);
    }

    function test_onlyBurnerCanBurnWithoutAllowance() public {
        tbn.mint(alice, 1_000_000);
        tbn.setBurner(bob);

        vm.expectRevert(TenbinToken.NotBurner.selector);
        tbn.burn(alice, 1);

        vm.prank(bob);
        tbn.burn(alice, 400_000);

        assertEq(tbn.balanceOf(alice), 600_000);
        assertEq(tbn.totalSupply(), 600_000);
    }
}
