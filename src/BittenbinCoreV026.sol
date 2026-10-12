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
 *         A customer asks a question with a fee in TBN and a deadline. Until the deadline, a wallet can
 *         store the question under any of its neurons, each of whose memory holds at most C questions. The
 *         answer is the direction of the sum q of the vectors (x, y) that stored it, and the fee is shared
 *         among them
 *         by their contribution to the length of q.
 * @dev    This contract must be set as the Tenbinium minter. Questions are never settled.
 */
contract BittenbinCoreV026 {
    using SafeERC20 for IERC20;

    uint256 public constant NEURONS_PER_ERA = 100_000;
    uint256 public constant RAMP_ERAS = 13;
    uint256 public constant NEURONS_PER_HALVING = 50_000;
    uint256 public constant MIN_WINDOW = 1 hours;
    uint256 public constant BASE_RATE = 1 ether;
    uint256 public constant QUESTIONS_PER_HALVING = 1_000_000;
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
    error WindowTooShort();
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

        neurons[point] = Neuron({wallet: msg.sender, c: uint64(c)});

        reward = rewardAt(neuronCount);
        neuronCount += 1;
        emit NeuronCreated(msg.sender, x, y, c, bits, reward);

        if (reward > 0) tbn.mint(msg.sender, reward);
    }

    /// @notice Asks a question that neurons can store until the deadline, which must be at least an hour
    ///         away and sets the fee, for a fee in TBN that this
    ///         contract holds until then. The caller must have approved the fee.
    function ask(string calldata text, uint256 deadline) external returns (uint256 questionId) {
        if (bytes(text).length == 0) revert EmptyQuestion();
        if (deadline < block.timestamp + MIN_WINDOW || deadline > type(uint64).max) revert WindowTooShort();
        uint256 fee = feeAt(questionCount, deadline - block.timestamp);

        questionId = ++questionCount;
        questions[questionId] =
            Question({customer: msg.sender, deadline: uint64(deadline), refunded: false, fee: fee, qx: 0, qy: 0});
        emit QuestionAsked(questionId, msg.sender, text, fee, deadline);

        IERC20(address(tbn)).safeTransferFrom(msg.sender, address(this), fee);
    }

    /// @notice Stores an open question under the caller's neuron at (x, y), with an optional opinion.
    ///         A wallet can store a question under any number of its neurons, each of them once, and a
    ///         neuron's memory holds at most C questions.
    function store(uint256 questionId, uint256 x, uint256 y, string calldata opinion) external {
        Question storage question = questions[questionId];
        if (question.customer == address(0)) revert NoQuestion();
        if (block.timestamp >= question.deadline) revert QuestionClosed();
        if (bytes(opinion).length > MAX_OPINION_LENGTH) revert OpinionTooLong();

        uint256 point = _point(x, y);
        Neuron storage neuron = neurons[point];
        if (neuron.wallet != msg.sender) revert NotNeuronOwner();

        uint256[] storage stored = _memory[point];
        if (stored.length >= neuron.c) revert MemoryFull();

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

    /// @notice What a question open for `duration` seconds costs right now.
    function feeOf(uint256 duration) external view returns (uint256) {
        return feeAt(questionCount, duration);
    }

    /// @notice What a question open for `duration` seconds costs after `count` earlier questions.
    ///         It is the rate times the square root of the duration in hours, so one hour costs the
    ///         rate, four hours twice the rate and nine hours three times the rate.
    function feeAt(uint256 count, uint256 duration) public pure returns (uint256) {
        return Math.mulDiv(rateAt(count), Math.sqrt(duration * 1e36 / 1 hours), ONE);
    }

    /// @notice The fee of a one-hour question after `count` earlier questions. It starts at
    ///         1 TBN and halves with every million questions.
    function rateAt(uint256 count) public pure returns (uint256) {
        uint256 halvings = count / QUESTIONS_PER_HALVING;
        return halvings < 64 ? BASE_RATE >> halvings : 0;
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
        return neurons[point].c - _memory[point].length;
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

    /// @notice TBN reward of a neuron created after `count` earlier neurons. Per 100,000 neurons, it is
    ///         1, 4, 9 and 16 TBN, holds at 25 TBN for six eras, and falls back through 16, 9 and 4 TBN,
    ///         which emits 20,900,000 TBN over 1,300,000 neurons. It then drops to 1 TBN and halves with
    ///         every 50,000 neurons, which emits the last 100,000 TBN.
    function rewardAt(uint256 count) public pure returns (uint256) {
        uint256 era = count / NEURONS_PER_ERA;

        if (era < 5) return (era + 1) * (era + 1) * ONE;
        if (era < 10) return 25 * ONE;
        if (era < RAMP_ERAS) return (14 - era) * (14 - era) * ONE;

        uint256 halvings = (count - RAMP_ERAS * NEURONS_PER_ERA) / NEURONS_PER_HALVING;
        return halvings < 64 ? ONE >> halvings : 0;
    }

    function _point(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x << 128) | y;
    }
}
