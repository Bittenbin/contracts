// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PythagoreanMarketMaker} from "../src/PythagoreanMarketMaker.sol";
import {TenbinToken} from "../src/tokens/TenbinToken.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

interface Vm {
    function startPrank(address sender) external;
    function stopPrank() external;
    function expectRevert() external;
    function expectRevert(bytes calldata) external;
    function warp(uint256) external;
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

contract SecurityTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    PythagoreanMarketMaker private pmm;
    MockUSDC private usdc;
    TenbinToken private tenbin;

    address private owner = address(0xABCD);
    address private attacker = address(0xBAD);
    address private alice = address(0xA11CE);
    address private bob = address(0xB0B);

    function setUp() public {
        vm.startPrank(owner);
        usdc = new MockUSDC();
        tenbin = new TenbinToken(owner);
        pmm = _deployPmmProxy(address(usdc), address(tenbin));
        tenbin.setMinter(address(pmm));
        vm.stopPrank();

        _fundAndApprove(alice, 1_000_000 * 1e6);
        _fundAndApprove(bob, 1_000_000 * 1e6);
        _fundAndApprove(attacker, 1_000_000 * 1e6);
    }

    function testReentrancyGuardPathsDoNotRevert() public {
        string memory url = "https://reentrancy.test";
        vm.startPrank(alice);
        pmm.createMarket(url, 3, 4);
        vm.stopPrank();

        bytes32 urlHash = keccak256(bytes(url));
        uint256 pageId = uint256(urlHash);

        vm.startPrank(bob);
        pmm.voteOnMarket(pageId, 3, 10);
        vm.stopPrank();

        vm.startPrank(bob);
        vm.warp(block.timestamp + 30 days);
        pmm.claimRewards();
        vm.stopPrank();
    }

    function testSlippageCalculationIsBounded() public view {
        (uint256 expectedPayment, uint256 maxPayment) = pmm.calculatePaymentWithSlippage(3, 4, 3, 10, 100);
        _assertTrue(maxPayment >= expectedPayment);
    }

    function testSellingWithoutVotesReverts() public {
        string memory url = "https://sell.test";
        vm.startPrank(alice);
        pmm.createMarket(url, 3, 4);
        vm.stopPrank();

        uint256 pageId = uint256(keccak256(bytes(url)));

        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSelector(PythagoreanMarketMaker.InsufficientVotesToSell.selector));
        pmm.voteOnMarket(pageId, 3, 3);
        vm.stopPrank();
    }

    function testNoOpAndDiagonalMovesRevert() public {
        string memory url = "https://diagonal.test";
        vm.startPrank(alice);
        pmm.createMarket(url, 3, 4);
        vm.stopPrank();

        uint256 pageId = uint256(keccak256(bytes(url)));

        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(PythagoreanMarketMaker.InvalidCoordinate.selector));
        pmm.voteOnMarket(pageId, 3, 4);
        vm.stopPrank();

        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(PythagoreanMarketMaker.InvalidCoordinate.selector));
        pmm.voteOnMarket(pageId, 5, 12);
        vm.stopPrank();
    }

    function testUnauthorizedFeeExtractionReverts() public {
        string memory url = "https://fees.test";
        vm.startPrank(alice);
        pmm.createMarket(url, 3, 4);
        vm.stopPrank();

        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        pmm.distributeProtocolFees(0);
        vm.stopPrank();
    }

    function testApprovalLimitsTransfers() public {
        string memory url = "https://approval.test";

        vm.startPrank(alice);
        usdc.approve(address(pmm), 1 * 1e6);
        vm.expectRevert();
        pmm.createMarket(url, 3, 4);
        vm.stopPrank();
    }

    function testTenbinAccessControl() public {
        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSelector(TenbinToken.NotMinter.selector));
        tenbin.mint(attacker, 1_000_000);
        vm.stopPrank();

        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSelector(TenbinToken.NotBurner.selector));
        tenbin.burn(attacker, 500_000);
        vm.stopPrank();

        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        tenbin.setMinter(attacker);
        vm.stopPrank();
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

    function _assertTrue(bool value) private pure {
        require(value, "assertTrue failed");
    }
}
