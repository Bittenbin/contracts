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

contract PlatformMarketsTest {
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

    function testCreateMarketUsesUrlHashAsPlatformId() public {
        string memory url = "https://apple.com";
        bytes32 urlHash = keccak256(bytes(url));
        uint256 pageId = uint256(urlHash);

        vm.startPrank(alice);
        pmm.createMarket(url, 3, 4);
        vm.stopPrank();

        _assertTrue(pmm.marketExistsFor(pageId));

        (uint256 x, uint256 y) = pmm.marketCoordinates(pageId);
        _assertEq(x, 3);
        _assertEq(y, 4);

        _assertEqBytes32(pmm.marketUrlHash(pageId), urlHash);
        _assertTrue(pmm.urlHashUsed(urlHash));
    }

    function testRejectsDuplicateUrl() public {
        string memory url = "https://example.com";

        vm.startPrank(alice);
        pmm.createMarket(url, 3, 4);
        vm.stopPrank();

        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(PythagoreanMarketMaker.MarketAlreadyExists.selector));
        pmm.createMarket(url, 5, 12);
        vm.stopPrank();
    }

    function testAllowsNonPythagoreanCoordinates() public {
        string memory url = "https://non-pythagorean.com";

        vm.startPrank(alice);
        pmm.createMarket(url, 4, 5);
        vm.stopPrank();

        bytes32 urlHash = keccak256(bytes(url));
        uint256 pageId = uint256(urlHash);
        (uint256 x, uint256 y) = pmm.marketCoordinates(pageId);
        _assertEq(x, 4);
        _assertEq(y, 5);
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

    function _assertEqBytes32(bytes32 actual, bytes32 expected) private pure {
        require(actual == expected, "assertEq bytes32 failed");
    }

    function _assertTrue(bool value) private pure {
        require(value, "assertTrue failed");
    }
}
