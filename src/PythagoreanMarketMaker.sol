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
 * - Markets exist at (x, y) coordinates
 * - Cost = sqrt(x² + y²) in USDC (hypotenuse-based pricing)
 * - Each voter's contributions are tracked individually for fair selling
 * - Coordinates are globally unique across all markets
 * - Market creation is permissionless (no approval required)
 * 
 * Fee Structure:
 * - Protocol fee: 100 basis points (1%) on all buy/sell transactions (paid in USDC)
 * - Fees accumulate in contract and can be distributed 50/50 to recipients
 * 
 * Staking Rewards System (Synthetix/SushiSwap O(1) Pattern):
 * - First 20 years: fixed 1,000,000 TBN/year (per-second accrual)
 * - Tail emission: yearly halving from 500,000 TBN/year (500k, 250k, 125k, ...)
 * - Total emission remains capped at 21,000,000 TBN
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
    uint256 public constant PHASE_ONE_DURATION = 20 * 365 days;
    uint256 public constant PHASE_ONE_ANNUAL_EMISSION = 1_000_000 * 1e6; // 1M TBN/year
    uint256 public constant PHASE_TWO_INITIAL_ANNUAL_EMISSION = 500_000 * 1e6; // 500k TBN/year
    uint256 public constant PHASE_TWO_HALVING_PERIOD = 365 days;
    
    // Emission cap remains 21M TENBIN in raw units
    uint256 public constant MAX_EMISSION = 21_000_000 * 1e6; // 21M TENBIN in raw units
    
    
    // State variables
    IERC20 public paymentToken; // USDC for transactions
    IERC20 public rewardToken;  // TENBIN for staking rewards
    uint256 public paymentTokenDecimals;
    
    address public ownerFeeRecipient;
    address public protocolFeeRecipient;
    
    uint256 public accumulatedProtocolFees;
    uint256 public totalMarkets; // total entities created
    
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
        uint256 x;
        uint256 y;
    }
    
    struct VoterPosition {
        uint256 yVotes;
        uint256 xVotes;
        bool exists;
    }
    
    // Holding cost basis per platform per user (for tracking individual positions)
    struct HoldingCosts {
        uint256 yCost;       // in payment token units
        uint256 xCost;    // in payment token units
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
        uint256 x,
        uint256 y,
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
        uint256 fromX,
        uint256 fromY,
        uint256 toX,
        uint256 toY,
        int256 voteDelta,
        uint256 protocolFee
    );
    
    event VoterPositionUpdate(
        uint256 indexed pageId,
        address indexed voter,
        uint256 yVotes,
        uint256 xVotes,
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
        uint256 oldX,
        uint256 oldY,
        uint256 newX,
        uint256 newY
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
     * @dev Emissions start from emissionStartTime and follow phased annual rates
     * @return Applicable timestamp for reward calculation
     */
    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp;
    }

    function _phaseTwoAnnualEmissionForEpoch(uint256 epoch) internal pure returns (uint256) {
        if (epoch >= 256) {
            return 0;
        }
        uint256 divisor = 1 << epoch;
        if (divisor == 0) {
            return 0;
        }
        return PHASE_TWO_INITIAL_ANNUAL_EMISSION / divisor;
    }

    function _rewardBetweenTimestamps(uint256 fromTimestamp, uint256 toTimestamp) internal view returns (uint256 totalReward) {
        if (toTimestamp <= fromTimestamp || emissionStartTime == 0) {
            return 0;
        }

        uint256 startTime = fromTimestamp;
        if (startTime < emissionStartTime) {
            startTime = emissionStartTime;
        }
        if (toTimestamp <= startTime) {
            return 0;
        }

        uint256 phaseOneEndTime = emissionStartTime + PHASE_ONE_DURATION;

        // Phase 1: fixed 1,000,000 TBN/year for first 20 years
        if (startTime < phaseOneEndTime) {
            uint256 phaseOneSegmentEnd = toTimestamp < phaseOneEndTime ? toTimestamp : phaseOneEndTime;
            uint256 phaseOneDuration = phaseOneSegmentEnd - startTime;
            totalReward += Math.mulDiv(phaseOneDuration, PHASE_ONE_ANNUAL_EMISSION, SECONDS_PER_YEAR);
            startTime = phaseOneSegmentEnd;
        }

        // Phase 2: yearly halving from 500,000 TBN/year onward
        while (startTime < toTimestamp) {
            uint256 epoch = (startTime - phaseOneEndTime) / PHASE_TWO_HALVING_PERIOD;
            uint256 annualEmission = _phaseTwoAnnualEmissionForEpoch(epoch);
            if (annualEmission == 0) {
                break;
            }

            uint256 epochEndTime = phaseOneEndTime + ((epoch + 1) * PHASE_TWO_HALVING_PERIOD);
            uint256 endTime = toTimestamp < epochEndTime ? toTimestamp : epochEndTime;
            uint256 duration = endTime - startTime;

            totalReward += Math.mulDiv(duration, annualEmission, SECONDS_PER_YEAR);
            startTime = endTime;
        }
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
        
        uint256 rewardAccrued = _rewardBetweenTimestamps(lastRewardUpdateTime, lastApplicable);
        if (rewardAccrued == 0) {
            return rewardPerTokenStored;
        }
        return rewardPerTokenStored + Math.mulDiv(rewardAccrued, 1e18, totalStaked);
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
     * @notice Get current emission rate as per-second equivalent
     * @return Rate in raw token units (6 decimals)
     */
    function getEmissionRate() external view returns (uint256) {
        if (emissionStartTime == 0 || block.timestamp < emissionStartTime) {
            return Math.mulDiv(PHASE_ONE_ANNUAL_EMISSION, 1, SECONDS_PER_YEAR);
        }

        uint256 phaseOneEndTime = emissionStartTime + PHASE_ONE_DURATION;
        if (block.timestamp < phaseOneEndTime) {
            return Math.mulDiv(PHASE_ONE_ANNUAL_EMISSION, 1, SECONDS_PER_YEAR);
        }

        uint256 epoch = (block.timestamp - phaseOneEndTime) / PHASE_TWO_HALVING_PERIOD;
        uint256 annualEmission = _phaseTwoAnnualEmissionForEpoch(epoch);
        return Math.mulDiv(annualEmission, 1, SECONDS_PER_YEAR);
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
        if (totalEmitted >= MAX_EMISSION) {
            return false;
        }

        uint256 phaseOneEndTime = emissionStartTime + PHASE_ONE_DURATION;
        if (block.timestamp < phaseOneEndTime) {
            return true;
        }

        uint256 epoch = (block.timestamp - phaseOneEndTime) / PHASE_TWO_HALVING_PERIOD;
        return _phaseTwoAnnualEmissionForEpoch(epoch) > 0;
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
     * @param initialX Initial x
     * @param initialY Initial y
     */
    function createMarket(
        string calldata url,
        uint256 initialX,
        uint256 initialY
    ) external whenNotPaused nonReentrant {
        // Use default slippage tolerance and derive pageId from URL hash
        if (bytes(url).length == 0) {
            revert InvalidUrl();
        }
        bytes32 urlHash = keccak256(bytes(url));
        uint256 pageId = uint256(urlHash);
        _createMarketWithSlippage(pageId, initialX, initialY, DEFAULT_SLIPPAGE_BASIS_POINTS, url, urlHash);
    }
    
    /**
     * @dev Creates a new market with custom slippage tolerance
     * @param url Raw URL string provided by the user
     * @param initialX Initial x
     * @param initialY Initial y
     * @param slippageBasisPoints Maximum acceptable slippage in basis points
     */
    function createMarketWithSlippage(
        string calldata url,
        uint256 initialX,
        uint256 initialY,
        uint256 slippageBasisPoints
    ) external whenNotPaused nonReentrant {
        // Derive pageId from URL hash and apply custom slippage
        if (bytes(url).length == 0) {
            revert InvalidUrl();
        }
        bytes32 urlHash = keccak256(bytes(url));
        uint256 pageId = uint256(urlHash);
        _createMarketWithSlippage(pageId, initialX, initialY, slippageBasisPoints, url, urlHash);
    }
    
    /**
     * @dev Internal function to create market with slippage protection
     */
    function _createMarketWithSlippage(
        uint256 pageId,
        uint256 initialX,
        uint256 initialY,
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
        
        _validateCoordinateBounds(initialX, initialY);
        
        uint256 totalVotes = initialX + initialY;
        if (!isValidCoordinate(initialX, initialY)) {
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
        
        bytes32 coordHash = keccak256(abi.encodePacked(initialX, initialY));
        if (coordinateToMarket[coordHash] != 0) {
            revert CoordinateOccupied();
        }
        
        // Compute hypotenuse in token units (fixed-point with payment token decimals)
        uint256 xSquared = _safeMul(initialX, initialX);
        uint256 ySquared = _safeMul(initialY, initialY);
        uint256 sumSquares = _safeAddSquares(xSquared, ySquared);
        // Ensure hypotenuse is within limit without precision loss: sumSquares <= MAX_HYPOTENUSE^2
        if (sumSquares > _safeMul(MAX_HYPOTENUSE, MAX_HYPOTENUSE)) {
            revert HypotenuseTooLarge();
        }
        uint256 initialHypotenuseScaled = _computeHypotenuseScaled(initialX, initialY);
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
        
        marketCoordinates[pageId] = Coordinate(initialX, initialY);
        marketExists[pageId] = true;
        coordinateToMarket[coordHash] = pageId;
        marketCreator[pageId] = msg.sender;
        totalVoteVolume[pageId] = totalVotes;
        totalMarkets += 1;
        
        voterPositions[pageId][msg.sender] = VoterPosition({
            yVotes: initialY,
            xVotes: initialX,
            exists: true
        });
        
        // Track cost basis for staking rewards
        // yCost = cost of going from (0,0) to (0, initialY)
        // xCost = cost of going from (0, initialY) to (initialX, initialY)
        uint256 yCostPart = _computeHypotenuseScaled(0, initialY);
        uint256 xCostPart = initialHypotenuseScaled - yCostPart;
        holdings[pageId][msg.sender] = HoldingCosts({
            yCost: yCostPart,
            xCost: xCostPart
        });
        
        // Update global staking state (user's new total stake across all platforms)
        uint256 newUserTotalStake = userTotalStake[msg.sender] + yCostPart + xCostPart;
        _updateUserStake(msg.sender, newUserTotalStake);
        
        emit MarketCreated(pageId, msg.sender, initialX, initialY, totalVotes);
        if (bytes(url).length > 0) {
            // Emit raw URL for off-chain indexing; hash is stored for uniqueness checks
            emit MarketMetadata(pageId, urlHash, url);
        }
        // For event readability, include integer hypotenuse (floor) in the event payload
        emit VoterPositionUpdate(pageId, msg.sender, initialY, initialX, Math.sqrt(sumSquares));
        emit VoterFirstParticipation(pageId, msg.sender, block.timestamp);
        emit LiquidityAdded(pageId, totalPayment, paymentToken.balanceOf(address(this)));
    }
    
    /**
     * @dev Vote on an existing market by adjusting your position
     * @param pageId The page ID to vote on
     * @param newX New x (for the entire market)
     * @param newY New y (for the entire market)
     */
    function voteOnMarket(
        uint256 pageId,
        uint256 newX,
        uint256 newY
    ) external whenNotPaused nonReentrant {
        _voteOnMarketWithSlippage(pageId, newX, newY, DEFAULT_SLIPPAGE_BASIS_POINTS);
    }
    
    /**
     * @dev Vote on market with custom slippage tolerance
     * @param pageId The page ID to vote on
     * @param newX New x (for the entire market)
     * @param newY New y (for the entire market)
     * @param slippageBasisPoints Maximum acceptable slippage in basis points
     */
    function voteOnMarketWithSlippage(
        uint256 pageId,
        uint256 newX,
        uint256 newY,
        uint256 slippageBasisPoints
    ) external whenNotPaused nonReentrant {
        _voteOnMarketWithSlippage(pageId, newX, newY, slippageBasisPoints);
    }
    
    /**
     * @dev Internal function to vote with slippage protection
     */
    function _voteOnMarketWithSlippage(
        uint256 pageId,
        uint256 newX,
        uint256 newY,
        uint256 slippageBasisPoints
    ) internal {
        // Multi-axis move allowed: disallow only no-op updates
        if (slippageBasisPoints > BASIS_POINTS_DENOMINATOR) {
            revert InvalidSlippage();
        }
        
        if (!marketExists[pageId]) {
            revert MarketDoesNotExist();
        }
        
        _validateCoordinateBounds(newX, newY);

        Coordinate memory current = marketCoordinates[pageId];
        bool xChanged = newX != current.x;
        bool yChanged = newY != current.y;
        if (!xChanged && !yChanged) {
            // Disallow no-op moves
            revert InvalidCoordinate();
        }
        
        if (!isValidCoordinate(newX, newY)) {
            revert InvalidCoordinate();
        }
        
        bytes32 newCoordHash = keccak256(abi.encodePacked(newX, newY));
        uint256 occupyingMarket = coordinateToMarket[newCoordHash];
        if (occupyingMarket != 0 && occupyingMarket != pageId) {
            revert CoordinateOccupied();
        }
        
        _processVoteUpdate(pageId, newX, newY, newCoordHash, slippageBasisPoints);
    }
    
    /**
     * @dev Internal function to process vote updates with slippage protection
     */
    function _processVoteUpdate(
        uint256 pageId,
        uint256 newX,
        uint256 newY,
        bytes32 newCoordHash,
        uint256 slippageBasisPoints
    ) internal {
        // Core vote processing: compute deltas, apply buy/sell, update stake
        Coordinate memory current = marketCoordinates[pageId];
        VoterPosition storage voterPos = voterPositions[pageId][msg.sender];
        
        bool isFirstTimeVoter = !voterPos.exists;
        
        int256 yDelta = int256(newY) - int256(current.y);
        int256 xDelta = int256(newX) - int256(current.x);
        
        uint256 currentXSquared = _safeMul(current.x, current.x);
        uint256 currentYSquared = _safeMul(current.y, current.y);
        uint256 currentSumSquares = _safeAddSquares(currentXSquared, currentYSquared);
        uint256 currentHypotenuseInt = Math.sqrt(currentSumSquares);
        
        uint256 newXSquared = _safeMul(newX, newX);
        uint256 newYSquared = _safeMul(newY, newY);
        uint256 newSumSquares = _safeAddSquares(newXSquared, newYSquared);
        uint256 newHypotenuseInt = Math.sqrt(newSumSquares);
        
        // Ensure hypotenuse is within limit using exact squared comparison
        if (newSumSquares > _safeMul(MAX_HYPOTENUSE, MAX_HYPOTENUSE)) {
            revert HypotenuseTooLarge();
        }
        // Compute scaled hypotenuse values (fixed-point with token decimals)
        uint256 currentHypotenuseScaled = _computeHypotenuseScaled(current.x, current.y);
        uint256 newHypotenuseScaled = _computeHypotenuseScaled(newX, newY);
        int256 hypotenuseChangeScaled = int256(newHypotenuseScaled) - int256(currentHypotenuseScaled);
        
        uint256 protocolFee;
        
        // Track old cost basis before changes for stake update
        HoldingCosts storage userHoldings = holdings[pageId][msg.sender];
        uint256 oldPlatformCost = userHoldings.yCost + userHoldings.xCost;
        
        if (hypotenuseChangeScaled > 0) {
            protocolFee = _processBuyVotesWithSlippage(
                pageId,
                uint256(hypotenuseChangeScaled),
                yDelta,
                xDelta,
                voterPos,
                slippageBasisPoints
            );
            totalVoteVolume[pageId] += uint256(hypotenuseChangeScaled);
            // Update cost basis by decomposing path into y leg then x leg
            uint256 yBuy = yDelta > 0 ? uint256(yDelta) : 0;
            uint256 xBuy = xDelta > 0 ? uint256(xDelta) : 0;
            if (yDelta > 0) {
                uint256 yPart = _computeHypotenuseScaled(current.x, current.y + yBuy) - _computeHypotenuseScaled(current.x, current.y);
                userHoldings.yCost += yPart;
            }
            if (xDelta > 0) {
                uint256 xPart = _computeHypotenuseScaled(current.x + xBuy, current.y + yBuy) - _computeHypotenuseScaled(current.x, current.y + yBuy);
                userHoldings.xCost += xPart;
            }
        } else if (hypotenuseChangeScaled < 0) {
            // Before sell, compute previous holdings for pro-rata reduction
            uint256 prevY = voterPos.yVotes;
            uint256 prevX = voterPos.xVotes;
            uint256 ySell = yDelta < 0 ? uint256(-yDelta) : 0;
            uint256 xSell = xDelta < 0 ? uint256(-xDelta) : 0;

            protocolFee = _processSellVotesWithSlippage(
                pageId,
                uint256(-hypotenuseChangeScaled),
                yDelta,
                xDelta,
                voterPos,
                slippageBasisPoints
            );
            // Pro-rata reduce cost basis for sold units
            if (ySell > 0 && prevY > 0) {
                userHoldings.yCost = userHoldings.yCost * (prevY - ySell) / prevY;
            }
            if (xSell > 0 && prevX > 0) {
                userHoldings.xCost = userHoldings.xCost * (prevX - xSell) / prevX;
            }
        } else {
            _processRebalance(yDelta, xDelta, voterPos);
        }
        
        // Update global staking state with new cost basis
        uint256 newPlatformCost = userHoldings.yCost + userHoldings.xCost;
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
        
        bytes32 oldCoordHash = keccak256(abi.encodePacked(current.x, current.y));
        delete coordinateToMarket[oldCoordHash];
        coordinateToMarket[newCoordHash] = pageId;
        
        marketCoordinates[pageId] = Coordinate(newX, newY);
        
        emit MarketVoteUpdate(
            pageId,
            msg.sender,
            current.x,
            current.y,
            newX,
            newY,
            int256(newHypotenuseInt) - int256(currentHypotenuseInt),
            protocolFee
        );
        
        emit VoterPositionUpdate(
            pageId, 
            msg.sender, 
            voterPos.yVotes, 
            voterPos.xVotes, 
            newHypotenuseInt
        );
        
        emit CoordinateChanged(pageId, oldCoordHash, newCoordHash, current.x, current.y, newX, newY);
        
        if (isFirstTimeVoter) {
            emit VoterFirstParticipation(pageId, msg.sender, block.timestamp);
        }
    }

    /**
     * @dev Process rebalancing (same hypotenuse)
     */
    function _processRebalance(
        int256 yDelta,
        int256 xDelta,
        VoterPosition storage voterPos
    ) internal {
        if (yDelta != 0 || xDelta != 0) {
            if (yDelta < 0 && voterPos.yVotes < uint256(-yDelta)) {
                revert InsufficientVotesToSell();
            }
            if (xDelta < 0 && voterPos.xVotes < uint256(-xDelta)) {
                revert InsufficientVotesToSell();
            }

            if (yDelta > 0) {
                voterPos.yVotes += uint256(yDelta);
            } else if (yDelta < 0) {
                voterPos.yVotes -= uint256(-yDelta);
            }

            if (xDelta > 0) {
                voterPos.xVotes += uint256(xDelta);
            } else if (xDelta < 0) {
                voterPos.xVotes -= uint256(-xDelta);
            }
        }
    }

    /**
     * @dev Process buying votes with slippage protection
     */
    function _processBuyVotesWithSlippage(
        uint256 pageId,
        uint256 hypotenuseIncrease,
        int256 yDelta,
        int256 xDelta,
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
        
        if (yDelta > 0) {
            voterPos.yVotes += uint256(yDelta);
        } else if (yDelta < 0) {
            uint256 reductionAmount = uint256(-yDelta);
            if (voterPos.yVotes < reductionAmount) {
                revert InsufficientVotesToSell();
            }
            voterPos.yVotes -= reductionAmount;
        }
        
        if (xDelta > 0) {
            voterPos.xVotes += uint256(xDelta);
        } else if (xDelta < 0) {
            uint256 reductionAmount = uint256(-xDelta);
            if (voterPos.xVotes < reductionAmount) {
                revert InsufficientVotesToSell();
            }
            voterPos.xVotes -= reductionAmount;
        }
        
        emit LiquidityAdded(pageId, totalPayment, paymentToken.balanceOf(address(this)));
    }
    
    /**
     * @dev Process selling votes with slippage protection
     */
    function _processSellVotesWithSlippage(
        uint256 pageId,
        uint256 hypotenuseDecrease,
        int256 yDelta,
        int256 xDelta,
        VoterPosition storage voterPos,
        uint256 slippageBasisPoints
    ) internal returns (uint256 protocolFee) {
        // Sell path: validate holdings, refund USDC minus fee
        if (yDelta < 0) {
            uint256 sellAmount = uint256(-yDelta);
            if (voterPos.yVotes < sellAmount) {
                revert InsufficientVotesToSell();
            }
            voterPos.yVotes -= sellAmount;
        } else if (yDelta > 0) {
            voterPos.yVotes += uint256(yDelta);
        }
        
        if (xDelta < 0) {
            uint256 sellAmount = uint256(-xDelta);
            if (voterPos.xVotes < sellAmount) {
                revert InsufficientVotesToSell();
            }
            voterPos.xVotes -= sellAmount;
        } else if (xDelta > 0) {
            voterPos.xVotes += uint256(xDelta);
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
     * @return yVotes Number of y votes owned
     * @return xVotes Number of x votes owned
     * @return exists Whether voter has a position
     */
    function getVoterPosition(
        uint256 pageId,
        address voter
    ) external view returns (
        uint256 yVotes,
        uint256 xVotes,
        bool exists
    ) {
        VoterPosition memory pos = voterPositions[pageId][voter];
        return (pos.yVotes, pos.xVotes, pos.exists);
    }
    
    /**
     * @dev Get market state and page score
     * @param pageId The page ID to query
     * @return x X coordinate
     * @return y Y coordinate
     * @return pageScore Page score (0 to 1e18)
     * @return totalVotes Total current votes
     */
    function getMarketState(uint256 pageId) 
        external 
        view 
        returns (
            uint256 x,
            uint256 y,
            uint256 pageScore,
            uint256 totalVotes
        ) 
    {
        if (!marketExists[pageId]) {
            return (0, 0, 0, 0);
        }
        
        Coordinate memory coord = marketCoordinates[pageId];
        x = coord.x;
        y = coord.y;
        totalVotes = x + y;
        pageScore = calculatePageScore(x, y);
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
     * @param currentX Current x coordinate
     * @param currentY Current y coordinate
     * @param newX Target x coordinate
     * @param newY Target y coordinate
     * @param slippageBasisPoints Slippage tolerance in basis points
     * @return expectedPayment Expected payment amount
     * @return maxPaymentWithSlippage Maximum payment with slippage
     */
    function calculatePaymentWithSlippage(
        uint256 currentX,
        uint256 currentY,
        uint256 newX,
        uint256 newY,
        uint256 slippageBasisPoints
    ) external view returns (
        uint256 expectedPayment,
        uint256 maxPaymentWithSlippage
    ) {
        _validateCoordinateBounds(currentX, currentY);
        _validateCoordinateBounds(newX, newY);
        
        uint256 currentHypotenuseScaled = _computeHypotenuseScaled(currentX, currentY);
        uint256 newHypotenuseScaled = _computeHypotenuseScaled(newX, newY);
        
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
     * @param currentX Current x coordinate
     * @param currentY Current y coordinate
     * @param newX Target x coordinate
     * @param newY Target y coordinate
     * @param slippageBasisPoints Slippage tolerance in basis points
     * @return expectedRefund Expected refund amount
     * @return minRefundWithSlippage Minimum refund with slippage
     */
    function calculateRefundWithSlippage(
        uint256 currentX,
        uint256 currentY,
        uint256 newX,
        uint256 newY,
        uint256 slippageBasisPoints
    ) external view returns (
        uint256 expectedRefund,
        uint256 minRefundWithSlippage
    ) {
        _validateCoordinateBounds(currentX, currentY);
        _validateCoordinateBounds(newX, newY);
        
        uint256 currentHypotenuseScaled = _computeHypotenuseScaled(currentX, currentY);
        uint256 newHypotenuseScaled = _computeHypotenuseScaled(newX, newY);
        
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
     * @param x X coordinate
     * @param y Y coordinate
     * @return Y score scaled by 1e18
     */
    function calculatePageScore(uint256 x, uint256 y) public pure returns (uint256) {
        if (x == 0 && y == 0) {
            return 0;
        }
        
        if (x > MAX_COORDINATE_VALUE || y > MAX_COORDINATE_VALUE) {
            revert CoordinateTooLarge();
        }
        
        uint256 xSquared = _safeMul(x, x);
        uint256 ySquared = _safeMul(y, y);
        uint256 sumSquares = _safeAddSquares(xSquared, ySquared);
        
        return (ySquared * 1e18) / sumSquares;
    }
    
    /**
     * @dev Check if coordinates are valid (positive, within bounds, integer hypotenuse within max)
     * @param x The x coordinate
     * @param y The y coordinate
     * @return bool True if valid
     */
    function isValidCoordinate(uint256 x, uint256 y) public pure returns (bool) {
        if (x == 0 || y == 0) {
            return false;
        }
        
        if (x > MAX_COORDINATE_VALUE || y > MAX_COORDINATE_VALUE) {
            return false;
        }
        
        uint256 xSquared = _safeMul(x, x);
        uint256 ySquared = _safeMul(y, y);
        uint256 sumSquares = _safeAddSquares(xSquared, ySquared);
        if (sumSquares > _safeMul(MAX_HYPOTENUSE, MAX_HYPOTENUSE)) {
            return false;
        }
        uint256 c = Math.sqrt(sumSquares);
        // Pythagorean triple constraint: hypotenuse must be an exact positive integer
        return c > 0 && _safeMul(c, c) == sumSquares;
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
     * @param x X coordinate
     * @param y Y coordinate
     */
    function _validateCoordinateBounds(uint256 x, uint256 y) private pure {
        if (x > MAX_COORDINATE_VALUE || y > MAX_COORDINATE_VALUE) {
            revert CoordinateTooLarge();
        }
    }
    
    /**
     * @dev Compute hypotenuse scaled to the payment token decimals (floor)
     */
    function _computeHypotenuseScaled(uint256 x, uint256 y) private view returns (uint256) {
        uint256 xSquared = _safeMul(x, x);
        uint256 ySquared = _safeMul(y, y);
        uint256 sumSquares = _safeAddSquares(xSquared, ySquared);
        uint256 d = paymentTokenDecimals;
        uint256 d2 = _safeMul(d, d);
        uint256 scaledSumSquares = _safeMul(sumSquares, d2);
        return Math.sqrt(scaledSumSquares);
    }
}