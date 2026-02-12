// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PythagoreanMarketMaker} from "../src/PythagoreanMarketMaker.sol";
import {TenbinToken} from "../src/tokens/TenbinToken.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

interface Vm {
    function startPrank(address sender) external;
    function stopPrank() external;
    function expectRevert(bytes calldata) external;
}

contract MockUSDC is ERC20 {
    uint8 private constant DECIMALS = 6;

    constructor() ERC20("USDC", "USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return DECIMALS;
    }
}

contract EdgeCasesTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    PythagoreanMarketMaker private pmm;
    MockUSDC private usdc;
    TenbinToken private tenbin;

    address private owner = address(0xABCD);
    address private alice = address(0xA11CE);
    address private bob = address(0xB0B);

    function setUp() public {
        vm.startPrank(owner);
        usdc = new MockUSDC();
        tenbin = new TenbinToken(owner);
        pmm = _deployPmmProxy(address(usdc), address(tenbin));
        vm.stopPrank();

        _fundAndApprove(alice, 1_000_000 * 1e6);
        _fundAndApprove(bob, 1_000_000 * 1e6);
    }

    function testEmptyUrlReverts() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(PythagoreanMarketMaker.InvalidUrl.selector));
        pmm.createMarket("", 3, 4);
        vm.stopPrank();
    }

    function testDiagonalMoveReverts() public {
        string memory url = "https://diagonal.com";
        vm.startPrank(alice);
        pmm.createMarket(url, 3, 4);
        vm.stopPrank();

        bytes32 urlHash = keccak256(bytes(url));
        uint256 pageId = uint256(urlHash);

        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(PythagoreanMarketMaker.InvalidCoordinate.selector));
        pmm.voteOnMarket(pageId, 5, 6);
        vm.stopPrank();
    }

    function testNoOpMoveReverts() public {
        string memory url = "https://noop.com";
        vm.startPrank(alice);
        pmm.createMarket(url, 3, 4);
        vm.stopPrank();

        bytes32 urlHash = keccak256(bytes(url));
        uint256 pageId = uint256(urlHash);

        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(PythagoreanMarketMaker.InvalidCoordinate.selector));
        pmm.voteOnMarket(pageId, 3, 4);
        vm.stopPrank();
    }

    function testSingleAxisUpvoteMove() public {
        string memory url = "https://upvote.com";
        vm.startPrank(alice);
        pmm.createMarket(url, 3, 4);
        vm.stopPrank();

        bytes32 urlHash = keccak256(bytes(url));
        uint256 pageId = uint256(urlHash);

        vm.startPrank(bob);
        pmm.voteOnMarket(pageId, 3, 10);
        vm.stopPrank();

        (uint256 x, uint256 y) = pmm.marketCoordinates(pageId);
        _assertEq(x, 3);
        _assertEq(y, 10);

        (uint256 upvotes, uint256 downvotes, bool exists) = pmm.getVoterPosition(pageId, bob);
        _assertTrue(exists);
        _assertEq(upvotes, 6);
        _assertEq(downvotes, 0);
    }

    function testSingleAxisDownvoteMove() public {
        string memory url = "https://downvote.com";
        vm.startPrank(alice);
        pmm.createMarket(url, 3, 4);
        vm.stopPrank();

        bytes32 urlHash = keccak256(bytes(url));
        uint256 pageId = uint256(urlHash);

        vm.startPrank(bob);
        pmm.voteOnMarket(pageId, 10, 4);
        vm.stopPrank();

        (uint256 x, uint256 y) = pmm.marketCoordinates(pageId);
        _assertEq(x, 10);
        _assertEq(y, 4);

        (uint256 upvotes, uint256 downvotes, bool exists) = pmm.getVoterPosition(pageId, bob);
        _assertTrue(exists);
        _assertEq(upvotes, 0);
        _assertEq(downvotes, 7);
    }

    function _fundAndApprove(address user, uint256 amount) private {
        vm.startPrank(owner);
        usdc.mint(user, amount);
        vm.stopPrank();

        vm.startPrank(user);
        usdc.approve(address(pmm), type(uint256).max);
        vm.stopPrank();
    }

    function _deployPmmProxy(address usdcAddress, address tenbinAddress) private returns (PythagoreanMarketMaker) {
        PythagoreanMarketMaker implementation = new PythagoreanMarketMaker();
        bytes memory data = abi.encodeWithSelector(
            PythagoreanMarketMaker.initialize.selector,
            usdcAddress,
            tenbinAddress
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), data);
        return PythagoreanMarketMaker(address(proxy));
    }

    function _assertEq(uint256 actual, uint256 expected) private pure {
        require(actual == expected, "assertEq failed");
    }

    function _assertTrue(bool value) private pure {
        require(value, "assertTrue failed");
    }
}
