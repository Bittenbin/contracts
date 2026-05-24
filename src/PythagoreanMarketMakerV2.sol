// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Tenbinium} from "./Tenbinium.sol";

/**
 * @title PythagoreanMarketMakerV2
 * @author Calvin Lin
 * @notice Fresh v2 implementation of the whitepaper PMM, proof-of-proximity, and TBN reward mechanics.
 */
contract PythagoreanMarketMakerV2 is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant PROTOCOL_FEE_BASIS_POINTS = 100;
    uint256 public constant BASIS_POINTS_DENOMINATOR = 10_000;
    uint256 public constant MAX_COORDINATE_VALUE = 1e9;
    uint256 public constant MAX_HYPOTENUSE = 1.5e9;
    uint256 public constant TBN_BURN_FEE = 1 ether;
    uint256 public constant FEE_REDEMPTION_TBN_BURN = 100 ether;
    uint256 public constant REWARD_PRECISION = 1e18;
    uint256 public constant YEAR = 365 days;
    uint256 public constant INITIAL_EMISSION_YEARS = 20;
    uint256 public constant INITIAL_ANNUAL_EMISSION = 1_000_000 ether;
    uint256 public constant POST_INITIAL_ANNUAL_EMISSION = 500_000 ether;
    uint256 public constant MAX_TBN_EMISSION = 21_000_000 ether;

    IERC20 public immutable paymentToken;
    Tenbinium public immutable tbn;
    uint256 public immutable paymentTokenUnit;

    uint256 public accumulatedProtocolFees;
    uint256 public totalStakedValue;
    uint256 public nMax;

    uint256 public totalPower;
    uint256 public rewardPerPowerStored;
    uint256 public lastRewardTime;
    uint256 public emissionStartTime;
    uint256 public totalTbnEmitted;

    mapping(bytes32 => AgentLocation) public agentLocations;
    mapping(bytes32 => bool) public agentExists;
    mapping(bytes32 => bytes32) public coordinateToAgent;
    mapping(bytes32 => bool) public coordinateOccupied;
    mapping(bytes32 => bool) public usedPuzzleDestinations;
    mapping(bytes32 => address) public agentCreator;

    mapping(bytes32 => mapping(address => Exposure)) public exposures;
    mapping(address => SolverRewards) public solverRewards;

    struct AgentLocation {
        uint256 x;
        uint256 y;
        uint256 c;
    }

    struct Exposure {
        uint256 x;
        uint256 y;
        bool exists;
    }

    struct SolverRewards {
        uint256 power;
        uint256 rewardPerPowerPaid;
        uint256 unclaimed;
    }

    error InvalidAddress();
    error InvalidAgentId();
    error AgentAlreadyExists();
    error AgentDoesNotExist();
    error CoordinateOccupied();
    error InvalidPythagoreanCoordinate();
    error CoordinateTooLarge();
    error HypotenuseTooLarge();
    error InsufficientExposure();
    error PaymentFailed();
    error RefundFailed();
    error InvalidProofDelta();
    error InvalidProofTVL();
    error PuzzleDestinationAlreadyUsed();
    error NoRewardsToClaim();
    error InvalidFeeAmount();
    error PotentialOverflow();
    error InvalidPrimaryId();
    error StaleLocation(uint256 actualX, uint256 actualY);

    event AgentCreated(bytes32 indexed agentId, string primaryId, address indexed creator, uint256 x, uint256 y, uint256 c);
    event AgentRelocated(
        bytes32 indexed agentId,
        address indexed participant,
        uint256 fromX,
        uint256 fromY,
        uint256 toX,
        uint256 toY,
        int256 deltaC
    );
    event ExposureUpdated(bytes32 indexed agentId, address indexed participant, uint256 xExposure, uint256 yExposure);
    event ProofOfProximitySolved(
        address indexed solver,
        bytes32 indexed agentId,
        uint256 x,
        uint256 y,
        uint256 deltaC,
        uint256 n,
        uint256 newTVL,
        uint256 nMax
    );
    event SolverPowerUpdated(address indexed solver, uint256 power, uint256 totalPower);
    event TbnClaimed(address indexed solver, uint256 amount);
    event TbnBurnedForUsedDestination(address indexed payer, bytes32 indexed destinationHash, uint256 amount);
    event FeeVaultRedeemed(address indexed redeemer, uint256 tbnBurned, uint256 usdcRedeemed);

    constructor(
        address paymentToken_,
        address tbn_,
        address initialOwner_
    ) Ownable(initialOwner_) {
        if (
            paymentToken_ == address(0) ||
            tbn_ == address(0) ||
            initialOwner_ == address(0)
        ) {
            revert InvalidAddress();
        }

        paymentToken = IERC20(paymentToken_);
        tbn = Tenbinium(tbn_);
        paymentTokenUnit = 10 ** IERC20Metadata(paymentToken_).decimals();
    }

    function createAgent(string calldata primaryId, uint256 x, uint256 y) external nonReentrant {
        if (bytes(primaryId).length == 0) revert InvalidPrimaryId();
        _createAgent(keccak256(bytes(primaryId)), primaryId, x, y);
    }

    function relocateAgent(
        bytes32 agentId,
        uint256 currentX,
        uint256 currentY,
        uint256 newX,
        uint256 newY
    ) external nonReentrant {
        _relocateAgent(agentId, currentX, currentY, newX, newY);
    }

    function claimTBN() external nonReentrant returns (uint256 amount) {
        _settleSolver(msg.sender);
        amount = solverRewards[msg.sender].unclaimed;
        if (amount == 0) revert NoRewardsToClaim();

        solverRewards[msg.sender].unclaimed = 0;
        tbn.mint(msg.sender, amount);
        emit TbnClaimed(msg.sender, amount);
    }

    function getAgentState(bytes32 agentId) external view returns (uint256 x, uint256 y, uint256 c, bool exists) {
        AgentLocation memory location = agentLocations[agentId];
        return (location.x, location.y, location.c, agentExists[agentId]);
    }

    function getExposure(bytes32 agentId, address participant) external view returns (uint256 xExposure, uint256 yExposure, bool exists) {
        Exposure memory exposure = exposures[agentId][participant];
        return (exposure.x, exposure.y, exposure.exists);
    }

    function pendingTBN(address solver) external view returns (uint256) {
        SolverRewards memory rewards = solverRewards[solver];
        uint256 accumulator = rewardPerPowerStored;
        uint256 emitted = _emissionBetween(lastRewardTime, block.timestamp);

        if (totalPower > 0 && emitted > 0) {
            accumulator += (emitted * REWARD_PRECISION) / totalPower;
        }

        return rewards.unclaimed + ((rewards.power * (accumulator - rewards.rewardPerPowerPaid)) / REWARD_PRECISION);
    }

    function areConnected(bytes32 agentA, bytes32 agentB) external view returns (bool) {
        if (!agentExists[agentA] || !agentExists[agentB] || nMax == 0) return false;

        AgentLocation memory a = agentLocations[agentA];
        AgentLocation memory b = agentLocations[agentB];
        uint256 dx = a.x > b.x ? a.x - b.x : b.x - a.x;
        uint256 dy = a.y > b.y ? a.y - b.y : b.y - a.y;
        return (dx * dx) + (dy * dy) <= nMax * nMax;
    }

    function isValidCoordinate(uint256 x, uint256 y) public pure returns (bool) {
        if (x == 0 || y == 0 || x > MAX_COORDINATE_VALUE || y > MAX_COORDINATE_VALUE) return false;

        uint256 sumSquares = _safeAdd(_safeMul(x, x), _safeMul(y, y));
        uint256 c = Math.sqrt(sumSquares);
        return c <= MAX_HYPOTENUSE && c * c == sumSquares;
    }

    function destinationHash(uint256 x, uint256 y, uint256 c) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(x, y, c));
    }

    function coordinateHash(uint256 x, uint256 y) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(x, y));
    }

    function redeemFeeVault() external nonReentrant returns (uint256 usdcRedeemed) {
        usdcRedeemed = accumulatedProtocolFees;
        if (usdcRedeemed == 0) revert InvalidFeeAmount();

        accumulatedProtocolFees = 0;

        ERC20Burnable(address(tbn)).burnFrom(msg.sender, FEE_REDEMPTION_TBN_BURN);
        paymentToken.safeTransfer(msg.sender, usdcRedeemed);
        emit FeeVaultRedeemed(msg.sender, FEE_REDEMPTION_TBN_BURN, usdcRedeemed);
    }

    function _createAgent(bytes32 agentId, string calldata primaryId, uint256 x, uint256 y) internal {
        if (agentId == bytes32(0)) revert InvalidAgentId();
        if (agentExists[agentId]) revert AgentAlreadyExists();

        uint256 c = _validateAndGetHypotenuse(x, y);
        bytes32 coordHash = coordinateHash(x, y);
        if (coordinateOccupied[coordHash]) revert CoordinateOccupied();

        bytes32 destHash = destinationHash(x, y, c);
        _chargeUsedDestinationBurn(destHash);

        _collectPayment(c);
        totalStakedValue += c;

        agentLocations[agentId] = AgentLocation({x: x, y: y, c: c});
        agentExists[agentId] = true;
        coordinateOccupied[coordHash] = true;
        coordinateToAgent[coordHash] = agentId;
        agentCreator[agentId] = msg.sender;
        exposures[agentId][msg.sender] = Exposure({x: x, y: y, exists: true});

        _maybeSolveProof(agentId, x, y, c, c);

        emit AgentCreated(agentId, primaryId, msg.sender, x, y, c);
        emit ExposureUpdated(agentId, msg.sender, x, y);
    }

    function _relocateAgent(bytes32 agentId, uint256 currentX, uint256 currentY, uint256 newX, uint256 newY) internal {
        if (!agentExists[agentId]) revert AgentDoesNotExist();

        AgentLocation memory current = agentLocations[agentId];
        if (current.x != currentX || current.y != currentY) revert StaleLocation(current.x, current.y);

        uint256 newC = _validateAndGetHypotenuse(newX, newY);
        bytes32 newCoordHash = coordinateHash(newX, newY);
        bytes32 currentCoordHash = coordinateHash(current.x, current.y);

        if (newCoordHash != currentCoordHash && coordinateOccupied[newCoordHash]) revert CoordinateOccupied();

        int256 deltaC = int256(newC) - int256(current.c);
        int256 deltaX = int256(newX) - int256(current.x);
        int256 deltaY = int256(newY) - int256(current.y);

        Exposure storage exposure = exposures[agentId][msg.sender];
        _applyExposureDelta(exposure, deltaX, deltaY);

        bytes32 destHash = destinationHash(newX, newY, newC);
        _chargeUsedDestinationBurn(destHash);

        if (deltaC > 0) {
            _collectPayment(uint256(deltaC));
            totalStakedValue += uint256(deltaC);
        } else if (deltaC < 0) {
            uint256 decrease = uint256(-deltaC);
            _refundPayment(decrease);
            totalStakedValue -= decrease;
            _reducePowerForNegativeDelta(msg.sender, decrease);
        }

        if (newCoordHash != currentCoordHash) {
            delete coordinateOccupied[currentCoordHash];
            delete coordinateToAgent[currentCoordHash];
            coordinateOccupied[newCoordHash] = true;
            coordinateToAgent[newCoordHash] = agentId;
        }

        agentLocations[agentId] = AgentLocation({x: newX, y: newY, c: newC});

        if (deltaC > 0) {
            _maybeSolveProof(agentId, newX, newY, uint256(deltaC), newC);
        }

        emit AgentRelocated(agentId, msg.sender, current.x, current.y, newX, newY, deltaC);
        emit ExposureUpdated(agentId, msg.sender, exposure.x, exposure.y);
    }

    function _maybeSolveProof(bytes32 agentId, uint256 x, uint256 y, uint256 deltaC, uint256 c) internal returns (bool solved) {
        if (deltaC == 0) return false;

        uint256 n = Math.sqrt(deltaC);
        if (n == 0 || n * n != deltaC) return false;

        uint256 m = Math.sqrt(totalStakedValue);
        if (m == 0 || m * m != totalStakedValue) return false;

        bytes32 destHash = destinationHash(x, y, c);
        if (usedPuzzleDestinations[destHash]) return false;

        usedPuzzleDestinations[destHash] = true;
        if (n > nMax) nMax = n;
        _increasePower(msg.sender, deltaC);

        emit ProofOfProximitySolved(msg.sender, agentId, x, y, deltaC, n, totalStakedValue, nMax);
        return true;
    }

    function _collectPayment(uint256 valueDelta) internal returns (uint256 totalPayment) {
        uint256 payment = _toPaymentUnits(valueDelta);
        uint256 fee = (payment * PROTOCOL_FEE_BASIS_POINTS) / BASIS_POINTS_DENOMINATOR;
        totalPayment = payment + fee;
        accumulatedProtocolFees += fee;
        paymentToken.safeTransferFrom(msg.sender, address(this), totalPayment);
    }

    function _refundPayment(uint256 valueDelta) internal returns (uint256 netRefund) {
        uint256 refund = _toPaymentUnits(valueDelta);
        uint256 fee = (refund * PROTOCOL_FEE_BASIS_POINTS) / BASIS_POINTS_DENOMINATOR;
        netRefund = refund - fee;
        accumulatedProtocolFees += fee;
        paymentToken.safeTransfer(msg.sender, netRefund);
    }

    function _chargeUsedDestinationBurn(bytes32 destHash) internal {
        if (!usedPuzzleDestinations[destHash]) return;
        ERC20Burnable(address(tbn)).burnFrom(msg.sender, TBN_BURN_FEE);
        emit TbnBurnedForUsedDestination(msg.sender, destHash, TBN_BURN_FEE);
    }

    function _increasePower(address solver, uint256 amount) internal {
        _settleSolver(solver);

        if (emissionStartTime == 0) {
            emissionStartTime = block.timestamp;
            lastRewardTime = block.timestamp;
        }

        solverRewards[solver].power += amount;
        totalPower += amount;
        emit SolverPowerUpdated(solver, solverRewards[solver].power, totalPower);
    }

    function _reducePowerForNegativeDelta(address solver, uint256 amount) internal {
        SolverRewards storage rewards = solverRewards[solver];
        if (rewards.power == 0) return;

        _settleSolver(solver);
        uint256 reduction = amount > rewards.power ? rewards.power : amount;
        rewards.power -= reduction;
        totalPower -= reduction;
        emit SolverPowerUpdated(solver, rewards.power, totalPower);
    }

    function _settleSolver(address solver) internal {
        _updateGlobalAccumulator();

        SolverRewards storage rewards = solverRewards[solver];
        if (rewards.power > 0) {
            rewards.unclaimed += (rewards.power * (rewardPerPowerStored - rewards.rewardPerPowerPaid)) / REWARD_PRECISION;
        }
        rewards.rewardPerPowerPaid = rewardPerPowerStored;
    }

    function _updateGlobalAccumulator() internal {
        if (lastRewardTime == 0) {
            lastRewardTime = block.timestamp;
            return;
        }

        uint256 emitted = _emissionBetween(lastRewardTime, block.timestamp);
        lastRewardTime = block.timestamp;

        if (totalPower == 0 || emitted == 0) return;

        uint256 remainingEmission = MAX_TBN_EMISSION - totalTbnEmitted;
        if (emitted > remainingEmission) emitted = remainingEmission;
        totalTbnEmitted += emitted;
        rewardPerPowerStored += (emitted * REWARD_PRECISION) / totalPower;
    }

    function _emissionBetween(uint256 from, uint256 to) internal view returns (uint256 emitted) {
        if (emissionStartTime == 0 || to <= from || from < emissionStartTime) return 0;

        uint256 initialEnd = emissionStartTime + (INITIAL_EMISSION_YEARS * YEAR);
        if (from < initialEnd) {
            uint256 segmentEnd = to < initialEnd ? to : initialEnd;
            emitted += ((segmentEnd - from) * INITIAL_ANNUAL_EMISSION) / YEAR;
            from = segmentEnd;
        }

        while (from < to) {
            uint256 yearsAfterInitial = (from - initialEnd) / YEAR;
            uint256 yearEnd = initialEnd + ((yearsAfterInitial + 1) * YEAR);
            uint256 segmentEnd = to < yearEnd ? to : yearEnd;
            uint256 annualEmission = POST_INITIAL_ANNUAL_EMISSION >> yearsAfterInitial;
            if (annualEmission == 0) break;
            emitted += ((segmentEnd - from) * annualEmission) / YEAR;
            from = segmentEnd;
        }

        uint256 remainingEmission = MAX_TBN_EMISSION - totalTbnEmitted;
        if (emitted > remainingEmission) emitted = remainingEmission;
    }

    function _applyExposureDelta(Exposure storage exposure, int256 deltaX, int256 deltaY) internal {
        if (deltaX < 0) {
            uint256 reduction = uint256(-deltaX);
            if (exposure.x < reduction) revert InsufficientExposure();
            exposure.x -= reduction;
        } else if (deltaX > 0) {
            exposure.x += uint256(deltaX);
        }

        if (deltaY < 0) {
            uint256 reduction = uint256(-deltaY);
            if (exposure.y < reduction) revert InsufficientExposure();
            exposure.y -= reduction;
        } else if (deltaY > 0) {
            exposure.y += uint256(deltaY);
        }

        exposure.exists = true;
    }

    function _validateAndGetHypotenuse(uint256 x, uint256 y) internal pure returns (uint256 c) {
        if (x == 0 || y == 0) revert InvalidPythagoreanCoordinate();
        if (x > MAX_COORDINATE_VALUE || y > MAX_COORDINATE_VALUE) revert CoordinateTooLarge();

        uint256 sumSquares = _safeAdd(_safeMul(x, x), _safeMul(y, y));
        c = Math.sqrt(sumSquares);

        if (c > MAX_HYPOTENUSE) revert HypotenuseTooLarge();
        if (c * c != sumSquares) revert InvalidPythagoreanCoordinate();
    }

    function _toPaymentUnits(uint256 value) internal view returns (uint256 amount) {
        amount = value * paymentTokenUnit;
        if (amount / paymentTokenUnit != value) revert PotentialOverflow();
    }

    function _safeMul(uint256 a, uint256 b) internal pure returns (uint256 result) {
        if (a == 0) return 0;
        result = a * b;
        if (result / a != b) revert PotentialOverflow();
    }

    function _safeAdd(uint256 a, uint256 b) internal pure returns (uint256 result) {
        result = a + b;
        if (result < a) revert PotentialOverflow();
    }
}
