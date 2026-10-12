// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Tenbinium} from "./Tenbinium.sol";

/**
 * @title BittenbinCoreV025
 * @author Calvin Lin
 * @notice Opinions on probabilistic events, broadcast through a Pythagorean proof-of-work.
 *         A wallet chooses a lattice point (x, y, C) with x^2 + y^2 = C^2, which states the probability
 *         P(E) = (x / C)^2, and finds a nonce such that
 *
 *             H = keccak256(wallet, eventId, fingerprint, x, y, C, nonce)
 *
 *         begins with x, then y, then C, each written in binary without leading zeros. Each lattice point
 *         can be used once. Every accepted proof mints TBN on a schedule that depends only on the number
 *         of proofs accepted before it, and updating an opinion costs |P' - P| TBN.
 * @dev    This contract must be set as the Tenbinium minter. eventId is keccak256 of the event description
 *         and fingerprint is keccak256 of the intelligence behind the opinion, so the proof preimage is
 *         124 bytes and fits in a single keccak block.
 */
contract BittenbinCoreV025 {
    uint256 public constant PROOFS_PER_ERA = 1_000_000;
    uint256 internal constant ONE = 1 ether;

    Tenbinium public immutable tbn;

    /// @notice Number of proofs accepted so far, which alone sets the reward of the next one.
    uint256 public proofCount;

    mapping(bytes32 opinionId => Opinion) public opinions;
    mapping(bytes32 opinionId => mapping(uint256 version => bytes32)) public fingerprintOf;
    mapping(uint256 point => bool) internal _used;

    struct Opinion {
        address wallet;
        uint32 version;
        uint16 bits;
        uint64 x;
        uint64 y;
        uint64 c;
        bytes32 eventId;
    }

    error InvalidAddress();
    error EmptyDescription();
    error EmptyFingerprint();
    error InvalidPoint();
    error PointUsed();
    error InvalidProof();
    error OpinionExists();
    error NoOpinion();
    error WeakerProof();

    event OpinionBroadcast(
        bytes32 indexed opinionId,
        address indexed wallet,
        bytes32 indexed eventId,
        string description,
        bytes32 fingerprint,
        uint256 x,
        uint256 y,
        uint256 c,
        uint256 bits,
        uint256 reward
    );
    event OpinionUpdated(
        bytes32 indexed opinionId,
        uint256 version,
        bytes32 fingerprint,
        uint256 x,
        uint256 y,
        uint256 c,
        uint256 bits,
        uint256 reward,
        uint256 fee
    );

    constructor(address tbn_) {
        if (tbn_ == address(0)) revert InvalidAddress();
        tbn = Tenbinium(tbn_);
    }

    /// @notice Broadcasts the caller's opinion on an event at an unused lattice point, minting its reward.
    function broadcast(string calldata description, bytes32 fingerprint, uint256 x, uint256 y, uint256 c, uint128 nonce)
        external
        returns (bytes32 opinionId, uint256 reward)
    {
        if (bytes(description).length == 0) revert EmptyDescription();

        bytes32 eventId = keccak256(bytes(description));
        opinionId = opinionIdOf(msg.sender, eventId);
        if (opinions[opinionId].wallet != address(0)) revert OpinionExists();

        uint256 bits = _acceptProof(eventId, fingerprint, x, y, c, nonce);

        opinions[opinionId] = Opinion({
            wallet: msg.sender,
            version: 1,
            bits: uint16(bits),
            x: uint64(x),
            y: uint64(y),
            c: uint64(c),
            eventId: eventId
        });
        fingerprintOf[opinionId][1] = fingerprint;

        reward = _nextReward();
        emit OpinionBroadcast(opinionId, msg.sender, eventId, description, fingerprint, x, y, c, bits, reward);

        if (reward > 0) tbn.mint(msg.sender, reward);
    }

    /// @notice Moves the caller's opinion on an event to a new unused lattice point of at least as many
    ///         bits, for a fee of |P' - P| TBN. The fee is taken out of the proof's reward, and any
    ///         remainder is burned from the caller, which requires a TBN allowance for this contract.
    function update(bytes32 eventId, bytes32 fingerprint, uint256 x, uint256 y, uint256 c, uint128 nonce)
        external
        returns (uint256 reward, uint256 fee)
    {
        bytes32 opinionId = opinionIdOf(msg.sender, eventId);
        Opinion storage opinion = opinions[opinionId];
        if (opinion.wallet == address(0)) revert NoOpinion();

        uint256 bits = _acceptProof(eventId, fingerprint, x, y, c, nonce);
        if (bits < opinion.bits) revert WeakerProof();

        fee = signalFee(opinion.x, opinion.c, x, c);
        uint256 version = uint256(opinion.version) + 1;

        opinion.version = uint32(version);
        opinion.bits = uint16(bits);
        opinion.x = uint64(x);
        opinion.y = uint64(y);
        opinion.c = uint64(c);
        fingerprintOf[opinionId][version] = fingerprint;

        reward = _nextReward();
        emit OpinionUpdated(opinionId, version, fingerprint, x, y, c, bits, reward, fee);

        if (reward > fee) {
            tbn.mint(msg.sender, reward - fee);
        } else if (fee > reward) {
            tbn.burnFrom(msg.sender, fee - reward);
        }
    }

    function opinionIdOf(address wallet, bytes32 eventId) public pure returns (bytes32) {
        return keccak256(abi.encode(wallet, eventId));
    }

    function isUsed(uint256 x, uint256 y) external view returns (bool) {
        return _used[_point(x, y)];
    }

    /// @notice Reward of the next accepted proof.
    function nextReward() external view returns (uint256) {
        return rewardAt(proofCount);
    }

    /// @notice The hash that a wallet searches over.
    function proofHash(address wallet, bytes32 eventId, bytes32 fingerprint, uint256 x, uint256 y, uint256 c, uint128 nonce)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(wallet, eventId, fingerprint, uint64(x), uint64(y), uint64(c), nonce));
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
    function isValidProof(address wallet, bytes32 eventId, bytes32 fingerprint, uint256 x, uint256 y, uint256 c, uint128 nonce)
        public
        pure
        returns (bool)
    {
        (uint256 prefix, uint256 bits) = prefixOf(x, y, c);
        return uint256(proofHash(wallet, eventId, fingerprint, x, y, c, nonce)) >> (256 - bits) == prefix;
    }

    /// @notice TBN reward of a proof accepted after `count` earlier proofs. Per million proofs, it rises
    ///         from 0.5 to 1 TBN in steps of 0.1, holds at 1 through the 18th million, falls back to 0.5
    ///         for the 23rd, stays at 0.5 for the 24th, and halves with every million after that.
    function rewardAt(uint256 count) public pure returns (uint256) {
        uint256 era = count / PROOFS_PER_ERA;

        if (era < 5) return (5 + era) * ONE / 10;
        if (era < 18) return ONE;
        if (era < 23) return (27 - era) * ONE / 10;

        uint256 halvings = era - 23;
        return halvings < 64 ? (ONE / 2) >> halvings : 0;
    }

    /// @notice |P' - P| in TBN, rounded up, where P = (x / C)^2 and P' = (x' / C')^2.
    function signalFee(uint256 x, uint256 c, uint256 newX, uint256 newC) public pure returns (uint256) {
        // All four values fit in 64 bits, so each product below fits in 256 bits.
        uint256 a = x * x * newC * newC;
        uint256 b = newX * newX * c * c;
        uint256 difference = a > b ? a - b : b - a;
        return Math.mulDiv(difference, ONE, c * c * newC * newC, Math.Rounding.Ceil);
    }

    /// @dev Checks the point and the proof for the caller, marks the point as used and returns its bits.
    function _acceptProof(bytes32 eventId, bytes32 fingerprint, uint256 x, uint256 y, uint256 c, uint128 nonce)
        internal
        returns (uint256 bits)
    {
        if (fingerprint == bytes32(0)) revert EmptyFingerprint();

        uint256 prefix;
        (prefix, bits) = prefixOf(x, y, c);

        uint256 point = _point(x, y);
        if (_used[point]) revert PointUsed();

        if (uint256(proofHash(msg.sender, eventId, fingerprint, x, y, c, nonce)) >> (256 - bits) != prefix) {
            revert InvalidProof();
        }
        _used[point] = true;
    }

    function _nextReward() internal returns (uint256 reward) {
        reward = rewardAt(proofCount);
        proofCount += 1;
    }

    function _point(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x << 128) | y;
    }
}
