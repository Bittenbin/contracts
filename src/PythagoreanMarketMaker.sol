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
 * - Markets exist at (x, y) coordinates where x = distrust votes, y = trust votes
 * - Cost = sqrt(x² + y²) in TENBIN tokens (hypotenuse-based pricing)
 * - Each voter's contributions are tracked individually for fair selling
 * - Coordinates are globally unique across all markets
 * 
 * Fee Structure:
 * - Protocol fee: 100 basis points (1%) on all buy/sell transactions
 * - Fees accumulate in contract and can be distributed 50/50 to recipients
 * - Application fee: 10 TENBIN flat fee for market applications
 * 
 * Yield System:
 * - Annual yield rate = K / sqrt(totalMarkets) where K ≈ 1.329
 * - Yield accrues on cost basis (amount paid for votes)
 * - PMM must be set as TENBIN minter for yield claiming
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
    uint256 public constant MINIMUM_VOTES = 7;
    uint256 public constant MAX_COORDINATE_VALUE = 1e9;
    uint256 public constant MAX_HYPOTENUSE = 1.5e9;
    uint256 public constant DEFAULT_SLIPPAGE_BASIS_POINTS = 250;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    // K = 0.75 * sqrt(pi) in WAD (1e18)
    uint256 private constant K_WAD = 1329340388179137000; // ~1.329340388179137e18
    
    // Milestone thresholds
    uint256 public constant MILESTONE_1 = 100;
    uint256 public constant MILESTONE_2 = 1000;
    uint256 public constant MILESTONE_3 = 10000;
    uint256 public constant MILESTONE_4 = 100000;
    uint256 public constant MILESTONE_5 = 1000000;
    uint256 public constant MILESTONE_6 = 10000000;
    uint256 public constant MILESTONE_7 = 100000000;
    
    // State variables
    IERC20 public paymentToken;
    uint256 public paymentTokenDecimals;
    
    address public ownerFeeRecipient;
    address public protocolFeeRecipient;
    
    uint256 public accumulatedProtocolFees;
    uint256 public totalMarkets; // total entities created (approved or directly created)
    
    mapping(uint256 => Coordinate) public marketCoordinates;
    mapping(uint256 => bool) public marketExists;
    mapping(bytes32 => uint256) public coordinateToMarket;
    
    mapping(uint256 => address) public marketCreator;
    mapping(uint256 => uint256) public totalVoteVolume;
    mapping(uint256 => uint256) public highestMilestoneReached;
    
    mapping(uint256 => mapping(address => VoterPosition)) public voterPositions;
    
    struct Coordinate {
        uint256 x;
        uint256 y;
    }
    
    struct VoterPosition {
        uint256 trustVotes;
        uint256 distrustVotes;
        bool exists;
    }
    
    // Application struct and mapping
    struct Application {
        address applicant;
        uint256 timestamp;
    }
    mapping(uint256 => Application) public marketApplications;

    // Holding cost basis and yield accrual per platform per user
    struct HoldingCosts {
        uint256 trustCost;       // in payment token units
        uint256 distrustCost;    // in payment token units
        uint256 lastAccrual;     // timestamp of last accrual update
        uint256 unclaimedYield;  // accumulated yield in payment token units
    }
    mapping(uint256 => mapping(address => HoldingCosts)) public holdings;
    
    // Events
    event MarketCreated(
        uint256 indexed platformId,
        address indexed creator,
        uint256 x,
        uint256 y,
        uint256 cost
    );
    
    event MarketVoteUpdate(
        uint256 indexed platformId,
        address indexed voter,
        uint256 fromX,
        uint256 fromY,
        uint256 toX,
        uint256 toY,
        int256 voteDelta,
        uint256 protocolFee
    );
    
    event VoterPositionUpdate(
        uint256 indexed platformId,
        address indexed voter,
        uint256 trustVotes,
        uint256 distrustVotes,
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
    event MarketRebalanced(
        uint256 indexed platformId,
        address indexed voter,
        uint256 fromX,
        uint256 fromY,
        uint256 toX,
        uint256 toY,
        uint256 trustDelta,
        uint256 distrustDelta
    );
    
    event SlippageProtectionApplied(
        uint256 indexed platformId,
        address indexed voter,
        uint256 slippageBasisPoints,
        uint256 expectedAmount,
        uint256 maxAcceptableAmount,
        bool isBuy
    );
    
    event VoterFirstParticipation(
        uint256 indexed platformId,
        address indexed voter,
        uint256 timestamp
    );
    
    event CoordinateChanged(
        uint256 indexed platformId,
        bytes32 indexed oldCoordinateHash,
        bytes32 indexed newCoordinateHash,
        uint256 oldX,
        uint256 oldY,
        uint256 newX,
        uint256 newY
    );
    
    event LiquidityAdded(
        uint256 indexed platformId,
        uint256 amount,
        uint256 newContractBalance
    );
    
    event LiquidityRemoved(
        uint256 indexed platformId,
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
    
    event MarketMilestone(
        uint256 indexed platformId,
        uint256 totalVotes,
        uint256 milestone,
        uint256 timestamp
    );
    
    // Application workflow events
    event MarketApplicationSubmitted(
        uint256 indexed platformId,
        address indexed applicant,
        uint256 feePaid,
        uint256 timestamp
    );
    
    event MarketApplicationApproved(
        uint256 indexed platformId,
        address indexed approver,
        address indexed applicant
    );
    
    event MarketApplicationDenied(
        uint256 indexed platformId,
        address indexed approver,
        address indexed applicant
    );
    
    // Custom errors for gas-efficient reverts
    error InvalidCoordinate();
    error MarketAlreadyExists();
    error MarketDoesNotExist();
    error CoordinateOccupied();
    error InvalidAddress();
    error PaymentFailed();
    error RefundFailed();
    error BelowMinimumVotes();
    error MustStartOffGenesis();
    error InsufficientVotesToSell();
    error InvalidVoteAmount();
    error InvalidFeeAmount();
    error CoordinateTooLarge();
    error PotentialOverflow();
    error HypotenuseTooLarge();
    error SlippageExceeded();
    error InvalidSlippage();
    error MarketApplicationExists();
    error MarketApplicationNotFound();
    error MintingNotSupported();
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    /**
     * @dev Initializes the contract
     * @param _paymentToken Address of the ERC20 token used for payments (TENBIN)
     */
    function initialize(
        address _paymentToken
    ) public initializer {
        if (_paymentToken == address(0)) {
            revert InvalidAddress();
        }
        
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        
        paymentToken = IERC20(_paymentToken);
        
        ownerFeeRecipient = 0x2dfc776B09234f617DFc38Cb8De1BB2B0B7C4E5B;
        protocolFeeRecipient = 0xb322A547De3308C2426aEa700c8176574E57eEe6;
        
        paymentTokenDecimals = 10 ** IERC20Metadata(_paymentToken).decimals();
    }

    // ============================================================
    // YIELD SYSTEM
    // ============================================================

    /**
     * @notice Get the current annual yield rate in WAD format (1e18 = 100%)
     * @dev Rate = K / sqrt(totalMarkets) where K = 0.75 * sqrt(π) ≈ 1.329
     * @return Annual yield rate scaled by 1e18 (e.g., 1.329e18 = 132.9% APY)
     */
    function currentAnnualYieldWad() public view returns (uint256) {
        if (totalMarkets == 0) {
            return 0;
        }
        // rate = K / sqrt(n)
        uint256 sqrtNScaled = Math.sqrt(totalMarkets * 1e18); // 1e9 scale
        // K_WAD * 1e9 / sqrtNScaled gives WAD
        return (K_WAD * 1e9) / sqrtNScaled;
    }

    /**
     * @dev Internal function to accrue yield for a user on a specific platform
     * @param platformId The platform ID to accrue yield for
     * @param user The user address to accrue yield for
     */
    function _accrueYield(uint256 platformId, address user) internal {
        HoldingCosts storage h = holdings[platformId][user];
        uint256 last = h.lastAccrual;
        if (last == 0) {
            h.lastAccrual = block.timestamp;
            return;
        }
        if (block.timestamp <= last) {
            return;
        }
        uint256 base = h.trustCost + h.distrustCost; // token units
        if (base == 0) {
            h.lastAccrual = block.timestamp;
            return;
        }
        uint256 dt = block.timestamp - last;
        uint256 rateWad = currentAnnualYieldWad();
        if (rateWad == 0) {
            h.lastAccrual = block.timestamp;
            return;
        }
        // reward = base * rate * dt / YEAR
        uint256 reward = (base * rateWad / 1e18) * dt / SECONDS_PER_YEAR;
        h.unclaimedYield += reward;
        h.lastAccrual = block.timestamp;
    }

    /**
     * @notice Claim accumulated yield rewards for a specific platform
     * @dev Mints TENBIN tokens to caller. PMM must be set as TENBIN minter.
     * @param platformId The platform ID to claim yield from
     */
    function claimYield(uint256 platformId) external nonReentrant whenNotPaused {
        _accrueYield(platformId, msg.sender);
        HoldingCosts storage h = holdings[platformId][msg.sender];
        uint256 amount = h.unclaimedYield;
        if (amount == 0) {
            return;
        }
        h.unclaimedYield = 0;
        // Mint reward tokens to user (PMM must be set as minter on TENBIN)
        try IMintableERC20(address(paymentToken)).mint(msg.sender, amount) {
        } catch {
            revert MintingNotSupported();
        }
    }

    /**
     * @dev Creates a new market for a platform ID with initial votes
     * @param platformId Unique identifier for the platform entity
     * @param initialX Initial distrust votes
     * @param initialY Initial trust votes
     */
    function createMarket(
        uint256 platformId,
        uint256 initialX,
        uint256 initialY
    ) external whenNotPaused nonReentrant {
        // Use default slippage tolerance
        _createMarketWithSlippage(platformId, initialX, initialY, DEFAULT_SLIPPAGE_BASIS_POINTS);
    }
    
    /**
     * @dev Creates a new market with custom slippage tolerance
     * @param platformId Unique identifier for the platform entity
     * @param initialX Initial distrust votes
     * @param initialY Initial trust votes
     * @param slippageBasisPoints Maximum acceptable slippage in basis points
     */
    function createMarketWithSlippage(
        uint256 platformId,
        uint256 initialX,
        uint256 initialY,
        uint256 slippageBasisPoints
    ) external whenNotPaused nonReentrant {
        _createMarketWithSlippage(platformId, initialX, initialY, slippageBasisPoints);
    }
    
    /**
     * @dev Internal function to create market with slippage protection
     */
    function _createMarketWithSlippage(
        uint256 platformId,
        uint256 initialX,
        uint256 initialY,
        uint256 slippageBasisPoints
    ) internal {
        if (slippageBasisPoints > BASIS_POINTS_DENOMINATOR) {
            revert InvalidSlippage();
        }
        
        if (marketExists[platformId]) {
            revert MarketAlreadyExists();
        }
        
        _validateCoordinateBounds(initialX, initialY);
        
        uint256 totalVotes = initialX + initialY;
        if (totalVotes < MINIMUM_VOTES) {
            revert BelowMinimumVotes();
        }
        
        if (initialX == initialY) {
            revert MustStartOffGenesis();
        }
        
        if (!isValidCoordinate(initialX, initialY)) {
            revert InvalidCoordinate();
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
            platformId,
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
        
        marketCoordinates[platformId] = Coordinate(initialX, initialY);
        marketExists[platformId] = true;
        coordinateToMarket[coordHash] = platformId;
        marketCreator[platformId] = msg.sender;
        totalVoteVolume[platformId] = totalVotes;
        totalMarkets += 1;
        
        voterPositions[platformId][msg.sender] = VoterPosition({
            trustVotes: initialY,
            distrustVotes: initialX,
            exists: true
        });
        
        // Track cost basis for yield accrual (same decomposition as in voting)
        // trustCost = cost of going from (0,0) to (0, initialY)
        // distrustCost = cost of going from (0, initialY) to (initialX, initialY)
        uint256 trustCostPart = _computeHypotenuseScaled(0, initialY);
        uint256 distrustCostPart = initialHypotenuseScaled - trustCostPart;
        holdings[platformId][msg.sender] = HoldingCosts({
            trustCost: trustCostPart,
            distrustCost: distrustCostPart,
            lastAccrual: block.timestamp,
            unclaimedYield: 0
        });
        
        emit MarketCreated(platformId, msg.sender, initialX, initialY, totalVotes);
        // For event readability, include integer hypotenuse (floor) in the event payload
        emit VoterPositionUpdate(platformId, msg.sender, initialY, initialX, Math.sqrt(sumSquares));
        emit VoterFirstParticipation(platformId, msg.sender, block.timestamp);
        emit LiquidityAdded(platformId, totalPayment, paymentToken.balanceOf(address(this)));
        
        _checkAndEmitMilestone(platformId, totalVotes);
    }
    
    /**
     * @dev Apply to create a new market for a platform ID. Consumes a flat 10-token fee.
     * The fee is added to accumulated protocol fees regardless of approval outcome.
     */
    function applyForMarket(uint256 platformId) external whenNotPaused nonReentrant {
        if (marketExists[platformId]) {
            revert MarketAlreadyExists();
        }
        if (marketApplications[platformId].applicant != address(0)) {
            revert MarketApplicationExists();
        }
        
        uint256 applicationFee = 10 * paymentTokenDecimals;
        if (!paymentToken.transferFrom(msg.sender, address(this), applicationFee)) {
            revert PaymentFailed();
        }
        accumulatedProtocolFees += applicationFee;
        
        marketApplications[platformId] = Application({
            applicant: msg.sender,
            timestamp: block.timestamp
        });
        
        emit MarketApplicationSubmitted(platformId, msg.sender, applicationFee, block.timestamp);
    }
    
    /**
     * @dev Approve a pending market application. Initializes market with (0,0) coordinate.
     */
    function approveMarket(uint256 platformId) external onlyOwner {
        Application memory app = marketApplications[platformId];
        if (app.applicant == address(0)) {
            revert MarketApplicationNotFound();
        }
        if (marketExists[platformId]) {
            revert MarketAlreadyExists();
        }
        marketExists[platformId] = true;
        marketCoordinates[platformId] = Coordinate({x: 0, y: 0});
        marketCreator[platformId] = app.applicant;
        totalMarkets += 1;
        delete marketApplications[platformId];
        
        emit MarketApplicationApproved(platformId, msg.sender, app.applicant);
    }
    
    /**
     * @dev Deny a pending market application. Fee remains consumed.
     */
    function denyMarket(uint256 platformId) external onlyOwner {
        Application memory app = marketApplications[platformId];
        if (app.applicant == address(0)) {
            revert MarketApplicationNotFound();
        }
        delete marketApplications[platformId];
        emit MarketApplicationDenied(platformId, msg.sender, app.applicant);
    }
    
    /**
     * @dev Vote on an existing market by adjusting your position
     * @param platformId The platform ID to vote on
     * @param newX New distrust votes (for the entire market)
     * @param newY New trust votes (for the entire market)
     */
    function voteOnMarket(
        uint256 platformId,
        uint256 newX,
        uint256 newY
    ) external whenNotPaused nonReentrant {
        _voteOnMarketWithSlippage(platformId, newX, newY, DEFAULT_SLIPPAGE_BASIS_POINTS);
    }
    
    /**
     * @dev Vote on market with custom slippage tolerance
     * @param platformId The platform ID to vote on
     * @param newX New distrust votes (for the entire market)
     * @param newY New trust votes (for the entire market)
     * @param slippageBasisPoints Maximum acceptable slippage in basis points
     */
    function voteOnMarketWithSlippage(
        uint256 platformId,
        uint256 newX,
        uint256 newY,
        uint256 slippageBasisPoints
    ) external whenNotPaused nonReentrant {
        _voteOnMarketWithSlippage(platformId, newX, newY, slippageBasisPoints);
    }
    
    /**
     * @dev Internal function to vote with slippage protection
     */
    function _voteOnMarketWithSlippage(
        uint256 platformId,
        uint256 newX,
        uint256 newY,
        uint256 slippageBasisPoints
    ) internal {
        if (slippageBasisPoints > BASIS_POINTS_DENOMINATOR) {
            revert InvalidSlippage();
        }
        
        if (!marketExists[platformId]) {
            revert MarketDoesNotExist();
        }
        
        _validateCoordinateBounds(newX, newY);
        
        if (!isValidCoordinate(newX, newY)) {
            revert InvalidCoordinate();
        }
        
        bytes32 newCoordHash = keccak256(abi.encodePacked(newX, newY));
        uint256 occupyingMarket = coordinateToMarket[newCoordHash];
        if (occupyingMarket != 0 && occupyingMarket != platformId) {
            revert CoordinateOccupied();
        }
        
        _processVoteUpdate(platformId, newX, newY, newCoordHash, slippageBasisPoints);
    }
    
    /**
     * @dev Internal function to process vote updates with slippage protection
     */
    function _processVoteUpdate(
        uint256 platformId,
        uint256 newX,
        uint256 newY,
        bytes32 newCoordHash,
        uint256 slippageBasisPoints
    ) internal {
        Coordinate memory current = marketCoordinates[platformId];
        VoterPosition storage voterPos = voterPositions[platformId][msg.sender];
        
        bool isFirstTimeVoter = !voterPos.exists;
        
        int256 trustDelta = int256(newY) - int256(current.y);
        int256 distrustDelta = int256(newX) - int256(current.x);
        
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

        // Accrue yield on user's existing holdings for this platform before any change
        _accrueYield(platformId, msg.sender);
        
        if (hypotenuseChangeScaled > 0) {
            protocolFee = _processBuyVotesWithSlippage(
                platformId,
                uint256(hypotenuseChangeScaled),
                trustDelta,
                distrustDelta,
                voterPos,
                slippageBasisPoints
            );
            totalVoteVolume[platformId] += uint256(hypotenuseChangeScaled);
            // Update cost basis by decomposing cost into trust then distrust
            uint256 trustBuy = trustDelta > 0 ? uint256(trustDelta) : 0;
            uint256 distrustBuy = distrustDelta > 0 ? uint256(distrustDelta) : 0;
            if (trustBuy > 0) {
                uint256 trustPart = _computeHypotenuseScaled(current.x, current.y + trustBuy) - _computeHypotenuseScaled(current.x, current.y);
                holdings[platformId][msg.sender].trustCost += trustPart;
            }
            if (distrustBuy > 0) {
                uint256 distrustPart = _computeHypotenuseScaled(current.x + distrustBuy, current.y + trustBuy) - _computeHypotenuseScaled(current.x, current.y + trustBuy);
                holdings[platformId][msg.sender].distrustCost += distrustPart;
            }
            holdings[platformId][msg.sender].lastAccrual = block.timestamp;
        } else if (hypotenuseChangeScaled < 0) {
            // Before sell, compute previous holdings for pro-rata reduction
            uint256 prevTrust = voterPos.trustVotes;
            uint256 prevDistrust = voterPos.distrustVotes;
            uint256 trustSell = trustDelta < 0 ? uint256(-trustDelta) : 0;
            uint256 distrustSell = distrustDelta < 0 ? uint256(-distrustDelta) : 0;

            protocolFee = _processSellVotesWithSlippage(
                platformId,
                uint256(-hypotenuseChangeScaled),
                trustDelta,
                distrustDelta,
                voterPos,
                slippageBasisPoints
            );
            // Pro-rata reduce cost basis for sold units
            if (trustSell > 0 && prevTrust > 0) {
                HoldingCosts storage h = holdings[platformId][msg.sender];
                h.trustCost = h.trustCost * (prevTrust - trustSell) / prevTrust;
                h.lastAccrual = block.timestamp;
            }
            if (distrustSell > 0 && prevDistrust > 0) {
                HoldingCosts storage h2 = holdings[platformId][msg.sender];
                h2.distrustCost = h2.distrustCost * (prevDistrust - distrustSell) / prevDistrust;
                h2.lastAccrual = block.timestamp;
            }
        } else {
            _processRebalance(trustDelta, distrustDelta, voterPos);
            emit MarketRebalanced(
                platformId, 
                msg.sender, 
                current.x, 
                current.y, 
                newX, 
                newY, 
                trustDelta > 0 ? uint256(trustDelta) : 0,
                distrustDelta > 0 ? uint256(distrustDelta) : 0
            );
            // For rebalancing, do not change cost basis; only accrual was updated above
        }
        
        voterPos.exists = true;
        
        bytes32 oldCoordHash = keccak256(abi.encodePacked(current.x, current.y));
        delete coordinateToMarket[oldCoordHash];
        coordinateToMarket[newCoordHash] = platformId;
        
        marketCoordinates[platformId] = Coordinate(newX, newY);
        
        emit MarketVoteUpdate(
            platformId,
            msg.sender,
            current.x,
            current.y,
            newX,
            newY,
            int256(newHypotenuseInt) - int256(currentHypotenuseInt),
            protocolFee
        );
        
        emit VoterPositionUpdate(
            platformId, 
            msg.sender, 
            voterPos.trustVotes, 
            voterPos.distrustVotes, 
            newHypotenuseInt
        );
        
        emit CoordinateChanged(platformId, oldCoordHash, newCoordHash, current.x, current.y, newX, newY);
        
        if (isFirstTimeVoter) {
            emit VoterFirstParticipation(platformId, msg.sender, block.timestamp);
        }
        
        _checkAndEmitMilestone(platformId, marketCoordinates[platformId].x + marketCoordinates[platformId].y);
    }

    /**
     * @dev Process buying votes with slippage protection
     */
    function _processBuyVotesWithSlippage(
        uint256 platformId,
        uint256 hypotenuseIncrease,
        int256 trustDelta,
        int256 distrustDelta,
        VoterPosition storage voterPos,
        uint256 slippageBasisPoints
    ) internal returns (uint256 protocolFee) {
        uint256 payment = _validatePaymentAmount(hypotenuseIncrease);
        protocolFee = (payment * PROTOCOL_FEE_BASIS_POINTS) / BASIS_POINTS_DENOMINATOR;
        uint256 totalPayment = payment + protocolFee;
        
        uint256 maxAcceptablePayment = totalPayment + (totalPayment * slippageBasisPoints) / BASIS_POINTS_DENOMINATOR;
        
        emit SlippageProtectionApplied(
            platformId,
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
        
        if (trustDelta > 0) {
            voterPos.trustVotes += uint256(trustDelta);
        } else if (trustDelta < 0) {
            uint256 reductionAmount = uint256(-trustDelta);
            if (voterPos.trustVotes < reductionAmount) {
                revert InsufficientVotesToSell();
            }
            voterPos.trustVotes -= reductionAmount;
        }
        
        if (distrustDelta > 0) {
            voterPos.distrustVotes += uint256(distrustDelta);
        } else if (distrustDelta < 0) {
            uint256 reductionAmount = uint256(-distrustDelta);
            if (voterPos.distrustVotes < reductionAmount) {
                revert InsufficientVotesToSell();
            }
            voterPos.distrustVotes -= reductionAmount;
        }
        
        emit LiquidityAdded(platformId, totalPayment, paymentToken.balanceOf(address(this)));
    }
    
    /**
     * @dev Process selling votes with slippage protection
     */
    function _processSellVotesWithSlippage(
        uint256 platformId,
        uint256 hypotenuseDecrease,
        int256 trustDelta,
        int256 distrustDelta,
        VoterPosition storage voterPos,
        uint256 slippageBasisPoints
    ) internal returns (uint256 protocolFee) {
        if (trustDelta < 0) {
            uint256 sellAmount = uint256(-trustDelta);
            if (voterPos.trustVotes < sellAmount) {
                revert InsufficientVotesToSell();
            }
            voterPos.trustVotes -= sellAmount;
        } else if (trustDelta > 0) {
            voterPos.trustVotes += uint256(trustDelta);
        }
        
        if (distrustDelta < 0) {
            uint256 sellAmount = uint256(-distrustDelta);
            if (voterPos.distrustVotes < sellAmount) {
                revert InsufficientVotesToSell();
            }
            voterPos.distrustVotes -= sellAmount;
        } else if (distrustDelta > 0) {
            voterPos.distrustVotes += uint256(distrustDelta);
        }
        
        uint256 refundAmount = _validatePaymentAmount(hypotenuseDecrease);
        protocolFee = (refundAmount * PROTOCOL_FEE_BASIS_POINTS) / BASIS_POINTS_DENOMINATOR;
        uint256 netRefund = refundAmount - protocolFee;
        
        uint256 minAcceptableRefund = netRefund - (netRefund * slippageBasisPoints) / BASIS_POINTS_DENOMINATOR;
        
        emit SlippageProtectionApplied(
            platformId,
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
        
        emit LiquidityRemoved(platformId, netRefund, paymentToken.balanceOf(address(this)));
    }
    
    /**
     * @dev Process rebalancing (same hypotenuse)
     */
    function _processRebalance(
        int256 trustDelta,
        int256 distrustDelta,
        VoterPosition storage voterPos
    ) internal {
        if (trustDelta != 0 || distrustDelta != 0) {
            if (trustDelta < 0 && voterPos.trustVotes < uint256(-trustDelta)) {
                revert InsufficientVotesToSell();
            }
            if (distrustDelta < 0 && voterPos.distrustVotes < uint256(-distrustDelta)) {
                revert InsufficientVotesToSell();
            }
            
            if (trustDelta > 0) {
                voterPos.trustVotes += uint256(trustDelta);
            } else if (trustDelta < 0) {
                voterPos.trustVotes -= uint256(-trustDelta);
            }
            
            if (distrustDelta > 0) {
                voterPos.distrustVotes += uint256(distrustDelta);
            } else if (distrustDelta < 0) {
                voterPos.distrustVotes -= uint256(-distrustDelta);
            }
        }
    }
    
    /**
     * @dev Get voter's position in a market
     * @param platformId The platform ID
     * @param voter The voter's address
     * @return trustVotes Number of trust votes owned
     * @return distrustVotes Number of distrust votes owned
     * @return exists Whether voter has a position
     */
    function getVoterPosition(
        uint256 platformId,
        address voter
    ) external view returns (
        uint256 trustVotes,
        uint256 distrustVotes,
        bool exists
    ) {
        VoterPosition memory pos = voterPositions[platformId][voter];
        return (pos.trustVotes, pos.distrustVotes, pos.exists);
    }
    
    /**
     * @dev Get market state and trust score
     * @param platformId The platform ID to query
     * @return x Distrust votes
     * @return y Trust votes
     * @return trustScore Trust score (0 to 1e18)
     * @return totalVotes Total current votes
     */
    function getMarketState(uint256 platformId) 
        external 
        view 
        returns (
            uint256 x,
            uint256 y,
            uint256 trustScore,
            uint256 totalVotes
        ) 
    {
        if (!marketExists[platformId]) {
            return (0, 0, 0, 0);
        }
        
        Coordinate memory coord = marketCoordinates[platformId];
        x = coord.x;
        y = coord.y;
        totalVotes = x + y;
        trustScore = calculateTrustScore(x, y);
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
     * @dev Check if a market exists for a platform ID
     * @param platformId The platform ID to check
     * @return exists Whether the market exists
     */
    function marketExistsFor(uint256 platformId) external view returns (bool exists) {
        return marketExists[platformId];
    }
    
    /**
     * @dev Calculate trust score for given coordinates
     * @param x Distrust votes
     * @param y Trust votes
     * @return Trust score scaled by 1e18
     */
    function calculateTrustScore(uint256 x, uint256 y) public pure returns (uint256) {
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
     * @dev Check if coordinates are valid (positive, within bounds, hypotenuse within max)
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
     * @dev Required by UUPSUpgradeable
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
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
     * @param xSquared First squared value
     * @param ySquared Second squared value
     * @return sum The sum of the squared values
     */
    function _safeAddSquares(uint256 xSquared, uint256 ySquared) private pure returns (uint256 sum) {
        sum = xSquared + ySquared;
        if (sum < xSquared || sum < ySquared) revert PotentialOverflow();
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
    
    /**
     * @dev Check and emit milestone events
     * @param platformId The platform ID
     * @param totalVotes Current total votes
     */
    function _checkAndEmitMilestone(uint256 platformId, uint256 totalVotes) internal {
        uint256 highestReached = highestMilestoneReached[platformId];
        
        if (highestReached < MILESTONE_1 && totalVotes >= MILESTONE_1) {
            emit MarketMilestone(platformId, totalVotes, MILESTONE_1, block.timestamp);
            highestMilestoneReached[platformId] = MILESTONE_1;
            highestReached = MILESTONE_1;
        }
        if (highestReached < MILESTONE_2 && totalVotes >= MILESTONE_2) {
            emit MarketMilestone(platformId, totalVotes, MILESTONE_2, block.timestamp);
            highestMilestoneReached[platformId] = MILESTONE_2;
            highestReached = MILESTONE_2;
        }
        if (highestReached < MILESTONE_3 && totalVotes >= MILESTONE_3) {
            emit MarketMilestone(platformId, totalVotes, MILESTONE_3, block.timestamp);
            highestMilestoneReached[platformId] = MILESTONE_3;
            highestReached = MILESTONE_3;
        }
        if (highestReached < MILESTONE_4 && totalVotes >= MILESTONE_4) {
            emit MarketMilestone(platformId, totalVotes, MILESTONE_4, block.timestamp);
            highestMilestoneReached[platformId] = MILESTONE_4;
            highestReached = MILESTONE_4;
        }
        if (highestReached < MILESTONE_5 && totalVotes >= MILESTONE_5) {
            emit MarketMilestone(platformId, totalVotes, MILESTONE_5, block.timestamp);
            highestMilestoneReached[platformId] = MILESTONE_5;
            highestReached = MILESTONE_5;
        }
        if (highestReached < MILESTONE_6 && totalVotes >= MILESTONE_6) {
            emit MarketMilestone(platformId, totalVotes, MILESTONE_6, block.timestamp);
            highestMilestoneReached[platformId] = MILESTONE_6;
            highestReached = MILESTONE_6;
        }
        if (highestReached < MILESTONE_7 && totalVotes >= MILESTONE_7) {
            emit MarketMilestone(platformId, totalVotes, MILESTONE_7, block.timestamp);
            highestMilestoneReached[platformId] = MILESTONE_7;
        }
    }
}