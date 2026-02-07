// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {PythagoreanMarketMaker} from "../src/PythagoreanMarketMaker.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

interface Vm {
    function envString(string calldata name) external returns (string memory value);
    function createSelectFork(string calldata url) external returns (uint256 forkId);
    function startPrank(address sender) external;
    function stopPrank() external;
    function expectRevert(bytes calldata) external;
}

contract SingleAxisTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    PythagoreanMarketMaker private pmm;
    MockUSDC private usdc;

    address private voter = address(0xBEEF);
    uint256 private platformId = 1234567890;

    function setUp() public {
        string memory rpcUrl = vm.envString("BASE_MAINNET_RPC_URL");
        vm.createSelectFork(rpcUrl);

        usdc = new MockUSDC();
        pmm = new PythagoreanMarketMaker();
        pmm.initialize(address(usdc));

        usdc.mint(voter, 1_000_000_000);

        vm.startPrank(voter);
        usdc.approve(address(pmm), type(uint256).max);
        pmm.createMarket(platformId, 3, 4);
        vm.stopPrank();
    }

    function testDiagonalMoveReverts() public {
        vm.startPrank(voter);
        vm.expectRevert(abi.encodeWithSelector(PythagoreanMarketMaker.InvalidCoordinate.selector));
        pmm.voteOnMarket(platformId, 4, 5);
        vm.stopPrank();
    }

    function testXAxisMoveSucceeds() public {
        vm.startPrank(voter);
        pmm.voteOnMarket(platformId, 5, 4);
        vm.stopPrank();

        (uint256 x, uint256 y) = pmm.marketCoordinates(platformId);
        _assertEq(x, 5);
        _assertEq(y, 4);
    }

    function testYAxisMoveSucceeds() public {
        vm.startPrank(voter);
        pmm.voteOnMarket(platformId, 3, 6);
        vm.stopPrank();

        (uint256 x, uint256 y) = pmm.marketCoordinates(platformId);
        _assertEq(x, 3);
        _assertEq(y, 6);
    }

    function _assertEq(uint256 actual, uint256 expected) internal pure {
        require(actual == expected, "assertion failed");
    }
}
