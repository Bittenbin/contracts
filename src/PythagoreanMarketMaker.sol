// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

interface IMintableERC20 {
    function mint(address to, uint256 amount) external;
}

/**
 * @title PythagoreanMarketMaker
 * @author clwsqc and rtedwardchen
 * @notice Decentralized reputation system using coordinate-based markets with individual vote tracking
 * @dev Upgradeable implementation using UUPS proxy pattern with OpenZeppelin contracts
 * 
 * Core Mechanics:
 * - Markets exist at (downvotes, upvotes) coordinates
 * - Cost = sqrt(downvotes² + upvotes²) in USDC (hypotenuse-based pricing)
 * - Each voter's contributions are tracked individually for fair selling
 * - Coordinates are globally unique across all markets
 * - Market creation is permissionless (no approval required)
 * 
 * Fee Structure:
 * - Protocol fee: 100 basis points (1%) on all buy/sell transactions (paid in USDC)
 * - Fees accumulate in contract and can be distributed 50/50 to recipients
 * 
 * Staking Rewards System (Synthetix/SushiSwap O(1) Pattern):
 * - Constant emission: 1,000,000 TENBIN per year (~31.71 TENBIN/second)
 * - Total emission pool: 21,000,000 TENBIN over 21 years
 * - Rewards proportional to user's cost basis (stake) across all platforms
 * - Rewards paid in TENBIN tokens (separate from USDC payment token)
 * - O(1) gas complexity using rewardPerToken accumulator pattern
 * - PMM must be set as TENBIN minter for reward claiming
 * 
 * MEV Protection:
 * - Default 2.5% slippage tolerance on all trades
 * - Prevents sandwich attacks and front-running
 * - Custom slippage available via WithSlippage() variants
 * 
 * Safety Features:
 * - ReentrancyGuard on all state-changing functions
 * - Pausable for emergency situations
 * - Overflow protection on all math operations
 * - Maximum coordinate and hypotenuse limits
 */
contract PythagoreanMarketMaker is Initializable, UUPSUpgradeable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {
    
    // Constants
    uint256 public constant PROTOCOL_FEE_BASIS_POINTS = 100;
    uint256 public constant BASIS_POINTS_DENOMINATOR = 10000;
    uint256 public constant MAX_COORDINATE_VALUE = 1e9;
    uint256 public constant MAX_HYPOTENUSE = 1.5e9;
    uint256 public constant DEFAULT_SLIPPAGE_BASIS_POINTS = 250;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    
    // Emission constants (Tokenomics: 21M over 21 years = 1M/year)
    // 1,000,000 TENBIN/year = 1,000,000 * 1e6 / 31,536,000 ≈ 31,709 raw units/sec
    uint256 public constant REWARD_RATE = 31709; // ~0.0317 TENBIN per second (6 decimals)
    uint256 public constant EMISSION_DURATION = 21 * 365 days;
    uint256 public constant MAX_EMISSION = 21_000_000 * 1e6; // 21M TENBIN in raw units
    
    
    // State variables
    IERC20 public paymentToken; // USDC for transactions
    IERC20 public rewardToken;  // TENBIN for staking rewards
    uint256 public paymentTokenDecimals;
    
    address public ownerFeeRecipient;
    address public protocolFeeRecipient;
    
    uint256 public accumulatedProtocolFees;
    uint256 public totalMarkets; // total entities created
    uint256 public totalOwnerFloatWithdrawn; // Cumulative owner withdrawals against min-float allowance
    
    mapping(uint256 => Coordinate) public marketCoordinates;
    mapping(uint256 => bool) public marketExists;
    mapping(bytes32 => uint256) public coordinateToMarket;
    
    mapping(uint256 => address) public marketCreator;
    mapping(uint256 => uint256) public totalVoteVolume;
    
    mapping(uint256 => mapping(address => VoterPosition)) public voterPositions;

    // Metadata storage (URL uniqueness enforced via hash)
    mapping(bytes32 => bool) public urlHashUsed;
    mapping(uint256 => bytes32) public marketUrlHash;
    
    struct Coordinate {
        uint256 downvotes;
        uint256 upvotes;
    }
    
    struct VoterPosition {
        uint256 upVotes;
        uint256 downVotes;
        bool exists;
    }
    
    // Holding cost basis per platform per user (for tracking individual positions)
    struct HoldingCosts {
        uint256 trustCost;       // in payment token units
        uint256 distrustCost;    // in payment token units
    }
    mapping(uint256 => mapping(address => HoldingCosts)) public holdings;
    
    // ============================================================
    // GLOBAL STAKING STATE (Synthetix/SushiSwap pattern for O(1) rewards)
    // ============================================================
    
    // Global reward accumulator state
    uint256 public rewardPerTokenStored;     // Accumulated reward per staked token, scaled by 1e18
    uint256 public lastRewardUpdateTime;     // Last timestamp when rewardPerTokenStored was updated
    uint256 public emissionStartTime;        // Timestamp when emission started (set on first stake)
    uint256 public totalStaked;              // Total cost basis across all users and platforms
    uint256 public totalEmitted;             // Total rewards minted so far (to enforce MAX_EMISSION cap)
    
    // Per-user global reward tracking
    mapping(address => uint256) public userRewardPerTokenPaid;  // Snapshot of rewardPerTokenStored when user last interacted
    mapping(address => uint256) public pendingRewards;          // Unclaimed rewards for user
    mapping(address => uint256) public userTotalStake;          // User's total cost basis across all platforms
    
    // Upgrade control
    bool public upgradesDisabled;  // Once true, contract cannot be upgraded (one-way switch)
    
    // Events
    event MarketCreated(
        uint256 indexed pageId,
        address indexed creator,
        uint256 downvotes,
        uint256 upvotes,
        uint256 cost
    );

    // Emits raw URL for off-chain indexing; on-chain uniqueness is enforced via urlHashUsed
    event MarketMetadata(
        uint256 indexed pageId,
        bytes32 indexed urlHash,
        string url
    );
    
    event MarketVoteUpdate(
        uint256 indexed pageId,
        address indexed voter,
        uint256 fromDownvotes,
        uint256 fromUpvotes,
        uint256 toDownvotes,
        uint256 toUpvotes,
        int256 voteDelta,
        uint256 protocolFee
    );
    
    event VoterPositionUpdate(
        uint256 indexed pageId,
        address indexed voter,
        uint256 upVotes,
        uint256 downVotes,
        uint256 hypotenuse
    );
    
    event ProtocolFeesWithdrawn(address indexed to, uint256 amount);
    
    event FeeRecipientsUpdated(address indexed ownerRecipient, address indexed protocolRecipient);
    
    event ProtocolFeesDistributed(
        address indexed ownerRecipient,
        address indexed protocolRecipient,
        uint256 ownerAmount,
        uint256 protocolAmount
    );

    event OwnerFloatWithdrawn(
        address indexed to,
        uint256 amount,
        uint256 totalWithdrawn,
        uint256 maxWithdrawable
    );
    
    // Comprehensive events for tracking and indexing
    
    event SlippageProtectionApplied(
        uint256 indexed pageId,
        address indexed voter,
        uint256 slippageBasisPoints,
        uint256 expectedAmount,
        uint256 maxAcceptableAmount,
        bool isBuy
    );
    
    event VoterFirstParticipation(
        uint256 indexed pageId,
        address indexed voter,
        uint256 timestamp
    );
    
    event CoordinateChanged(
        uint256 indexed pageId,
        bytes32 indexed oldCoordinateHash,
        bytes32 indexed newCoordinateHash,
        uint256 oldDownvotes,
        uint256 oldUpvotes,
        uint256 newDownvotes,
        uint256 newUpvotes
    );
    
    event LiquidityAdded(
        uint256 indexed pageId,
        uint256 amount,
        uint256 newContractBalance
    );
    
    event LiquidityRemoved(
        uint256 indexed pageId,
        uint256 amount,
        uint256 newContractBalance
    );
    
    event EmergencyActionTaken(
        string action,
        address indexed initiator,
        uint256 timestamp,
        string reason
    );
    
    event ContractUpgraded(
        address indexed oldImplementation,
        address indexed newImplementation,
        uint256 timestamp
    );
    
    event UpgradesPermanentlyDisabled(
        address indexed disabledBy,
        uint256 timestamp
    );
    
    // Staking reward events
    event RewardClaimed(
        address indexed user,
        uint256 amount,
        uint256 totalEmittedAfter
    );
    
    event StakeUpdated(
        address indexed user,
        uint256 previousStake,
        uint256 newStake,
        uint256 totalStakedAfter
    );
    
    // Custom errors for gas-efficient reverts
    error InvalidCoordinate();
    error MarketAlreadyExists();
    error MarketDoesNotExist();
    error CoordinateOccupied();
    error InvalidAddress();
    error PaymentFailed();
    error RefundFailed();
    error InsufficientVotesToSell();
    error InvalidVoteAmount();
    error InvalidFeeAmount();
    error CoordinateTooLarge();
    error PotentialOverflow();
    error HypotenuseTooLarge();
    error SlippageExceeded();
    error InvalidSlippage();
    error InvalidUrl();
    error UrlAlreadyUsed();
    error MintingNotSupported();
    error EmissionExhausted();
    error UpgradesDisabled();
    error FloatWithdrawExceeded();
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    /**
     * @dev Initializes the contract
     * @param _paymentToken Address of the ERC20 token used for payments (USDC)
     * @param _rewardToken Address of the ERC20 token used for rewards (TENBIN)
     */
    function initialize(
        address _paymentToken,
        address _rewardToken
    ) public initializer {
        // Set immutable payment/reward tokens and fee recipients
        if (_paymentToken == address(0) || _rewardToken == address(0)) {
            revert InvalidAddress();
        }
        
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        
        paymentToken = IERC20(_paymentToken);
        rewardToken = IERC20(_rewardToken);
        
        ownerFeeRecipient = 0x2dfc776B09234f617DFc38Cb8De1BB2B0B7C4E5B;
        protocolFeeRecipient = 0xb322A547De3308C2426aEa700c8176574E57eEe6;
        
        paymentTokenDecimals = 10 ** IERC20Metadata(_paymentToken).decimals();
    }

    // ============================================================
    // STAKING REWARDS SYSTEM (Synthetix/SushiSwap O(1) Pattern)
    // ============================================================

    /**
     * @notice Get the last applicable timestamp for reward calculation
     * @dev Returns the earlier of current time or emission end time
     * @return Applicable timestamp for reward calculation
     */
    function lastTimeRewardApplicable() public view returns (uint256) {
        if (emissionStartTime == 0) {
            return block.timestamp;
        }
        uint256 emissionEndTime = emissionStartTime + EMISSION_DURATION;
        return block.timestamp < emissionEndTime ? block.timestamp : emissionEndTime;
    }

    /**
     * @notice Calculate the current reward per token value
     * @dev Core of Synthetix pattern - accumulates reward per unit of stake over time
     * @return Current rewardPerToken value, scaled by 1e18
     */
    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) {
            return rewardPerTokenStored;
        }
        
        uint256 lastApplicable = lastTimeRewardApplicable();
        if (lastApplicable <= lastRewardUpdateTime) {
            return rewardPerTokenStored;
        }
        
        uint256 timeDelta = lastApplicable - lastRewardUpdateTime;
        // reward per token = stored + (timeDelta * REWARD_RATE * 1e18 / totalStaked)
        return rewardPerTokenStored + (timeDelta * REWARD_RATE * 1e18 / totalStaked);
    }

    /**
     * @notice Calculate earned rewards for an account
     * @dev Computes pending + newly accrued rewards since last interaction
     * @param account The address to calculate earnings for
     * @return Total earned rewards (unclaimed) for the account
     */
    function earned(address account) public view returns (uint256) {
        uint256 currentRewardPerToken = rewardPerToken();
        uint256 rewardDelta = currentRewardPerToken - userRewardPerTokenPaid[account];
        // earned = stake * (currentRPT - paidRPT) / 1e18 + pending
        return (userTotalStake[account] * rewardDelta / 1e18) + pendingRewards[account];
    }

    /**
     * @notice Get the current emission rate (TENBIN per second)
     * @return Rate in raw token units (6 decimals)
     */
    function getEmissionRate() external pure returns (uint256) {
        return REWARD_RATE;
    }

    /**
     * @notice Get remaining emission that can be distributed
     * @return Remaining amount in raw token units
     */
    function remainingEmission() public view returns (uint256) {
        if (totalEmitted >= MAX_EMISSION) {
            return 0;
        }
        return MAX_EMISSION - totalEmitted;
    }

    /**
     * @notice Check if emission period is still active
     * @return True if rewards can still be distributed
     */
    function isEmissionActive() public view returns (bool) {
        if (emissionStartTime == 0) {
            return true; // Not started yet, will be active once first stake happens
        }
        return block.timestamp < emissionStartTime + EMISSION_DURATION && totalEmitted < MAX_EMISSION;
    }

    /**
     * @dev Internal function to update reward state (called before any stake change)
     * @param account The account to update rewards for (address(0) for global-only update)
     */
    function _updateReward(address account) internal {
        rewardPerTokenStored = rewardPerToken();
        lastRewardUpdateTime = lastTimeRewardApplicable();
        
        if (account != address(0)) {
            pendingRewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
    }

    /**
     * @notice Claim accumulated staking rewards
     * @dev Mints TENBIN tokens to caller. PMM must be set as TENBIN minter.
     */
    function claimRewards() external nonReentrant whenNotPaused {
        // Settle rewards then mint TENBIN to caller
        _updateReward(msg.sender);
        
        uint256 reward = pendingRewards[msg.sender];
        if (reward == 0) {
            return;
        }
        
        // Enforce emission cap
        uint256 remaining = remainingEmission();
        if (remaining == 0) {
            revert EmissionExhausted();
        }
        if (reward > remaining) {
            reward = remaining;
        }
        
        pendingRewards[msg.sender] = pendingRewards[msg.sender] - reward;
        totalEmitted += reward;
        
        // Mint reward tokens to user (PMM must be set as minter on TENBIN)
        try IMintableERC20(address(rewardToken)).mint(msg.sender, reward) {
        } catch {
            revert MintingNotSupported();
        }
        
        emit RewardClaimed(msg.sender, reward, totalEmitted);
    }
    
    /**
     * @dev Internal function to update a user's stake and global totals
     * @param user The user whose stake is changing
     * @param newUserStake The user's new total stake
     */
    function _updateUserStake(address user, uint256 newUserStake) internal {
        // Update rewards before changing stake
        _updateReward(user);
        
        // Initialize emission start time on first stake
        if (emissionStartTime == 0 && newUserStake > 0) {
            emissionStartTime = block.timestamp;
            lastRewardUpdateTime = block.timestamp;
        }
        
        uint256 previousStake = userTotalStake[user];
        
        // Update global total
        if (newUserStake > previousStake) {
            totalStaked += (newUserStake - previousStake);
        } else if (newUserStake < previousStake) {
            totalStaked -= (previousStake - newUserStake);
        }
        
        userTotalStake[user] = newUserStake;
        
        emit StakeUpdated(user, previousStake, newUserStake, totalStaked);
    }

    /**
     * @dev Creates a new market using a URL-derived platform ID
     * @param url Raw URL string provided by the user
     * @param initialDownvotes Initial downvotes
     * @param initialUpvotes Initial upvotes
     */
    function createMarket(
        string calldata url,
        uint256 initialDownvotes,
        uint256 initialUpvotes
    ) external whenNotPaused nonReentrant {
        // Use default slippage tolerance and derive pageId from URL hash
        if (bytes(url).length == 0) {
            revert InvalidUrl();
        }
        bytes32 urlHash = keccak256(bytes(url));
        uint256 pageId = uint256(urlHash);
        _createMarketWithSlippage(pageId, initialDownvotes, initialUpvotes, DEFAULT_SLIPPAGE_BASIS_POINTS, url, urlHash);
    }
    
    /**
     * @dev Creates a new market with custom slippage tolerance
     * @param url Raw URL string provided by the user
     * @param initialDownvotes Initial downvotes
     * @param initialUpvotes Initial upvotes
     * @param slippageBasisPoints Maximum acceptable slippage in basis points
     */
    function createMarketWithSlippage(
        string calldata url,
        uint256 initialDownvotes,
        uint256 initialUpvotes,
        uint256 slippageBasisPoints
    ) external whenNotPaused nonReentrant {
        // Derive pageId from URL hash and apply custom slippage
        if (bytes(url).length == 0) {
            revert InvalidUrl();
        }
        bytes32 urlHash = keccak256(bytes(url));
        uint256 pageId = uint256(urlHash);
        _createMarketWithSlippage(pageId, initialDownvotes, initialUpvotes, slippageBasisPoints, url, urlHash);
    }
    
    /**
     * @dev Internal function to create market with slippage protection
     */
    function _createMarketWithSlippage(
        uint256 pageId,
        uint256 initialDownvotes,
        uint256 initialUpvotes,
        uint256 slippageBasisPoints,
        string memory url,
        bytes32 urlHash
    ) internal {
        // Permissionless market creation with USDC payment
        if (slippageBasisPoints > BASIS_POINTS_DENOMINATOR) {
            revert InvalidSlippage();
        }
        
        if (marketExists[pageId]) {
            revert MarketAlreadyExists();
        }
        
        _validateCoordinateBounds(initialDownvotes, initialUpvotes);
        
        uint256 totalVotes = initialDownvotes + initialUpvotes;
        if (!isValidCoordinate(initialDownvotes, initialUpvotes)) {
            revert InvalidCoordinate();
        }

        // Enforce metadata uniqueness only when a URL is provided
        if (bytes(url).length > 0) {
            if (urlHashUsed[urlHash]) {
                revert UrlAlreadyUsed();
            }
            urlHashUsed[urlHash] = true;
            marketUrlHash[pageId] = urlHash;
        }
        
        bytes32 coordHash = keccak256(abi.encodePacked(initialDownvotes, initialUpvotes));
        if (coordinateToMarket[coordHash] != 0) {
            revert CoordinateOccupied();
        }
        
        // Compute hypotenuse in token units (fixed-point with payment token decimals)
        uint256 downvotesSquared = _safeMul(initialDownvotes, initialDownvotes);
        uint256 upvotesSquared = _safeMul(initialUpvotes, initialUpvotes);
        uint256 sumSquares = _safeAddSquares(downvotesSquared, upvotesSquared);
        // Ensure hypotenuse is within limit without precision loss: sumSquares <= MAX_HYPOTENUSE^2
        if (sumSquares > _safeMul(MAX_HYPOTENUSE, MAX_HYPOTENUSE)) {
            revert HypotenuseTooLarge();
        }
        uint256 initialHypotenuseScaled = _computeHypotenuseScaled(initialDownvotes, initialUpvotes);
        uint256 totalPaymentInTokenUnits = _validatePaymentAmount(initialHypotenuseScaled);
        uint256 protocolFee = (totalPaymentInTokenUnits * PROTOCOL_FEE_BASIS_POINTS) / BASIS_POINTS_DENOMINATOR;
        uint256 totalPayment = totalPaymentInTokenUnits + protocolFee;
        
        uint256 maxAcceptablePayment = totalPayment + (totalPayment * slippageBasisPoints) / BASIS_POINTS_DENOMINATOR;
        
        emit SlippageProtectionApplied(
            pageId,
            msg.sender,
            slippageBasisPoints,
            totalPayment,
            maxAcceptablePayment,
            true
        );
        
        if (totalPayment > maxAcceptablePayment) {
            revert SlippageExceeded();
        }
        
        if (!paymentToken.transferFrom(msg.sender, address(this), totalPayment)) {
            revert PaymentFailed();
        }
        
        accumulatedProtocolFees += protocolFee;
        
        marketCoordinates[pageId] = Coordinate(initialDownvotes, initialUpvotes);
        marketExists[pageId] = true;
        coordinateToMarket[coordHash] = pageId;
        marketCreator[pageId] = msg.sender;
        totalVoteVolume[pageId] = totalVotes;
        totalMarkets += 1;
        
        voterPositions[pageId][msg.sender] = VoterPosition({
            upVotes: initialUpvotes,
            downVotes: initialDownvotes,
            exists: true
        });
        
        // Track cost basis for staking rewards
        // trustCost = cost of going from (0,0) to (0, initialUpvotes)
        // distrustCost = cost of going from (0, initialUpvotes) to (initialDownvotes, initialUpvotes)
        uint256 trustCostPart = _computeHypotenuseScaled(0, initialUpvotes);
        uint256 distrustCostPart = initialHypotenuseScaled - trustCostPart;
        holdings[pageId][msg.sender] = HoldingCosts({
            trustCost: trustCostPart,
            distrustCost: distrustCostPart
        });
        
        // Update global staking state (user's new total stake across all platforms)
        uint256 newUserTotalStake = userTotalStake[msg.sender] + trustCostPart + distrustCostPart;
        _updateUserStake(msg.sender, newUserTotalStake);
        
        emit MarketCreated(pageId, msg.sender, initialDownvotes, initialUpvotes, totalVotes);
        if (bytes(url).length > 0) {
            // Emit raw URL for off-chain indexing; hash is stored for uniqueness checks
            emit MarketMetadata(pageId, urlHash, url);
        }
        // For event readability, include integer hypotenuse (floor) in the event payload
        emit VoterPositionUpdate(pageId, msg.sender, initialUpvotes, initialDownvotes, Math.sqrt(sumSquares));
        emit VoterFirstParticipation(pageId, msg.sender, block.timestamp);
        emit LiquidityAdded(pageId, totalPayment, paymentToken.balanceOf(address(this)));
    }
    
    /**
     * @dev Vote on an existing market by adjusting your position
     * @param pageId The page ID to vote on
     * @param newDownvotes New downvotes (for the entire market)
     * @param newUpvotes New upvotes (for the entire market)
     */
    function voteOnMarket(
        uint256 pageId,
        uint256 newDownvotes,
        uint256 newUpvotes
    ) external whenNotPaused nonReentrant {
        _voteOnMarketWithSlippage(pageId, newDownvotes, newUpvotes, DEFAULT_SLIPPAGE_BASIS_POINTS);
    }
    
    /**
     * @dev Vote on market with custom slippage tolerance
     * @param pageId The page ID to vote on
     * @param newDownvotes New downvotes (for the entire market)
     * @param newUpvotes New upvotes (for the entire market)
     * @param slippageBasisPoints Maximum acceptable slippage in basis points
     */
    function voteOnMarketWithSlippage(
        uint256 pageId,
        uint256 newDownvotes,
        uint256 newUpvotes,
        uint256 slippageBasisPoints
    ) external whenNotPaused nonReentrant {
        _voteOnMarketWithSlippage(pageId, newDownvotes, newUpvotes, slippageBasisPoints);
    }
    
    /**
     * @dev Internal function to vote with slippage protection
     */
    function _voteOnMarketWithSlippage(
        uint256 pageId,
        uint256 newDownvotes,
        uint256 newUpvotes,
        uint256 slippageBasisPoints
    ) internal {
        // Single-axis move: only one coordinate can change per transaction
        if (slippageBasisPoints > BASIS_POINTS_DENOMINATOR) {
            revert InvalidSlippage();
        }
        
        if (!marketExists[pageId]) {
            revert MarketDoesNotExist();
        }
        
        _validateCoordinateBounds(newDownvotes, newUpvotes);

        Coordinate memory current = marketCoordinates[pageId];
        bool downvotesChanged = newDownvotes != current.downvotes;
        bool upvotesChanged = newUpvotes != current.upvotes;
        if (downvotesChanged == upvotesChanged) {
            // Disallow no-op and diagonal moves (must change exactly one axis)
            revert InvalidCoordinate();
        }
        
        if (!isValidCoordinate(newDownvotes, newUpvotes)) {
            revert InvalidCoordinate();
        }
        
        bytes32 newCoordHash = keccak256(abi.encodePacked(newDownvotes, newUpvotes));
        uint256 occupyingMarket = coordinateToMarket[newCoordHash];
        if (occupyingMarket != 0 && occupyingMarket != pageId) {
            revert CoordinateOccupied();
        }
        
        _processVoteUpdate(pageId, newDownvotes, newUpvotes, newCoordHash, slippageBasisPoints);
    }
    
    /**
     * @dev Internal function to process vote updates with slippage protection
     */
    function _processVoteUpdate(
        uint256 pageId,
        uint256 newDownvotes,
        uint256 newUpvotes,
        bytes32 newCoordHash,
        uint256 slippageBasisPoints
    ) internal {
        // Core vote processing: compute deltas, apply buy/sell, update stake
        Coordinate memory current = marketCoordinates[pageId];
        VoterPosition storage voterPos = voterPositions[pageId][msg.sender];
        
        bool isFirstTimeVoter = !voterPos.exists;
        
        int256 upvotesDelta = int256(newUpvotes) - int256(current.upvotes);
        int256 downvotesDelta = int256(newDownvotes) - int256(current.downvotes);
        
        uint256 currentDownvotesSquared = _safeMul(current.downvotes, current.downvotes);
        uint256 currentUpvotesSquared = _safeMul(current.upvotes, current.upvotes);
        uint256 currentSumSquares = _safeAddSquares(currentDownvotesSquared, currentUpvotesSquared);
        uint256 currentHypotenuseInt = Math.sqrt(currentSumSquares);
        
        uint256 newDownvotesSquared = _safeMul(newDownvotes, newDownvotes);
        uint256 newUpvotesSquared = _safeMul(newUpvotes, newUpvotes);
        uint256 newSumSquares = _safeAddSquares(newDownvotesSquared, newUpvotesSquared);
        uint256 newHypotenuseInt = Math.sqrt(newSumSquares);
        
        // Ensure hypotenuse is within limit using exact squared comparison
        if (newSumSquares > _safeMul(MAX_HYPOTENUSE, MAX_HYPOTENUSE)) {
            revert HypotenuseTooLarge();
        }
        // Compute scaled hypotenuse values (fixed-point with token decimals)
        uint256 currentHypotenuseScaled = _computeHypotenuseScaled(current.downvotes, current.upvotes);
        uint256 newHypotenuseScaled = _computeHypotenuseScaled(newDownvotes, newUpvotes);
        int256 hypotenuseChangeScaled = int256(newHypotenuseScaled) - int256(currentHypotenuseScaled);
        
        uint256 protocolFee;
        
        // Track old cost basis before changes for stake update
        HoldingCosts storage userHoldings = holdings[pageId][msg.sender];
        uint256 oldPlatformCost = userHoldings.trustCost + userHoldings.distrustCost;
        
        if (hypotenuseChangeScaled > 0) {
            protocolFee = _processBuyVotesWithSlippage(
                pageId,
                uint256(hypotenuseChangeScaled),
                upvotesDelta,
                downvotesDelta,
                voterPos,
                slippageBasisPoints
            );
            totalVoteVolume[pageId] += uint256(hypotenuseChangeScaled);
            // Single-axis: only one of upvotesDelta/downvotesDelta can be positive
            if (upvotesDelta > 0) {
                uint256 trustBuy = uint256(upvotesDelta);
                uint256 trustPart = _computeHypotenuseScaled(current.downvotes, current.upvotes + trustBuy) - _computeHypotenuseScaled(current.downvotes, current.upvotes);
                userHoldings.trustCost += trustPart;
            } else if (downvotesDelta > 0) {
                uint256 distrustBuy = uint256(downvotesDelta);
                uint256 distrustPart = _computeHypotenuseScaled(current.downvotes + distrustBuy, current.upvotes) - _computeHypotenuseScaled(current.downvotes, current.upvotes);
                userHoldings.distrustCost += distrustPart;
            }
        } else if (hypotenuseChangeScaled < 0) {
            // Before sell, compute previous holdings for pro-rata reduction
            uint256 prevTrust = voterPos.upVotes;
            uint256 prevDistrust = voterPos.downVotes;
            uint256 trustSell = upvotesDelta < 0 ? uint256(-upvotesDelta) : 0;
            uint256 distrustSell = downvotesDelta < 0 ? uint256(-downvotesDelta) : 0;

            protocolFee = _processSellVotesWithSlippage(
                pageId,
                uint256(-hypotenuseChangeScaled),
                upvotesDelta,
                downvotesDelta,
                voterPos,
                slippageBasisPoints
            );
            // Pro-rata reduce cost basis for sold units
            if (trustSell > 0 && prevTrust > 0) {
                userHoldings.trustCost = userHoldings.trustCost * (prevTrust - trustSell) / prevTrust;
            }
            if (distrustSell > 0 && prevDistrust > 0) {
                userHoldings.distrustCost = userHoldings.distrustCost * (prevDistrust - distrustSell) / prevDistrust;
            }
        } else {
            // Same hypotenuse moves are not possible with single-axis constraint
            revert InvalidCoordinate();
        }
        
        // Update global staking state with new cost basis
        uint256 newPlatformCost = userHoldings.trustCost + userHoldings.distrustCost;
        if (newPlatformCost != oldPlatformCost) {
            // Calculate user's new total stake across all platforms
            uint256 oldUserTotalStake = userTotalStake[msg.sender];
            uint256 newUserTotalStake;
            if (newPlatformCost > oldPlatformCost) {
                newUserTotalStake = oldUserTotalStake + (newPlatformCost - oldPlatformCost);
            } else {
                newUserTotalStake = oldUserTotalStake - (oldPlatformCost - newPlatformCost);
            }
            _updateUserStake(msg.sender, newUserTotalStake);
        }
        
        voterPos.exists = true;
        
        bytes32 oldCoordHash = keccak256(abi.encodePacked(current.downvotes, current.upvotes));
        delete coordinateToMarket[oldCoordHash];
        coordinateToMarket[newCoordHash] = pageId;
        
        marketCoordinates[pageId] = Coordinate(newDownvotes, newUpvotes);
        
        emit MarketVoteUpdate(
            pageId,
            msg.sender,
            current.downvotes,
            current.upvotes,
            newDownvotes,
            newUpvotes,
            int256(newHypotenuseInt) - int256(currentHypotenuseInt),
            protocolFee
        );
        
        emit VoterPositionUpdate(
            pageId, 
            msg.sender, 
            voterPos.upVotes, 
            voterPos.downVotes, 
            newHypotenuseInt
        );
        
        emit CoordinateChanged(pageId, oldCoordHash, newCoordHash, current.downvotes, current.upvotes, newDownvotes, newUpvotes);
        
        if (isFirstTimeVoter) {
            emit VoterFirstParticipation(pageId, msg.sender, block.timestamp);
        }
    }

    /**
     * @dev Process buying votes with slippage protection
     */
    function _processBuyVotesWithSlippage(
        uint256 pageId,
        uint256 hypotenuseIncrease,
        int256 upvotesDelta,
        int256 downvotesDelta,
        VoterPosition storage voterPos,
        uint256 slippageBasisPoints
    ) internal returns (uint256 protocolFee) {
        // Buy path: collect USDC + fee, then update position
        uint256 payment = _validatePaymentAmount(hypotenuseIncrease);
        protocolFee = (payment * PROTOCOL_FEE_BASIS_POINTS) / BASIS_POINTS_DENOMINATOR;
        uint256 totalPayment = payment + protocolFee;
        
        uint256 maxAcceptablePayment = totalPayment + (totalPayment * slippageBasisPoints) / BASIS_POINTS_DENOMINATOR;
        
        emit SlippageProtectionApplied(
            pageId,
            msg.sender,
            slippageBasisPoints,
            totalPayment,
            maxAcceptablePayment,
            true
        );
        
        if (totalPayment > maxAcceptablePayment) {
            revert SlippageExceeded();
        }
        
        uint256 userBalance = paymentToken.balanceOf(msg.sender);
        if (userBalance < totalPayment) {
            revert PaymentFailed();
        }
        
        if (!paymentToken.transferFrom(msg.sender, address(this), totalPayment)) {
            revert PaymentFailed();
        }
        
        accumulatedProtocolFees += protocolFee;
        
        if (upvotesDelta > 0) {
            voterPos.upVotes += uint256(upvotesDelta);
        } else if (upvotesDelta < 0) {
            uint256 reductionAmount = uint256(-upvotesDelta);
            if (voterPos.upVotes < reductionAmount) {
                revert InsufficientVotesToSell();
            }
            voterPos.upVotes -= reductionAmount;
        }
        
        if (downvotesDelta > 0) {
            voterPos.downVotes += uint256(downvotesDelta);
        } else if (downvotesDelta < 0) {
            uint256 reductionAmount = uint256(-downvotesDelta);
            if (voterPos.downVotes < reductionAmount) {
                revert InsufficientVotesToSell();
            }
            voterPos.downVotes -= reductionAmount;
        }
        
        emit LiquidityAdded(pageId, totalPayment, paymentToken.balanceOf(address(this)));
    }
    
    /**
     * @dev Process selling votes with slippage protection
     */
    function _processSellVotesWithSlippage(
        uint256 pageId,
        uint256 hypotenuseDecrease,
        int256 upvotesDelta,
        int256 downvotesDelta,
        VoterPosition storage voterPos,
        uint256 slippageBasisPoints
    ) internal returns (uint256 protocolFee) {
        // Sell path: validate holdings, refund USDC minus fee
        if (upvotesDelta < 0) {
            uint256 sellAmount = uint256(-upvotesDelta);
            if (voterPos.upVotes < sellAmount) {
                revert InsufficientVotesToSell();
            }
            voterPos.upVotes -= sellAmount;
        } else if (upvotesDelta > 0) {
            voterPos.upVotes += uint256(upvotesDelta);
        }
        
        if (downvotesDelta < 0) {
            uint256 sellAmount = uint256(-downvotesDelta);
            if (voterPos.downVotes < sellAmount) {
                revert InsufficientVotesToSell();
            }
            voterPos.downVotes -= sellAmount;
        } else if (downvotesDelta > 0) {
            voterPos.downVotes += uint256(downvotesDelta);
        }
        
        uint256 refundAmount = _validatePaymentAmount(hypotenuseDecrease);
        protocolFee = (refundAmount * PROTOCOL_FEE_BASIS_POINTS) / BASIS_POINTS_DENOMINATOR;
        uint256 netRefund = refundAmount - protocolFee;
        
        uint256 minAcceptableRefund = netRefund - (netRefund * slippageBasisPoints) / BASIS_POINTS_DENOMINATOR;
        
        emit SlippageProtectionApplied(
            pageId,
            msg.sender,
            slippageBasisPoints,
            netRefund,
            minAcceptableRefund,
            false
        );
        
        if (netRefund < minAcceptableRefund) {
            revert SlippageExceeded();
        }
        
        accumulatedProtocolFees += protocolFee;
        
        if (!paymentToken.transfer(msg.sender, netRefund)) {
            revert RefundFailed();
        }
        
        emit LiquidityRemoved(pageId, netRefund, paymentToken.balanceOf(address(this)));
    }
    
    /**
     * @dev Process rebalancing (same hypotenuse)
     */
    
    /**
     * @dev Get voter's position in a market
     * @param pageId The page ID
     * @param voter The voter's address
     * @return upVotes Number of upvotes owned
     * @return downVotes Number of downvotes owned
     * @return exists Whether voter has a position
     */
    function getVoterPosition(
        uint256 pageId,
        address voter
    ) external view returns (
        uint256 upVotes,
        uint256 downVotes,
        bool exists
    ) {
        VoterPosition memory pos = voterPositions[pageId][voter];
        return (pos.upVotes, pos.downVotes, pos.exists);
    }
    
    /**
     * @dev Get market state and page score
     * @param pageId The page ID to query
     * @return downvotes Downvotes
     * @return upvotes Upvotes
     * @return pageScore Page score (0 to 1e18)
     * @return totalVotes Total current votes
     */
    function getMarketState(uint256 pageId) 
        external 
        view 
        returns (
            uint256 downvotes,
            uint256 upvotes,
            uint256 pageScore,
            uint256 totalVotes
        ) 
    {
        if (!marketExists[pageId]) {
            return (0, 0, 0, 0);
        }
        
        Coordinate memory coord = marketCoordinates[pageId];
        downvotes = coord.downvotes;
        upvotes = coord.upvotes;
        totalVotes = downvotes + upvotes;
        pageScore = calculatePageScore(downvotes, upvotes);
    }
    
    /**
     * @dev Get contract's current token balance
     * @return balance Current balance of payment tokens held by contract
     */
    function getContractBalance() external view returns (uint256 balance) {
        return paymentToken.balanceOf(address(this));
    }
    
    /**
     * @dev Get contract's available liquidity (balance minus fees)
     * @return liquidity Available liquidity for refunds
     */
    function getAvailableLiquidity() external view returns (uint256 liquidity) {
        uint256 totalBalance = paymentToken.balanceOf(address(this));
        return totalBalance > accumulatedProtocolFees ? totalBalance - accumulatedProtocolFees : 0;
    }

    /**
     * @dev Heuristic minimum TVL estimate (first-quadrant lattice packing)
     * @notice minTVL ≈ (4 / (3 * sqrt(pi))) * n^(3/2), with n = totalMarkets
     */
    function minimumFloatEstimate() public view returns (uint256) {
        uint256 n = totalMarkets;
        if (n == 0) {
            return 0;
        }
        // 4 / (3 * sqrt(pi)) ≈ 0.752252778063675
        uint256 factorWad = 752252778063675000; // 1e18 precision
        uint256 sqrtN = Math.sqrt(n);
        uint256 nTimesSqrtN = _safeMul(n, sqrtN);
        return (factorWad * nTimesSqrtN) / 1e18;
    }

    /**
     * @dev Owner can withdraw from liquidity up to the min-float estimate (cumulative)
     */
    function withdrawOwnerFloat(uint256 amount) external onlyOwner nonReentrant {
        uint256 maxWithdrawable = minimumFloatEstimate();
        if (totalOwnerFloatWithdrawn + amount > maxWithdrawable) {
            revert FloatWithdrawExceeded();
        }

        uint256 available = paymentToken.balanceOf(address(this)) > accumulatedProtocolFees
            ? paymentToken.balanceOf(address(this)) - accumulatedProtocolFees
            : 0;
        if (amount > available) {
            revert InvalidFeeAmount();
        }

        totalOwnerFloatWithdrawn += amount;
        if (!paymentToken.transfer(ownerFeeRecipient, amount)) {
            revert PaymentFailed();
        }

        emit OwnerFloatWithdrawn(ownerFeeRecipient, amount, totalOwnerFloatWithdrawn, maxWithdrawable);
    }
    
    /**
     * @dev Get protocol fee percentage in basis points
     * @return feeBasisPoints The protocol fee in basis points
     * @return feePercentage The protocol fee as a percentage (for display)
     */
    function getProtocolFeeInfo() external pure returns (
        uint256 feeBasisPoints,
        uint256 feePercentage
    ) {
        return (PROTOCOL_FEE_BASIS_POINTS, PROTOCOL_FEE_BASIS_POINTS / 100);
    }
    
    /**
     * @dev Get default slippage tolerance
     * @return slippageBasisPoints The default slippage in basis points
     * @return slippagePercentage The default slippage as a percentage
     */
    function getDefaultSlippage() external pure returns (
        uint256 slippageBasisPoints,
        uint256 slippagePercentage
    ) {
        return (DEFAULT_SLIPPAGE_BASIS_POINTS, DEFAULT_SLIPPAGE_BASIS_POINTS / 100);
    }
    
    /**
     * @dev Calculate expected payment with slippage for buying votes
     * @param currentDownvotes Current downvotes coordinate
     * @param currentUpvotes Current upvotes coordinate
     * @param newDownvotes Target downvotes coordinate
     * @param newUpvotes Target upvotes coordinate
     * @param slippageBasisPoints Slippage tolerance in basis points
     * @return expectedPayment Expected payment amount
     * @return maxPaymentWithSlippage Maximum payment with slippage
     */
    function calculatePaymentWithSlippage(
        uint256 currentDownvotes,
        uint256 currentUpvotes,
        uint256 newDownvotes,
        uint256 newUpvotes,
        uint256 slippageBasisPoints
    ) external view returns (
        uint256 expectedPayment,
        uint256 maxPaymentWithSlippage
    ) {
        _validateCoordinateBounds(currentDownvotes, currentUpvotes);
        _validateCoordinateBounds(newDownvotes, newUpvotes);
        
        uint256 currentHypotenuseScaled = _computeHypotenuseScaled(currentDownvotes, currentUpvotes);
        uint256 newHypotenuseScaled = _computeHypotenuseScaled(newDownvotes, newUpvotes);
        
        if (newHypotenuseScaled <= currentHypotenuseScaled) {
            return (0, 0);
        }
        
        uint256 hypotenuseIncreaseScaled = newHypotenuseScaled - currentHypotenuseScaled;
        uint256 payment = _validatePaymentAmount(hypotenuseIncreaseScaled);
        uint256 protocolFee = (payment * PROTOCOL_FEE_BASIS_POINTS) / BASIS_POINTS_DENOMINATOR;
        expectedPayment = payment + protocolFee;
        maxPaymentWithSlippage = expectedPayment + (expectedPayment * slippageBasisPoints) / BASIS_POINTS_DENOMINATOR;
    }
    
    /**
     * @dev Calculate expected refund with slippage for selling votes
     * @param currentDownvotes Current downvotes coordinate
     * @param currentUpvotes Current upvotes coordinate
     * @param newDownvotes Target downvotes coordinate
     * @param newUpvotes Target upvotes coordinate
     * @param slippageBasisPoints Slippage tolerance in basis points
     * @return expectedRefund Expected refund amount
     * @return minRefundWithSlippage Minimum refund with slippage
     */
    function calculateRefundWithSlippage(
        uint256 currentDownvotes,
        uint256 currentUpvotes,
        uint256 newDownvotes,
        uint256 newUpvotes,
        uint256 slippageBasisPoints
    ) external view returns (
        uint256 expectedRefund,
        uint256 minRefundWithSlippage
    ) {
        _validateCoordinateBounds(currentDownvotes, currentUpvotes);
        _validateCoordinateBounds(newDownvotes, newUpvotes);
        
        uint256 currentHypotenuseScaled = _computeHypotenuseScaled(currentDownvotes, currentUpvotes);
        uint256 newHypotenuseScaled = _computeHypotenuseScaled(newDownvotes, newUpvotes);
        
        if (newHypotenuseScaled >= currentHypotenuseScaled) {
            return (0, 0);
        }
        
        uint256 hypotenuseDecreaseScaled = currentHypotenuseScaled - newHypotenuseScaled;
        uint256 refundAmount = _validatePaymentAmount(hypotenuseDecreaseScaled);
        uint256 protocolFee = (refundAmount * PROTOCOL_FEE_BASIS_POINTS) / BASIS_POINTS_DENOMINATOR;
        expectedRefund = refundAmount - protocolFee;
        minRefundWithSlippage = expectedRefund - (expectedRefund * slippageBasisPoints) / BASIS_POINTS_DENOMINATOR;
    }
    
    /**
     * @dev Get fee distribution info
     * @return ownerRecipient Address receiving owner's share
     * @return protocolRecipient Address receiving protocol's share
     * @return pendingFees Total accumulated fees pending distribution
     */
    function getFeeDistributionInfo() external view returns (
        address ownerRecipient,
        address protocolRecipient,
        uint256 pendingFees
    ) {
        return (ownerFeeRecipient, protocolFeeRecipient, accumulatedProtocolFees);
    }
    
    /**
     * @dev Calculate how fees would be split if distributed now
     * @return ownerShare Amount that would go to owner
     * @return protocolShare Amount that would go to protocol
     */
    function calculateFeeDistribution() external view returns (
        uint256 ownerShare,
        uint256 protocolShare
    ) {
        uint256 total = accumulatedProtocolFees;
        ownerShare = total / 2;
        protocolShare = total - ownerShare;
    }
    
    /**
     * @dev Check if a market exists for a page ID
     * @param pageId The page ID to check
     * @return exists Whether the market exists
     */
    function marketExistsFor(uint256 pageId) external view returns (bool exists) {
        return marketExists[pageId];
    }
    
    /**
     * @dev Calculate page score for given coordinates
     * @param downvotes Downvotes
     * @param upvotes Upvotes
     * @return Trust score scaled by 1e18
     */
    function calculatePageScore(uint256 downvotes, uint256 upvotes) public pure returns (uint256) {
        if (downvotes == 0 && upvotes == 0) {
            return 0;
        }
        
        if (downvotes > MAX_COORDINATE_VALUE || upvotes > MAX_COORDINATE_VALUE) {
            revert CoordinateTooLarge();
        }
        
        uint256 downvotesSquared = _safeMul(downvotes, downvotes);
        uint256 upvotesSquared = _safeMul(upvotes, upvotes);
        uint256 sumSquares = _safeAddSquares(downvotesSquared, upvotesSquared);
        
        return (upvotesSquared * 1e18) / sumSquares;
    }
    
    /**
     * @dev Check if coordinates are valid (positive, within bounds, hypotenuse within max)
     * @param downvotes The downvotes coordinate
     * @param upvotes The upvotes coordinate
     * @return bool True if valid
     */
    function isValidCoordinate(uint256 downvotes, uint256 upvotes) public pure returns (bool) {
        if (downvotes == 0 || upvotes == 0) {
            return false;
        }
        
        if (downvotes > MAX_COORDINATE_VALUE || upvotes > MAX_COORDINATE_VALUE) {
            return false;
        }
        
        uint256 downvotesSquared = _safeMul(downvotes, downvotes);
        uint256 upvotesSquared = _safeMul(upvotes, upvotes);
        uint256 sumSquares = _safeAddSquares(downvotesSquared, upvotesSquared);
        // Valid if hypotenuse^2 <= MAX_HYPOTENUSE^2
        return sumSquares <= _safeMul(MAX_HYPOTENUSE, MAX_HYPOTENUSE);
    }
    
    /**
     * @dev Distribute protocol fees 50/50 between owner and protocol
     * @param amount The amount to distribute (0 = distribute all)
     * @notice Only callable by owner
     * @return totalAmount The total amount of fees distributed
     */
    function distributeProtocolFees(uint256 amount) external onlyOwner nonReentrant returns (uint256 totalAmount) {
        totalAmount = amount == 0 ? accumulatedProtocolFees : amount;
        
        if (totalAmount == 0 || totalAmount > accumulatedProtocolFees) {
            revert InvalidFeeAmount();
        }
        
        uint256 ownerShare = totalAmount / 2;
        uint256 protocolShare = totalAmount - ownerShare;
        
        accumulatedProtocolFees -= totalAmount;
        
        if (!paymentToken.transfer(ownerFeeRecipient, ownerShare)) {
            revert PaymentFailed();
        }
        
        if (!paymentToken.transfer(protocolFeeRecipient, protocolShare)) {
            revert PaymentFailed();
        }
        
        emit ProtocolFeesDistributed(ownerFeeRecipient, protocolFeeRecipient, ownerShare, protocolShare);
    }
    
    /**
     * @dev Withdraw fees to owner recipient only
     * @param amount The amount to withdraw to owner
     * @notice Only callable by owner
     */
    function withdrawToOwner(uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0 || amount > accumulatedProtocolFees) {
            revert InvalidFeeAmount();
        }
        
        accumulatedProtocolFees -= amount;
        
        if (!paymentToken.transfer(ownerFeeRecipient, amount)) {
            revert PaymentFailed();
        }
        
        emit ProtocolFeesWithdrawn(ownerFeeRecipient, amount);
    }
    
    /**
     * @dev Withdraw fees to protocol recipient only
     * @param amount The amount to withdraw to protocol
     * @notice Only callable by owner
     */
    function withdrawToProtocol(uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0 || amount > accumulatedProtocolFees) {
            revert InvalidFeeAmount();
        }
        
        accumulatedProtocolFees -= amount;
        
        if (!paymentToken.transfer(protocolFeeRecipient, amount)) {
            revert PaymentFailed();
        }
        
        emit ProtocolFeesWithdrawn(protocolFeeRecipient, amount);
    }
    
    /**
     * @dev Update fee recipient addresses
     * @param newOwnerRecipient New address for owner's fee share
     * @param newProtocolRecipient New address for protocol's fee share
     * @notice Only callable by owner
     */
    function updateFeeRecipients(
        address newOwnerRecipient,
        address newProtocolRecipient
    ) external onlyOwner {
        if (newOwnerRecipient == address(0) || newProtocolRecipient == address(0)) {
            revert InvalidAddress();
        }
        
        ownerFeeRecipient = newOwnerRecipient;
        protocolFeeRecipient = newProtocolRecipient;
        
        emit FeeRecipientsUpdated(newOwnerRecipient, newProtocolRecipient);
    }
    
    /**
     * @dev Pause the contract with reason
     * @param reason Reason for pausing (empty string for default message)
     * @notice Only callable by owner
     */
    function pause(string calldata reason) external onlyOwner {
        _pause();
        emit EmergencyActionTaken("pause", msg.sender, block.timestamp, 
            bytes(reason).length == 0 ? "Contract paused by owner" : reason);
    }
    
    /**
     * @dev Unpause the contract
     * @notice Only callable by owner
     */
    function unpause() external onlyOwner {
        _unpause();
        emit EmergencyActionTaken("unpause", msg.sender, block.timestamp, "Contract unpaused by owner");
    }
    
    /**
     * @notice Permanently disable contract upgrades (one-way operation)
     * @dev Once called, the contract becomes immutable. Cannot be undone.
     * @notice Only callable by owner
     */
    function disableUpgrades() external onlyOwner {
        upgradesDisabled = true;
        emit UpgradesPermanentlyDisabled(msg.sender, block.timestamp);
        emit EmergencyActionTaken("upgrades_disabled", msg.sender, block.timestamp, "Contract upgrades permanently disabled");
    }
    
    /**
     * @notice Check if the contract is immutable (upgrades disabled)
     * @return True if upgrades have been permanently disabled
     */
    function isImmutable() external view returns (bool) {
        return upgradesDisabled;
    }
    
    /**
     * @dev Required by UUPSUpgradeable. Reverts if upgrades have been disabled.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        if (upgradesDisabled) {
            revert UpgradesDisabled();
        }
        emit ContractUpgraded(address(this), newImplementation, block.timestamp);
    }
    
    /**
     * @dev Validate payment amount doesn't cause overflow
     * @param scaledHypotenuse The hypotenuse value scaled to payment token decimals
     * @return payment The safe payment amount
     */
    function _validatePaymentAmount(uint256 scaledHypotenuse) internal view returns (uint256 payment) {
        payment = scaledHypotenuse;
        if (payment > _safeMul(MAX_HYPOTENUSE, paymentTokenDecimals)) {
            revert HypotenuseTooLarge();
        }
    }
    
    /**
     * @dev Safe multiplication that checks for overflow
     * @param a First number
     * @param b Second number
     * @return result The product of a and b
     */
    function _safeMul(uint256 a, uint256 b) private pure returns (uint256 result) {
        if (a == 0) return 0;
        result = a * b;
        if (result / a != b) revert PotentialOverflow();
    }
    
    /**
     * @dev Safe addition for squared values to prevent overflow
     * @param firstSquared First squared value
     * @param secondSquared Second squared value
     * @return sum The sum of the squared values
     */
    function _safeAddSquares(uint256 firstSquared, uint256 secondSquared) private pure returns (uint256 sum) {
        sum = firstSquared + secondSquared;
        if (sum < firstSquared || sum < secondSquared) revert PotentialOverflow();
    }
    
    /**
     * @dev Validate coordinate bounds
     * @param downvotes Downvotes coordinate
     * @param upvotes Upvotes coordinate
     */
    function _validateCoordinateBounds(uint256 downvotes, uint256 upvotes) private pure {
        if (downvotes > MAX_COORDINATE_VALUE || upvotes > MAX_COORDINATE_VALUE) {
            revert CoordinateTooLarge();
        }
    }
    
    /**
     * @dev Compute hypotenuse scaled to the payment token decimals (floor)
     */
    function _computeHypotenuseScaled(uint256 downvotes, uint256 upvotes) private view returns (uint256) {
        uint256 downvotesSquared = _safeMul(downvotes, downvotes);
        uint256 upvotesSquared = _safeMul(upvotes, upvotes);
        uint256 sumSquares = _safeAddSquares(downvotesSquared, upvotesSquared);
        uint256 d = paymentTokenDecimals;
        uint256 d2 = _safeMul(d, d);
        uint256 scaledSumSquares = _safeMul(sumSquares, d2);
        return Math.sqrt(scaledSumSquares);
    }
}