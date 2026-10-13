// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Tenbinium} from "./Tenbinium.sol";

/**
 * @title BittenbinCoreV026
 * @author Calvin Lin
 * @notice A network of neurons that answers questions with a probability.
 *         A wallet creates a neuron at a lattice point (x, y, C) with x^2 + y^2 = C^2 by finding a nonce
 *         such that
 *
 *             H = keccak256(wallet, x, y, C, nonce)
 *
 *         begins with x, then y, then C, each written in binary without leading zeros. The neuron stays
 *         there forever, stands for the probability (x / C)^2, and mints TBN on a schedule that depends
 *         only on the number of neurons created before it.
 *         A customer asks a question for one of four durations, each with a fixed fee in TBN. Until the deadline, a wallet can
 *         store the question under any of its neurons, each of whose memory holds one question for every bit
 *         of its proof. The
 *         answer is the direction of the sum q of the vectors (x, y) that stored it, and the fee is shared
 *         among them
 *         by their contribution to the length of q.
 * @dev    This contract must be set as the Tenbinium minter. Questions are never settled.
 */
contract BittenbinCoreV026 {
    using SafeERC20 for IERC20;

    uint256 public constant BASE_REWARD = 2 ether;
    uint256 public constant BASE_NEURONS = 9_000_000;
    uint256 public constant HALVING_START = 10_000_000;
    uint256 public constant NEURONS_PER_HALVING = 2_000_000;
    uint256 public constant MAX_OPINION_LENGTH = 280;
    uint256 internal constant ONE = 1 ether;

    Tenbinium public immutable tbn;

    /// @notice Number of neurons created so far, which alone sets the reward of the next one.
    uint256 public neuronCount;
    uint256 public questionCount;

    mapping(uint256 point => Neuron) public neurons;
    mapping(uint256 point => uint256[]) internal _memory;
    mapping(uint256 questionId => Question) public questions;
    /// @notice Whether a neuron has stored a question, and whether its share of the fee has been claimed.
    mapping(uint256 questionId => mapping(uint256 point => Status)) public statusOf;

    struct Neuron {
        address wallet;
        uint64 c;
        /// @dev Bits of x, y and C together, which is the length of the proof and the size of the memory.
        uint8 bits;
    }

    struct Question {
        address customer;
        uint64 deadline;
        bool refunded;
        uint256 fee;
        uint256 qx;
        uint256 qy;
    }

    enum Status {
        None,
        Stored,
        Claimed
    }

    error InvalidAddress();
    error InvalidPoint();
    error PointUsed();
    error InvalidProof();
    error EmptyQuestion();
    error InvalidDuration();
    error NoQuestion();
    error QuestionClosed();
    error QuestionOpen();
    error NotNeuronOwner();
    error MemoryFull();
    error AlreadyStored();
    error OpinionTooLong();
    error NothingToClaim();
    error NothingToRefund();

    event NeuronCreated(address indexed wallet, uint256 x, uint256 y, uint256 c, uint256 bits, uint256 reward);
    event QuestionAsked(uint256 indexed questionId, address indexed customer, string text, uint256 fee, uint256 deadline);
    event QuestionStored(uint256 indexed questionId, address indexed wallet, uint256 x, uint256 y, uint256 c, string opinion);
    event FeeClaimed(uint256 indexed questionId, address indexed wallet, uint256 amount);
    event FeeRefunded(uint256 indexed questionId, address indexed customer, uint256 amount);

    constructor(address tbn_) {
        if (tbn_ == address(0)) revert InvalidAddress();
        tbn = Tenbinium(tbn_);
    }

    /// @notice Creates the caller's neuron at an unused lattice point, minting its reward.
    function createNeuron(uint256 x, uint256 y, uint256 c, uint128 nonce) external returns (uint256 reward) {
        (uint256 prefix, uint256 bits) = prefixOf(x, y, c);

        uint256 point = _point(x, y);
        if (neurons[point].wallet != address(0)) revert PointUsed();
        if (uint256(proofHash(msg.sender, x, y, c, nonce)) >> (256 - bits) != prefix) revert InvalidProof();

        neurons[point] = Neuron({wallet: msg.sender, c: uint64(c), bits: uint8(bits)});

        reward = rewardAt(neuronCount);
        neuronCount += 1;
        emit NeuronCreated(msg.sender, x, y, c, bits, reward);

        if (reward > 0) tbn.mint(msg.sender, reward);
    }

    /// @notice Asks a question that neurons can store for `duration` seconds, which must be one of the
    ///         four durations that `feeOf` accepts. This contract holds the fee in TBN until the
    ///         deadline, and the caller must have approved it.
    function ask(string calldata text, uint256 duration) external returns (uint256 questionId) {
        if (bytes(text).length == 0) revert EmptyQuestion();
        uint256 fee = feeOf(duration);
        uint256 deadline = block.timestamp + duration;

        questionId = ++questionCount;
        questions[questionId] =
            Question({customer: msg.sender, deadline: uint64(deadline), refunded: false, fee: fee, qx: 0, qy: 0});
        emit QuestionAsked(questionId, msg.sender, text, fee, deadline);

        IERC20(address(tbn)).safeTransferFrom(msg.sender, address(this), fee);
    }

    /// @notice Stores an open question under the caller's neuron at (x, y), with an optional opinion.
    ///         A wallet can store a question under any number of its neurons, each of them once, and a
    ///         neuron's memory holds as many questions as its proof has bits.
    function store(uint256 questionId, uint256 x, uint256 y, string calldata opinion) external {
        Question storage question = questions[questionId];
        if (question.customer == address(0)) revert NoQuestion();
        if (block.timestamp >= question.deadline) revert QuestionClosed();
        if (bytes(opinion).length > MAX_OPINION_LENGTH) revert OpinionTooLong();

        uint256 point = _point(x, y);
        Neuron storage neuron = neurons[point];
        if (neuron.wallet != msg.sender) revert NotNeuronOwner();

        uint256[] storage stored = _memory[point];
        if (stored.length >= neuron.bits) revert MemoryFull();

        if (statusOf[questionId][point] != Status.None) revert AlreadyStored();

        stored.push(questionId);
        statusOf[questionId][point] = Status.Stored;
        question.qx += x;
        question.qy += y;
        emit QuestionStored(questionId, msg.sender, x, y, neuron.c, opinion);
    }

    /// @notice Pays the caller the share of a closed question's fee that its neuron at (x, y) earned.
    function claim(uint256 questionId, uint256 x, uint256 y) external returns (uint256 amount) {
        Question storage question = questions[questionId];
        if (question.customer == address(0)) revert NoQuestion();
        if (block.timestamp < question.deadline) revert QuestionOpen();

        uint256 point = _point(x, y);
        if (neurons[point].wallet != msg.sender) revert NotNeuronOwner();
        if (statusOf[questionId][point] != Status.Stored) revert NothingToClaim();

        statusOf[questionId][point] = Status.Claimed;
        amount = shareOf(questionId, x, y);
        emit FeeClaimed(questionId, msg.sender, amount);

        if (amount > 0) IERC20(address(tbn)).safeTransfer(msg.sender, amount);
    }

    /// @notice Returns the fee of a closed question that no neuron stored to its customer.
    function refund(uint256 questionId) external returns (uint256 amount) {
        Question storage question = questions[questionId];
        if (question.customer == address(0)) revert NoQuestion();
        if (block.timestamp < question.deadline) revert QuestionOpen();
        if (question.qx != 0 || question.refunded) revert NothingToRefund();

        question.refunded = true;
        amount = question.fee;
        emit FeeRefunded(questionId, question.customer, amount);

        IERC20(address(tbn)).safeTransfer(question.customer, amount);
    }

    /// @notice The sum q of the vectors that have stored a question and its probability (q_x / ||q||)^2,
    ///         scaled by 1e18. The probability is zero while no neuron has stored it.
    function answerOf(uint256 questionId) external view returns (uint256 qx, uint256 qy, uint256 probability) {
        Question storage question = questions[questionId];
        qx = question.qx;
        qy = question.qy;
        if (qx != 0) probability = Math.mulDiv(qx * qx, ONE, qx * qx + qy * qy);
    }

    /// @notice The part of a question's fee that a neuron at (x, y) earns given what has stored it so far.
    ///         It is the neuron's contribution to the length of q as a fraction of that length, which
    ///         equals (x q_x + y q_y) / (q_x^2 + q_y^2).
    function shareOf(uint256 questionId, uint256 x, uint256 y) public view returns (uint256) {
        Question storage question = questions[questionId];
        uint256 qx = question.qx;
        uint256 qy = question.qy;
        if (qx == 0) return 0;

        return Math.mulDiv(question.fee, x * qx + y * qy, qx * qx + qy * qy);
    }

    /// @notice What a question open for `duration` seconds costs. A question stays open for one hour,
    ///         four hours, one day or seven days, for 1, 2, 5 or 13 TBN, which is approximately the
    ///         square root of the duration in hours.
    function feeOf(uint256 duration) public pure returns (uint256) {
        if (duration == 1 hours) return 1 ether;
        if (duration == 4 hours) return 2 ether;
        if (duration == 1 days) return 5 ether;
        if (duration == 7 days) return 13 ether;
        revert InvalidDuration();
    }

    function isUsed(uint256 x, uint256 y) external view returns (bool) {
        return neurons[_point(x, y)].wallet != address(0);
    }

    /// @notice The questions stored by the neuron at (x, y), in the order that it stored them.
    function memoryOf(uint256 x, uint256 y) external view returns (uint256[] memory) {
        return _memory[_point(x, y)];
    }

    /// @notice How many more questions the neuron at (x, y) can store.
    function memoryLeft(uint256 x, uint256 y) external view returns (uint256) {
        uint256 point = _point(x, y);
        return neurons[point].bits - _memory[point].length;
    }

    /// @notice Reward of the next neuron.
    function nextReward() external view returns (uint256) {
        return rewardAt(neuronCount);
    }

    /// @notice The hash that a wallet searches over.
    function proofHash(address wallet, uint256 x, uint256 y, uint256 c, uint128 nonce) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(wallet, uint64(x), uint64(y), uint64(c), nonce));
    }

    /// @notice The leading bits that a proof at (x, y, C) must have, and how many of them there are.
    ///         Reverts unless x, y and C are positive integers with x^2 + y^2 = C^2.
    function prefixOf(uint256 x, uint256 y, uint256 c) public pure returns (uint256 prefix, uint256 bits) {
        if (x == 0 || y == 0 || c > type(uint64).max) revert InvalidPoint();
        // c fits in 64 bits, so a larger x or y cannot satisfy the equation and the squares cannot overflow.
        if (x >= c || y >= c || x * x + y * y != c * c) revert InvalidPoint();

        uint256 bitsY = Math.log2(y) + 1;
        uint256 bitsC = Math.log2(c) + 1;
        prefix = (x << (bitsY + bitsC)) | (y << bitsC) | c;
        bits = Math.log2(x) + 1 + bitsY + bitsC;
    }

    /// @notice Whether the nonce is a valid proof for the wallet at (x, y, C). Use of the point is not checked.
    function isValidProof(address wallet, uint256 x, uint256 y, uint256 c, uint128 nonce) public pure returns (bool) {
        (uint256 prefix, uint256 bits) = prefixOf(x, y, c);
        return uint256(proofHash(wallet, x, y, c, nonce)) >> (256 - bits) == prefix;
    }

    /// @notice TBN reward of a neuron created after `count` earlier neurons. It is 2 TBN for each of the
    ///         first 9,000,000 neurons, which emits 18,000,000 TBN, and 1 TBN for the million after that.
    ///         From 10,000,000 neurons onwards it halves with every 2,000,000 neurons, starting at
    ///         0.5 TBN, which emits the last 2,000,000 TBN.
    function rewardAt(uint256 count) public pure returns (uint256) {
        if (count < BASE_NEURONS) return BASE_REWARD;
        if (count < HALVING_START) return BASE_REWARD / 2;

        uint256 halvings = (count - HALVING_START) / NEURONS_PER_HALVING + 2;
        return halvings < 64 ? BASE_REWARD >> halvings : 0;
    }

    /// @dev Coordinates beyond 64 bits are rejected so that no two pairs (x, y) share a key.
    function _point(uint256 x, uint256 y) internal pure returns (uint256) {
        if (x > type(uint64).max || y > type(uint64).max) revert InvalidPoint();
        return (x << 128) | y;
    }
}
