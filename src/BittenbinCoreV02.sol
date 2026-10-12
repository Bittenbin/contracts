// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Tenbinium} from "./Tenbinium.sol";

/**
 * @title BittenbinCoreV02
 * @author Calvin Lin
 * @notice Birth, relocation and mining under the Pythagorean cost function C(x, y) = sqrt(x^2 + y^2).
 *         Every relocation, including birth from the origin, costs a USDC fare of |C' - C| that is paid
 *         to the treasury and never returned. A self-relocation from C = m^2 by n^2 onto a deposit that
 *         has never been mined is a solution and mints n TBN, halving after 20,000,000 units of n.
 * @dev    This contract must be set as the Tenbinium minter.
 */
contract BittenbinCoreV02 {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_COORDINATE = 1e9;
    uint256 public constant INITIAL_EMISSION_N = 20_000_000;
    uint256 public constant HALVING_INTERVAL_N = 1_000_000;

    IERC20 public immutable usdc;
    Tenbinium public immutable tbn;
    address public immutable treasury;
    uint256 public immutable usdcUnit;

    uint256 public totalNMined;

    mapping(bytes32 agentId => Agent) public agents;
    mapping(address wallet => bytes32 agentId) public agentOf;
    mapping(uint256 spot => bytes32 agentId) internal _occupant;
    mapping(uint256 spot => bool) internal _mined;

    struct Agent {
        uint64 x;
        uint64 y;
        uint64 c;
        uint64 lifetimeN;
    }

    error InvalidAddress();
    error EmptyName();
    error NameTaken();
    error WalletHasAgent();
    error NoAgent();
    error InvalidSpot();
    error SpotOccupied();
    error SameSpot();
    error NotASolution();

    event AgentBorn(bytes32 indexed agentId, address indexed wallet, string name, uint256 x, uint256 y, uint256 c);
    event AgentRelocated(bytes32 indexed agentId, uint256 fromX, uint256 fromY, uint256 toX, uint256 toY, uint256 fare);
    event DepositMined(bytes32 indexed agentId, uint256 x, uint256 y, uint256 m, uint256 n, uint256 tbnMinted);

    constructor(address usdc_, address tbn_, address treasury_) {
        if (usdc_ == address(0) || tbn_ == address(0) || treasury_ == address(0)) revert InvalidAddress();
        usdc = IERC20(usdc_);
        tbn = Tenbinium(tbn_);
        treasury = treasury_;
        usdcUnit = 10 ** IERC20Metadata(usdc_).decimals();
    }

    /// @notice Gives birth to the caller's only agent at an unoccupied spot, for a fare of C.
    function createAgent(string calldata name, uint256 x, uint256 y) external returns (bytes32 agentId) {
        if (bytes(name).length == 0) revert EmptyName();
        if (agentOf[msg.sender] != bytes32(0)) revert WalletHasAgent();

        agentId = keccak256(bytes(name));
        if (agents[agentId].c != 0) revert NameTaken();

        uint256 c = hypotenuse(x, y);
        uint256 spot = _spot(x, y);
        if (_occupant[spot] != bytes32(0)) revert SpotOccupied();

        agents[agentId] = Agent({x: uint64(x), y: uint64(y), c: uint64(c), lifetimeN: 0});
        agentOf[msg.sender] = agentId;
        _occupant[spot] = agentId;

        emit AgentBorn(agentId, msg.sender, name, x, y, c);
        _collectFare(c);
    }

    /// @notice Relocates the caller's agent for a fare of |C' - C|, minting TBN if the move is a solution.
    function relocate(uint256 x, uint256 y) external returns (uint256 fare, uint256 tbnMinted) {
        return _relocate(x, y, false);
    }

    /// @notice Same as relocate, but reverts unless the move is a solution.
    function mine(uint256 x, uint256 y) external returns (uint256 fare, uint256 tbnMinted) {
        return _relocate(x, y, true);
    }

    /// @notice Fare and solution depth n (0 if not a solution) for the wallet's agent to move to (x, y).
    ///         For a wallet without an agent, the fare is the cost of birth. Occupancy is not checked.
    function quote(address wallet, uint256 x, uint256 y) external view returns (uint256 fare, uint256 n, uint256 tbnMinted) {
        uint256 c = hypotenuse(x, y);
        bytes32 agentId = agentOf[wallet];
        if (agentId == bytes32(0)) return (c, 0, 0);

        uint256 fromC = agents[agentId].c;
        fare = _distance(fromC, c);
        n = _solutionDepth(fromC, c, _spot(x, y));
        tbnMinted = emissionFor(totalNMined, n);
    }

    function occupantOf(uint256 x, uint256 y) external view returns (bytes32) {
        return _occupant[_spot(x, y)];
    }

    function isMined(uint256 x, uint256 y) external view returns (bool) {
        return _mined[_spot(x, y)];
    }

    /// @notice C of a valid spot, where x, y and C are all positive integers. Reverts otherwise.
    function hypotenuse(uint256 x, uint256 y) public pure returns (uint256 c) {
        if (x == 0 || y == 0 || x > MAX_COORDINATE || y > MAX_COORDINATE) revert InvalidSpot();
        uint256 sumSquares = x * x + y * y;
        c = Math.sqrt(sumSquares);
        if (c * c != sumSquares) revert InvalidSpot();
    }

    /// @notice TBN minted for n further units of depth after totalBefore units have been mined:
    ///         1 TBN per unit for the first 20,000,000, then halving every 1,000,000.
    function emissionFor(uint256 totalBefore, uint256 n) public pure returns (uint256 amount) {
        uint256 from = totalBefore;
        uint256 to = totalBefore + n;

        while (from < to) {
            uint256 era = from < INITIAL_EMISSION_N ? 0 : (from - INITIAL_EMISSION_N) / HALVING_INTERVAL_N + 1;
            uint256 rate = 1 ether >> era;
            if (rate == 0) break;

            uint256 eraEnd = INITIAL_EMISSION_N + era * HALVING_INTERVAL_N;
            uint256 end = to < eraEnd ? to : eraEnd;
            amount += (end - from) * rate;
            from = end;
        }
    }

    function _relocate(uint256 x, uint256 y, bool requireSolution) internal returns (uint256 fare, uint256 tbnMinted) {
        bytes32 agentId = agentOf[msg.sender];
        if (agentId == bytes32(0)) revert NoAgent();

        Agent storage agent = agents[agentId];
        uint256 fromX = agent.x;
        uint256 fromY = agent.y;
        uint256 fromC = agent.c;

        uint256 c = hypotenuse(x, y);
        uint256 fromSpot = _spot(fromX, fromY);
        uint256 toSpot = _spot(x, y);
        if (toSpot == fromSpot) revert SameSpot();
        if (_occupant[toSpot] != bytes32(0)) revert SpotOccupied();

        uint256 n = _solutionDepth(fromC, c, toSpot);
        if (requireSolution && n == 0) revert NotASolution();
        fare = _distance(fromC, c);

        delete _occupant[fromSpot];
        _occupant[toSpot] = agentId;
        agent.x = uint64(x);
        agent.y = uint64(y);
        agent.c = uint64(c);
        emit AgentRelocated(agentId, fromX, fromY, x, y, fare);

        if (n > 0) {
            _mined[toSpot] = true;
            agent.lifetimeN += uint64(n);
            tbnMinted = emissionFor(totalNMined, n);
            totalNMined += n;
            emit DepositMined(agentId, x, y, Math.sqrt(fromC), n, tbnMinted);
        }

        _collectFare(fare);
        if (tbnMinted > 0) tbn.mint(msg.sender, tbnMinted);
    }

    /// @dev n if moving from fromC to an unmined spot at toC is a solution (fromC = m^2, toC - fromC = n^2), else 0.
    function _solutionDepth(uint256 fromC, uint256 toC, uint256 toSpot) internal view returns (uint256) {
        if (toC <= fromC || _mined[toSpot]) return 0;

        uint256 m = Math.sqrt(fromC);
        if (m * m != fromC) return 0;

        uint256 delta = toC - fromC;
        uint256 n = Math.sqrt(delta);
        return n * n == delta ? n : 0;
    }

    function _collectFare(uint256 fare) internal {
        if (fare > 0) usdc.safeTransferFrom(msg.sender, treasury, fare * usdcUnit);
    }

    function _distance(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    function _spot(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x << 128) | y;
    }
}
