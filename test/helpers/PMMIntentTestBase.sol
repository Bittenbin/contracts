// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PythagoreanMarketMaker} from "../../src/PythagoreanMarketMaker.sol";
import {TenbinToken} from "../../src/tokens/TenbinToken.sol";

contract MockUSDC6 is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

abstract contract PMMIntentTestBase is Test {
    uint256 internal constant USDC_UNIT = 1e6;
    uint256 internal constant FUND_AMOUNT = 2_000_000 * USDC_UNIT;

    PythagoreanMarketMaker internal pmm;
    MockUSDC6 internal usdc;
    TenbinToken internal tbn;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");

    function setUp() public virtual {
        usdc = new MockUSDC6();
        tbn = new TenbinToken(address(this));

        PythagoreanMarketMaker implementation = new PythagoreanMarketMaker();
        bytes memory initData = abi.encodeCall(
            PythagoreanMarketMaker.initialize,
            (address(usdc), address(tbn))
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        pmm = PythagoreanMarketMaker(address(proxy));

        tbn.setMinter(address(pmm));

        _fundAndApprove(alice);
        _fundAndApprove(bob);
        _fundAndApprove(carol);
        _fundAndApprove(dave);
    }

    function _fundAndApprove(address user) internal {
        usdc.mint(user, FUND_AMOUNT);
        vm.prank(user);
        usdc.approve(address(pmm), type(uint256).max);
    }

    function _pageId(string memory url) internal pure returns (uint256) {
        return uint256(keccak256(bytes(url)));
    }

    function _createMarketAs(
        address creator,
        string memory url,
        uint256 x,
        uint256 y
    ) internal returns (uint256 pageId) {
        pageId = _pageId(url);
        vm.prank(creator);
        pmm.createMarket(url, x, y);
    }

    function _warpForward(uint256 secondsForward) internal {
        vm.warp(block.timestamp + secondsForward);
        vm.roll(block.number + 1);
    }

    function _phaseOneReward(uint256 duration) internal view returns (uint256) {
        return Math.mulDiv(duration, pmm.PHASE_ONE_ANNUAL_EMISSION(), pmm.SECONDS_PER_YEAR());
    }

    function _annualToPerSecond(uint256 annualEmission) internal view returns (uint256) {
        return Math.mulDiv(annualEmission, 1, pmm.SECONDS_PER_YEAR());
    }
}
