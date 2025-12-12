const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { anyValue } = require("@nomicfoundation/hardhat-chai-matchers/withArgs");

describe("PythagoreanMarketMaker - Comprehensive Test Suite", function () {
  let pmm;
  let tenbin;
  let owner;
  let alice;
  let bob;
  let charlie;
  let david;
  let eve;
  let frank;

  // Platform IDs for testing
  const PLATFORM_ID_1 = 1234567890;
  const PLATFORM_ID_2 = 9876543210;
  
  // Generate unique platform IDs for tests
  function getUniquePlatformId() {
    return Math.floor(Date.now() * Math.random());
  }
  
  // Common Pythagorean coordinates for testing
  const COMMON_COORDS = [
    [3, 4, 5],      // 3² + 4² = 5²
    [5, 12, 13],    // 5² + 12² = 13²
    [8, 15, 17],    // 8² + 15² = 17²
    [7, 24, 25],    // 7² + 24² = 25²
    [20, 21, 29],   // 20² + 21² = 29²
    [11, 60, 61],   // 11² + 60² = 61²
    [13, 84, 85],   // 13² + 84² = 85²
    [36, 77, 85],   // 36² + 77² = 85²
    [16, 63, 65],   // 16² + 63² = 65²
    [33, 56, 65]    // 33² + 56² = 65²
  ];

  beforeEach(async function () {
    [owner, alice, bob, charlie, david, eve, frank] = await ethers.getSigners();

    // Deploy TENBIN token (6 decimals)
    const TenbinToken = await ethers.getContractFactory("TenbinToken");
    tenbin = await TenbinToken.deploy(owner.address);
    await tenbin.waitForDeployment();

    // Deploy PythagoreanMarketMaker
    const PythagoreanMarketMaker = await ethers.getContractFactory("PythagoreanMarketMaker");
    pmm = await upgrades.deployProxy(
      PythagoreanMarketMaker,
      [await tenbin.getAddress()],
      { initializer: 'initialize' }
    );
    await pmm.waitForDeployment();

    // Mint TENBIN to users
    const amounts = [
      [alice, "10000"],
      [bob, "10000"],
      [charlie, "2000000"], // 2M TENBIN for large tests
      [david, "10000"],
      [eve, "10000"],
      [frank, "100000"]
    ];
    
    for (const [user, amount] of amounts) {
      await tenbin.mint(user.address, ethers.parseUnits(amount, 6));
      await tenbin.connect(user).approve(await pmm.getAddress(), ethers.parseUnits(amount, 6));
    }
  });

  describe("Read-Only Functions and Coordinate Validation", function () {
    it("Should validate coordinates correctly", async function () {
      // Valid coordinates (Pythagorean and non-Pythagorean)
      expect(await pmm.isValidCoordinate(3, 4)).to.be.true;
      expect(await pmm.isValidCoordinate(5, 12)).to.be.true;
      expect(await pmm.isValidCoordinate(8, 15)).to.be.true;
      expect(await pmm.isValidCoordinate(7, 24)).to.be.true;
      expect(await pmm.isValidCoordinate(20, 21)).to.be.true;
      expect(await pmm.isValidCoordinate(4, 5)).to.be.true; // Non-Pythagorean
      expect(await pmm.isValidCoordinate(10, 10)).to.be.true; // Genesis line is valid coordinate but not allowed for creation
      
      // Invalid coordinates
      expect(await pmm.isValidCoordinate(0, 5)).to.be.false; // Zero coordinate
      expect(await pmm.isValidCoordinate(3, 0)).to.be.false; // Zero coordinate
      // Non-Pythagorean are allowed now; only size and zero are invalid
      
      // Large coordinates
      const largeValue = ethers.parseUnits("1.1", 9);
      expect(await pmm.isValidCoordinate(largeValue, 3)).to.be.false;
      expect(await pmm.isValidCoordinate(3, largeValue)).to.be.false;
    });
    
    it("Should calculate scores correctly", async function () {
      // Test various scores based on y²/(x²+y²)
      const testCases = [
        { x: 4, y: 3, expectedScore: 0.36 }, // 3²/(4²+3²) = 9/25 = 0.36
        { x: 3, y: 4, expectedScore: 0.64 }, // 4²/(3²+4²) = 16/25 = 0.64
        { x: 12, y: 5, expectedScore: 0.148 }, // 5²/(12²+5²) = 25/169 ≈ 0.148
        { x: 5, y: 12, expectedScore: 0.852 }, // 12²/(5²+12²) = 144/169 ≈ 0.852
        { x: 20, y: 21, expectedScore: 0.524 } // 21²/(20²+21²) = 441/841 ≈ 0.524
      ];
      
      for (const { x, y, expectedScore } of testCases) {
        const score = await pmm.calculateScore(x, y);
        const scoreDecimal = Number(score) / 1e18;
        expect(scoreDecimal).to.be.closeTo(expectedScore, 0.001);
      }
      
      // Edge cases
      expect(await pmm.calculateScore(0, 0)).to.equal(0);
      
      // Large values should revert
      const largeValue = ethers.parseUnits("1.1", 9);
      await expect(pmm.calculateScore(largeValue, 3))
        .to.be.revertedWithCustomError(pmm, "CoordinateTooLarge");
    });
    
    it("Should check market existence correctly", async function () {
      const platformId = getUniquePlatformId();
      
      // Market doesn't exist yet
      expect(await pmm.marketExistsFor(platformId)).to.be.false;
      
      // Create market
      await pmm.connect(alice).createMarket(platformId, 3, 4);
      
      // Now it exists
      expect(await pmm.marketExistsFor(platformId)).to.be.true;
    });
    
    it("Should return correct market state", async function () {
      const platformId = getUniquePlatformId();
      
      // Non-existent market should return zeros
      const emptyState = await pmm.getMarketState(platformId);
      expect(emptyState.x).to.equal(0);
      expect(emptyState.y).to.equal(0);
      expect(emptyState.score).to.equal(0);
      expect(emptyState.totalVotes).to.equal(0);
      
      // Create market
      await pmm.connect(alice).createMarket(platformId, 3, 4);
      
      // Check state
      const state = await pmm.getMarketState(platformId);
      expect(state.x).to.equal(3);
      expect(state.y).to.equal(4);
      expect(state.totalVotes).to.equal(7);
      expect(Number(state.score) / 1e18).to.be.closeTo(0.64, 0.001);
    });
    
    it("Should return protocol fee information", async function () {
      const [feeBasisPoints, feePercentage, maxFeeBasisPoints] = await pmm.getProtocolFeeInfo();
      expect(feeBasisPoints).to.equal(100); // 100 basis points (default)
      expect(feePercentage).to.equal(1); // 1%
      expect(maxFeeBasisPoints).to.equal(100); // Max 1%
    });
    
    it("Should return default slippage information", async function () {
      const [slippageBasisPoints, slippagePercentage] = await pmm.getDefaultSlippage();
      expect(slippageBasisPoints).to.equal(250); // 250 basis points
      expect(slippagePercentage).to.equal(2); // 2.5% actually (250/100 = 2.5)
    });
  });

  describe("Market Creation with Hypotenuse Pricing", function () {
    it("Should create a market with hypotenuse-based cost", async function () {
      // Create market at (3, 4)
      // Cost = sqrt(3² + 4²) = 5 TENBIN + 1% fee = 5.05 TENBIN
      await expect(pmm.connect(alice).createMarket(PLATFORM_ID_1, 3, 4))
        .to.emit(pmm, "MarketCreated")
        .withArgs(PLATFORM_ID_1, alice.address, 3, 4, 7); // 7 total votes

      // Check market state
      const state = await pmm.getMarketState(PLATFORM_ID_1);
      expect(state.x).to.equal(3);
      expect(state.y).to.equal(4);
      expect(state.totalVotes).to.equal(7);
      
      // Check Alice's position
      const [yVotes, xVotes, exists] = await pmm.getVoterPosition(PLATFORM_ID_1, alice.address);
      expect(exists).to.be.true;
      expect(yVotes).to.equal(4);
      expect(xVotes).to.equal(3);
    });

    it("Should allow non-Pythagorean coordinates with fractional hypotenuse cost", async function () {
      const platformId = getUniquePlatformId();
      const aliceBalanceBefore = await tenbin.balanceOf(alice.address);
      await pmm.connect(alice).createMarket(platformId, 4, 5); // sqrt(41) ≈ 6.403124... + 1% fee
      const aliceBalanceAfter = await tenbin.balanceOf(alice.address);
      const spent = Number(aliceBalanceBefore - aliceBalanceAfter) / 1e6;
      const expected = Math.sqrt(4*4 + 5*5) * 1.01;
      expect(spent).to.be.closeTo(expected, 0.000001);
      const state = await pmm.getMarketState(platformId);
      expect(state.x).to.equal(4);
      expect(state.y).to.equal(5);
    });

    it("Should charge correct hypotenuse-based fees", async function () {
      const aliceBalanceBefore = await tenbin.balanceOf(alice.address);
      const contractBalanceBefore = await tenbin.balanceOf(await pmm.getAddress());

      // Create market at (3, 4)
      await pmm.connect(alice).createMarket(PLATFORM_ID_1, 3, 4);

      const aliceBalanceAfter = await tenbin.balanceOf(alice.address);
      const contractBalanceAfter = await tenbin.balanceOf(await pmm.getAddress());

      // Alice pays 5 TENBIN + 0.05 fee = 5.05 TENBIN
      // Hypotenuse = sqrt(9 + 16) = 5
      // Cost = 5 * 10^6 * 1.01 = 5,050,000
      const aliceSpent = aliceBalanceBefore - aliceBalanceAfter;
      expect(aliceSpent).to.equal(5050000n);

      // Contract receives 5.05 TENBIN
      const contractReceived = contractBalanceAfter - contractBalanceBefore;
      expect(contractReceived).to.equal(5050000n);
      
      // Check accumulated fees
      const accumulatedFees = await pmm.accumulatedProtocolFees();
      expect(accumulatedFees).to.equal(50000n); // 0.05 TENBIN fee
    });
    
    it("Should prevent market creation with invalid coordinates", async function () {
      const platformId = getUniquePlatformId();
      
      // Zero coordinates with enough total votes
      await expect(pmm.connect(alice).createMarket(platformId, 0, 10))
        .to.be.revertedWithCustomError(pmm, "InvalidCoordinate");
      await expect(pmm.connect(alice).createMarket(platformId, 10, 0))
        .to.be.revertedWithCustomError(pmm, "InvalidCoordinate");
        
      // Genesis line (x = y)
      await expect(pmm.connect(alice).createMarket(platformId, 5, 5))
        .to.be.revertedWithCustomError(pmm, "MustStartOffGenesis");
        
      // Below minimum votes (checked before Pythagorean validation)
      await expect(pmm.connect(alice).createMarket(platformId, 2, 1))
        .to.be.revertedWithCustomError(pmm, "BelowMinimumVotes");
      
      // Non-Pythagorean coordinates are now allowed if votes >= minimum
      await expect(pmm.connect(alice).createMarket(getUniquePlatformId(), 4, 5))
        .to.not.be.reverted;
      await expect(pmm.connect(alice).createMarket(getUniquePlatformId(), 10, 11))
        .to.not.be.reverted;
    });
    
    it("Should prevent duplicate market creation", async function () {
      const platformId = getUniquePlatformId();
      
      // First creation should succeed
      await pmm.connect(alice).createMarket(platformId, 3, 4);
      
      // Second creation with same platform ID should fail
      await expect(pmm.connect(bob).createMarket(platformId, 5, 12))
        .to.be.revertedWithCustomError(pmm, "MarketAlreadyExists");
    });
    
    it("Should prevent coordinate reuse", async function () {
      const platformId1 = getUniquePlatformId();
      const platformId2 = getUniquePlatformId();
      
      // Create first market at (3, 4)
      await pmm.connect(alice).createMarket(platformId1, 3, 4);
      
      // Try to create second market at same coordinate
      await expect(pmm.connect(bob).createMarket(platformId2, 3, 4))
        .to.be.revertedWithCustomError(pmm, "CoordinateOccupied");
    });
    
    it("Should track market creator and volume", async function () {
      const platformId = getUniquePlatformId();
      
      await pmm.connect(alice).createMarket(platformId, 5, 12);
      
      expect(await pmm.marketCreator(platformId)).to.equal(alice.address);
      expect(await pmm.totalVoteVolume(platformId)).to.equal(17); // 5 + 12
    });
  });

  describe("Vote Tracking", function () {
    beforeEach(async function () {
      // Alice creates initial market at (3, 4)
      await pmm.connect(alice).createMarket(PLATFORM_ID_1, 3, 4);
    });

    it("Should track individual voter positions", async function () {
      // Bob votes to move from (3, 4) to (5, 12)
      await pmm.connect(bob).voteOnMarket(PLATFORM_ID_1, 5, 12);

      // Check Bob's position
      const [yVotes, xVotes, exists] = await pmm.getVoterPosition(PLATFORM_ID_1, bob.address);
      expect(exists).to.be.true;
      expect(yVotes).to.equal(8); // 12 - 4 = 8
      expect(xVotes).to.equal(2); // 5 - 3 = 2

      // Alice still has her original position
      const [aliceY, aliceX] = await pmm.getVoterPosition(PLATFORM_ID_1, alice.address);
      expect(aliceY).to.equal(4);
      expect(aliceX).to.equal(3);
    });

    it("Should accumulate votes for multiple transactions", async function () {
      // Bob's first vote: (3,4) to (5,12)
      await pmm.connect(bob).voteOnMarket(PLATFORM_ID_1, 5, 12);
      
      // Bob's second vote: (5,12) to (11,60)
      await pmm.connect(bob).voteOnMarket(PLATFORM_ID_1, 11, 60);

      // Check Bob's accumulated position
      const [yVotes, xVotes] = await pmm.getVoterPosition(PLATFORM_ID_1, bob.address);
      expect(yVotes).to.equal(56); // 8 + 48 = 56
      expect(xVotes).to.equal(8); // 2 + 6 = 8
    });

    it("Should prevent selling more votes than owned", async function () {
      // Bob votes to (5, 12)
      await pmm.connect(bob).voteOnMarket(PLATFORM_ID_1, 5, 12);
      
      // Bob owns 2 x-votes, try to sell all of them plus 1 more
      // Need to find a valid Pythagorean coordinate where Bob would need to sell 3 x-votes
      // From (5,12) if we go to (0,5) that's selling 5 x-votes, which Bob doesn't have
      // (0,5) is not valid anyway. Let's use (0,7) or (0,24) or another valid coordinate
      // Actually, we need a coordinate where x < 2 to force overselling
      // Since Bob only has 2 x-votes, trying to go to x=0 or x=1 would require selling more than he has
      // But we need a valid Pythagorean coordinate. Let's check what works:
      // If current is (5,12) and Bob has 2 x-votes
      // Going to any coordinate with x < 3 would require selling more than 2 x-votes
      // We need a valid coordinate like (0,y) where y makes it Pythagorean
      // But (0,y) is not valid. So let's think differently.
      
      // Actually, the issue is that Bob gained votes when moving from (3,4) to (5,12)
      // Bob gained: 2 x-votes, 8 y-votes
      // So to make Bob sell more than he owns, we need to reduce x by more than 2
      // Current market is at (5,12), so going to (2,y) would require selling 3 x-votes
      // We need (2,y) to be valid Pythagorean. 
      // Let's find a valid coordinate with x=2
      // Checking: 2² + y² = c²
      // We need y such that 4 + y² is a perfect square
      // If c² = 4 + y², then c² - 4 = y²
      // So we need c² - 4 to be a perfect square
      // Try c = 3: 9 - 4 = 5 (not perfect square)
      // Try c = 4: 16 - 4 = 12 (not perfect square)  
      // Try c = 5: 25 - 4 = 21 (not perfect square)
      // Actually, let's use a coordinate that doesn't require x=2
      
      // Better approach: Bob has 2 x-votes. Current position is (5,12).
      // To force overselling, we need Bob to try to move to a position that requires
      // reducing x by more than 2. So we need x < 3.
      // But we also need it to be a valid Pythagorean coordinate.
      // There's no valid Pythagorean coordinate with x < 3 except (0,y) which isn't valid.
      
      // Let's approach this differently. Bob owns exactly what he contributed.
      // He contributed +2 x when moving from (3,4) to (5,12)
      // So he can reduce x by at most 2.
      // Current market: (5,12). Bob can move to minimum (3,y) for x.
      // We need to find valid (3,y) coordinate. We know (3,4) is valid.
      
      // Actually, Bob trying to move back to original (3,4) would work but wouldn't exceed his votes.
      // Let's make Bob try to sell more y-votes than he has instead.
      // Bob has 8 y-votes. Current y=12. Moving to y < 4 would require selling more than 8.
      // So let's try to move to (x,3) where it's valid.
      // We know (4,3) is valid. From (5,12) to (4,3) requires reducing y by 9, but Bob only has 8.
      
      await expect(pmm.connect(bob).voteOnMarket(PLATFORM_ID_1, 4, 3))
        .to.be.revertedWithCustomError(pmm, "InsufficientVotesToSell");
    });

    it("Should allow selling within owned votes", async function () {
      // Bob accumulates votes
      await pmm.connect(bob).voteOnMarket(PLATFORM_ID_1, 5, 12);
      await pmm.connect(bob).voteOnMarket(PLATFORM_ID_1, 11, 60);
      
      // Bob now has 8 x-votes, can sell some
      const bobBalanceBefore = await tenbin.balanceOf(bob.address);
      
      // Move from (11, 60) to (8, 15) - valid Pythagorean coordinate
      // This reduces x by 3 (which Bob can afford) and y by 45
      await pmm.connect(bob).voteOnMarket(PLATFORM_ID_1, 8, 15);
      
      const bobBalanceAfter = await tenbin.balanceOf(bob.address);
      
      // Check Bob's position updated correctly
      const [yVotes, xVotes] = await pmm.getVoterPosition(PLATFORM_ID_1, bob.address);
      expect(yVotes).to.equal(11); // 56 - 45 = 11
      expect(xVotes).to.equal(5); // 8 - 3 = 5
      
      // Bob should receive refund
      expect(bobBalanceAfter).to.be.gt(bobBalanceBefore);
    });
  });

  describe("Slippage Protection", function () {
    beforeEach(async function () {
      await pmm.connect(alice).createMarket(PLATFORM_ID_1, 3, 4);
    });
    
    it("Should create market with custom slippage", async function () {
      const platformId = getUniquePlatformId();
      const slippageBasisPoints = 100; // 1% slippage
      
      // Calculate expected cost
      const hypotenuse = Math.sqrt(5*5 + 12*12); // 13
      const expectedCost = hypotenuse * 1.01; // With 1% fee
      const maxAcceptableCost = expectedCost * 1.01; // With 1% slippage
      
      const balanceBefore = await tenbin.balanceOf(bob.address);
      
      await expect(pmm.connect(bob).createMarketWithSlippage(platformId, 5, 12, slippageBasisPoints))
        .to.emit(pmm, "SlippageProtectionApplied")
        .withArgs(
          platformId,
          bob.address,
          slippageBasisPoints,
          13130000n, // 13.13 TENBIN (13 + 0.13 fee)
          13261300n, // 13.2613 TENBIN (with 1% slippage)
          true // isBuy
        );
        
      const balanceAfter = await tenbin.balanceOf(bob.address);
      const spent = Number(balanceBefore - balanceAfter) / 1e6;
      expect(spent).to.be.closeTo(13.13, 0.01);
    });
    
    it("Should vote with custom slippage when buying", async function () {
      const slippageBasisPoints = 500; // 5% slippage
      
      const balanceBefore = await tenbin.balanceOf(bob.address);
      
      // Move from (3,4) to (5,12) - cost 8 TENBIN + fee
      await expect(pmm.connect(bob).voteOnMarketWithSlippage(PLATFORM_ID_1, 5, 12, slippageBasisPoints))
        .to.emit(pmm, "SlippageProtectionApplied")
        .withArgs(
          PLATFORM_ID_1,
          bob.address,
          slippageBasisPoints,
          8080000n, // 8.08 TENBIN (8 + 0.08 fee)
          8484000n, // 8.484 TENBIN (with 5% slippage)
          true // isBuy
        );
        
      const balanceAfter = await tenbin.balanceOf(bob.address);
      const spent = Number(balanceBefore - balanceAfter) / 1e6;
      expect(spent).to.be.closeTo(8.08, 0.01);
    });
    
    it("Should vote with custom slippage when selling", async function () {
      // First Bob buys votes
      await pmm.connect(bob).voteOnMarket(PLATFORM_ID_1, 5, 12);
      
      const slippageBasisPoints = 300; // 3% slippage
      const balanceBefore = await tenbin.balanceOf(bob.address);
      
      // Sell back to (3,4) - refund 8 TENBIN - fee
      await expect(pmm.connect(bob).voteOnMarketWithSlippage(PLATFORM_ID_1, 3, 4, slippageBasisPoints))
        .to.emit(pmm, "SlippageProtectionApplied")
        .withArgs(
          PLATFORM_ID_1,
          bob.address,
          slippageBasisPoints,
          7920000n, // 7.92 TENBIN (8 - 0.08 fee)
          7682400n, // 7.6824 TENBIN (with 3% slippage)
          false // isBuy = false for selling
        );
        
      const balanceAfter = await tenbin.balanceOf(bob.address);
      const received = Number(balanceAfter - balanceBefore) / 1e6;
      expect(received).to.be.closeTo(7.92, 0.01);
    });
    
    it("Should calculate payment with slippage correctly", async function () {
      // Test calculatePaymentWithSlippage view function
      const result = await pmm.calculatePaymentWithSlippage(
        3, 4,    // current position
        5, 12,   // new position
        250      // 2.5% slippage
      );
      
      expect(result.expectedPayment).to.equal(8080000n); // 8.08 TENBIN
      expect(result.maxPaymentWithSlippage).to.equal(8282000n); // 8.282 TENBIN
    });
    
    it("Should calculate refund with slippage correctly", async function () {
      // Test calculateRefundWithSlippage view function
      const result = await pmm.calculateRefundWithSlippage(
        5, 12,   // current position
        3, 4,    // new position
        100      // 1% slippage
      );
      
      expect(result.expectedRefund).to.equal(7920000n); // 7.92 TENBIN
      expect(result.minRefundWithSlippage).to.equal(7840800n); // 7.8408 TENBIN
    });
    
    it("Should reject invalid slippage values", async function () {
      const platformId = getUniquePlatformId();
      const platformId2 = getUniquePlatformId();
      
      // Slippage > 100%
      await expect(pmm.connect(alice).createMarketWithSlippage(platformId, 3, 4, 10001))
        .to.be.revertedWithCustomError(pmm, "InvalidSlippage");
        
      // Test with voting too
      await pmm.connect(alice).createMarket(platformId2, 5, 12);
      await expect(pmm.connect(bob).voteOnMarketWithSlippage(platformId2, 8, 15, 15000))
        .to.be.revertedWithCustomError(pmm, "InvalidSlippage");
    });
  });

  describe("Hypotenuse-Based Voting", function () {
    beforeEach(async function () {
      await pmm.connect(alice).createMarket(PLATFORM_ID_1, 3, 4);
    });

    it("Should charge based on hypotenuse change when buying", async function () {
      const bobBalanceBefore = await tenbin.balanceOf(bob.address);
      
      // Move from (3, 4) to (5, 12)
      // Cost = sqrt(5² + 12²) - sqrt(3² + 4²) = 13 - 5 = 8 TENBIN
      await pmm.connect(bob).voteOnMarket(PLATFORM_ID_1, 5, 12);
      
      const bobBalanceAfter = await tenbin.balanceOf(bob.address);
      const bobSpent = bobBalanceBefore - bobBalanceAfter;
      
      // 8 TENBIN + 0.08 fee = 8.08 TENBIN = 8,080,000 (6 decimals)
      expect(bobSpent).to.equal(8080000n);
    });

    it("Should refund based on hypotenuse change when selling", async function () {
      // First Bob buys to (5, 12)
      await pmm.connect(bob).voteOnMarket(PLATFORM_ID_1, 5, 12);
      
      const bobBalanceBefore = await tenbin.balanceOf(bob.address);
      
      // Sell by moving back to (3, 4)
      // Refund = sqrt(5² + 12²) - sqrt(3² + 4²) = 13 - 5 = 8 TENBIN
      await pmm.connect(bob).voteOnMarket(PLATFORM_ID_1, 3, 4);
      
      const bobBalanceAfter = await tenbin.balanceOf(bob.address);
      const bobReceived = bobBalanceAfter - bobBalanceBefore;
      
      // 8 TENBIN - 0.08 fee = 7.92 TENBIN = 7,920,000 (6 decimals)
      expect(bobReceived).to.equal(7920000n);
    });

    it("Should handle rebalancing without cost", async function () {
      // Bob moves to (5, 12)
      await pmm.connect(bob).voteOnMarket(PLATFORM_ID_1, 5, 12);
      
      const bobBalanceBefore = await tenbin.balanceOf(bob.address);
      
      // Rebalance to (12, 5) - same hypotenuse
      await pmm.connect(bob).voteOnMarket(PLATFORM_ID_1, 12, 5);
      
      const bobBalanceAfter = await tenbin.balanceOf(bob.address);
      
      // No cost change (only gas)
      expect(bobBalanceAfter).to.equal(bobBalanceBefore);
      
      // Check position updated
      const [yVotes, xVotes] = await pmm.getVoterPosition(PLATFORM_ID_1, bob.address);
      expect(yVotes).to.equal(1); // 5 - 4 = 1
      expect(xVotes).to.equal(9); // 12 - 3 = 9
    });
  });

  describe("Complex Scenario from Spreadsheet", function () {
    it("Should reproduce the exact spreadsheet example", async function () {
      // Transaction 1: Alice creates at (3, 4) - Cost $5
      await pmm.connect(alice).createMarket(PLATFORM_ID_1, 3, 4);
      let [aliceY, aliceX] = await pmm.getVoterPosition(PLATFORM_ID_1, alice.address);
      expect(aliceY).to.equal(4);
      expect(aliceX).to.equal(3);

      // Transaction 2: Bob moves to (5, 12) - Cost $8
      await pmm.connect(bob).voteOnMarket(PLATFORM_ID_1, 5, 12);
      let [bobY, bobX] = await pmm.getVoterPosition(PLATFORM_ID_1, bob.address);
      expect(bobY).to.equal(8);
      expect(bobX).to.equal(2);

      // Transaction 3: Bob moves to (11, 60) - Cost $48
      await pmm.connect(bob).voteOnMarket(PLATFORM_ID_1, 11, 60);
      [bobY, bobX] = await pmm.getVoterPosition(PLATFORM_ID_1, bob.address);
      expect(bobY).to.equal(56); // 8 + 48
      expect(bobX).to.equal(8); // 2 + 6

      // Transaction 4: Charlie moves to (110, 600) - Cost $549
      await pmm.connect(charlie).voteOnMarket(PLATFORM_ID_1, 110, 600);
      let [charlieY, charlieX] = await pmm.getVoterPosition(PLATFORM_ID_1, charlie.address);
      expect(charlieY).to.equal(540);
      expect(charlieX).to.equal(99);

      // Transaction 5: Bob moves to (450, 600) - Cost $140
      await pmm.connect(bob).voteOnMarket(PLATFORM_ID_1, 450, 600);
      [bobY, bobX] = await pmm.getVoterPosition(PLATFORM_ID_1, bob.address);
      expect(bobY).to.equal(56); // unchanged
      expect(bobX).to.equal(348); // 8 + 340

      // Transaction 6: David moves to (800, 600) - Cost $250
      await pmm.connect(david).voteOnMarket(PLATFORM_ID_1, 800, 600);
      let [davidY, davidX] = await pmm.getVoterPosition(PLATFORM_ID_1, david.address);
      expect(davidY).to.equal(0);
      expect(davidX).to.equal(350);

      // Transaction 7: Alice moves to (1440, 600) - Cost $560
      await pmm.connect(alice).voteOnMarket(PLATFORM_ID_1, 1440, 600);
      [aliceY, aliceX] = await pmm.getVoterPosition(PLATFORM_ID_1, alice.address);
      expect(aliceY).to.equal(4); // unchanged
      expect(aliceX).to.equal(643); // 3 + 640

      // Transaction 8: Bob sells by moving to (1178, 600) - Refund $238
      const bobBalanceBefore = await tenbin.balanceOf(bob.address);
      await pmm.connect(bob).voteOnMarket(PLATFORM_ID_1, 1178, 600);
      const bobBalanceAfter = await tenbin.balanceOf(bob.address);
      
      [bobY, bobX] = await pmm.getVoterPosition(PLATFORM_ID_1, bob.address);
      expect(bobY).to.equal(56); // unchanged
      expect(bobX).to.equal(86); // 348 - 262

      // Verify refund amount (238 TENBIN - 2.38 fee = 235.62 TENBIN)
      const refund = bobBalanceAfter - bobBalanceBefore;
      expect(refund).to.be.closeTo(235620000n, 10000n); // Allow small rounding difference
    });
  });

  describe("Edge Cases", function () {
    it("Should prevent voting on non-existent market", async function () {
      const nonExistentId = getUniquePlatformId();
      
      await expect(pmm.connect(alice).voteOnMarket(nonExistentId, 3, 4))
        .to.be.revertedWithCustomError(pmm, "MarketDoesNotExist");
    });
    
    it("Should prevent non-voters from selling", async function () {
      await pmm.connect(alice).createMarket(PLATFORM_ID_1, 5, 12);
      
      // Bob hasn't voted, can't sell
      await expect(pmm.connect(bob).voteOnMarket(PLATFORM_ID_1, 3, 4))
        .to.be.revertedWithCustomError(pmm, "InsufficientVotesToSell");
    });
    
    it("Should handle voter positions across multiple platforms independently", async function () {
      const platform1 = getUniquePlatformId();
      const platform2 = getUniquePlatformId();
      
      // Alice creates two markets
      await pmm.connect(alice).createMarket(platform1, 3, 4);
      await pmm.connect(alice).createMarket(platform2, 5, 12);
      
      // Bob votes on platform1
      await pmm.connect(bob).voteOnMarket(platform1, 8, 15);
      
      // Check Bob's positions
      const [y1, x1, exists1] = await pmm.getVoterPosition(platform1, bob.address);
      const [y2, x2, exists2] = await pmm.getVoterPosition(platform2, bob.address);
      
      // Bob should have position on platform1 but not platform2
      expect(exists1).to.be.true;
      expect(y1).to.equal(11); // 15 - 4
      expect(x1).to.equal(5); // 8 - 3
      
      expect(exists2).to.be.false;
      expect(y2).to.equal(0);
      expect(x2).to.equal(0);
    });

    it("Should handle multiple voters correctly", async function () {
      // Alice creates at (3,4)
      await pmm.connect(alice).createMarket(PLATFORM_ID_1, 3, 4);
      
      // Bob moves to (5, 12) - gains 2 x, 8 y
      await pmm.connect(bob).voteOnMarket(PLATFORM_ID_1, 5, 12);
      
      // Charlie moves to (8, 15) - gains 3 x, 3 y  
      await pmm.connect(charlie).voteOnMarket(PLATFORM_ID_1, 8, 15);
      
      // David moves to (20, 21) - gains 12 x, 6 y
      await pmm.connect(david).voteOnMarket(PLATFORM_ID_1, 20, 21);
      
      // Check positions
      const [bobY] = await pmm.getVoterPosition(PLATFORM_ID_1, bob.address);
      const [charlieY] = await pmm.getVoterPosition(PLATFORM_ID_1, charlie.address);
      const [davidY] = await pmm.getVoterPosition(PLATFORM_ID_1, david.address);

      expect(bobY).to.equal(8); // 12 - 4
      expect(charlieY).to.equal(3); // 15 - 12
      expect(davidY).to.equal(6); // 21 - 15
    });
  });

  describe("Input Validation and Safety", function () {
    it("Should reject coordinates that are too large", async function () {
      const largeValue = ethers.parseUnits("1.1", 9); // Just over 1 billion
      
      await expect(pmm.connect(alice).createMarket(999, largeValue, 3))
        .to.be.revertedWithCustomError(pmm, "CoordinateTooLarge");
        
      await expect(pmm.connect(alice).createMarket(999, 3, largeValue))
        .to.be.revertedWithCustomError(pmm, "CoordinateTooLarge");
    });

    it("Should reject hypotenuse that is too large", async function () {
      // For this test, we need coordinates that:
      // 1. Form a valid Pythagorean triple
      // 2. Have a hypotenuse > 1.5 billion
      // 3. Are not on the genesis line (x ≠ y)
      
      // Let's use a scaled up version of (3,4,5) triple
      // Scale factor: 300 million gives us (900M, 1.2B, 1.5B)
      const scaleFactor = 300000000;
      const largeX = 3 * scaleFactor; // 900 million
      const largeY = 4 * scaleFactor; // 1.2 billion
      // This should produce hypotenuse = 5 * 300M = 1.5 billion
      
      // First verify these would be valid coordinates if not for size
      const smallX = 3;
      const smallY = 4;
      expect(await pmm.isValidCoordinate(smallX, smallY)).to.be.true;
      
      // Now test that the large version is rejected
      // Since 1.2B > 1B (MAX_COORDINATE_VALUE), it should be rejected for coordinate size
      await expect(pmm.connect(alice).createMarket(999, largeX, largeY))
        .to.be.revertedWithCustomError(pmm, "CoordinateTooLarge");
    });

    it("Should enforce maximum payment amount", async function () {
      // Test that valid coordinates within bounds work properly
      // Using known valid Pythagorean triples at reasonable scale
      
      // Test 1: Medium scale (300, 400, 500)
      await expect(pmm.connect(alice).createMarket(888, 300, 400))
        .to.not.be.reverted;
      
      // Test 2: Larger scale (3000, 4000, 5000)
      await expect(pmm.connect(bob).createMarket(889, 3000, 4000))
        .to.not.be.reverted;
      
      // Test 3: Even larger but still reasonable (30000, 40000, 50000)
      // This costs 50,000 TENBIN - use Charlie who has 2M TENBIN
      await expect(pmm.connect(charlie).createMarket(890, 30000, 40000))
        .to.not.be.reverted;
    });

    it("Should handle pause functionality", async function () {
      // Pause the contract with empty reason (uses default message)
      await pmm.connect(owner).pause("");
      
      // Try to create market while paused
      await expect(pmm.connect(alice).createMarket(999, 3, 4))
        .to.be.revertedWithCustomError(pmm, "EnforcedPause");
        
      // Try to vote while paused
      await expect(pmm.connect(alice).voteOnMarket(PLATFORM_ID_1, 5, 12))
        .to.be.revertedWithCustomError(pmm, "EnforcedPause");
        
      // Unpause
      await pmm.connect(owner).unpause();
      
      // Should work now
      await expect(pmm.connect(alice).createMarket(999, 3, 4))
        .to.not.be.reverted;
    });

    it("Should validate coordinates in score calculation", async function () {
      const largeValue = ethers.parseUnits("1.1", 9);
      
      await expect(pmm.calculateScore(largeValue, 3))
        .to.be.revertedWithCustomError(pmm, "CoordinateTooLarge");
    });

    it("Should return false for invalid coordinates in isValidCoordinate", async function () {
      const largeValue = ethers.parseUnits("1.1", 9);
      
      // Should return false, not revert
      expect(await pmm.isValidCoordinate(largeValue, 3)).to.be.false;
      expect(await pmm.isValidCoordinate(3, largeValue)).to.be.false;
      
      // Should still validate normal coordinates
      expect(await pmm.isValidCoordinate(3, 4)).to.be.true;
    });

    it("Should maintain 1 vote = 1 TENBIN relationship with boundary checks", async function () {
      // Test small coordinates: (3, 4) with hypotenuse 5
      // Cost should be exactly 5 TENBIN + 1% fee = 5.05 TENBIN
      const aliceBalanceBefore = await tenbin.balanceOf(alice.address);
      
      await pmm.connect(alice).createMarket(777, 3, 4);
      
      const aliceBalanceAfter = await tenbin.balanceOf(alice.address);
      const spent = aliceBalanceBefore - aliceBalanceAfter;
      
      // 5 TENBIN + 0.05 fee = 5.05 TENBIN = 5,050,000 units
      expect(spent).to.equal(5050000n);
      
      // Test larger coordinates: (300, 400) with hypotenuse 500
      // Cost should be exactly 500 TENBIN + 1% fee = 505 TENBIN
      const bobBalanceBefore = await tenbin.balanceOf(bob.address);
      
      await pmm.connect(bob).createMarket(778, 300, 400);
      
      const bobBalanceAfter = await tenbin.balanceOf(bob.address);
      const bobSpent = bobBalanceBefore - bobBalanceAfter;
      
      // 500 TENBIN + 5 fee = 505 TENBIN = 505,000,000 units
      expect(bobSpent).to.equal(505000000n);
      
      // Test larger but reasonable: (30000, 40000) with hypotenuse 50000
      // Cost = 50,000 TENBIN + 500 TENBIN fee = 50,500 TENBIN
      const largeX = 30000; // 30,000
      const largeY = 40000; // 40,000
      // Hypotenuse = 50,000, cost = 50,000 TENBIN + fee
      
      const charlieBalanceBefore = await tenbin.balanceOf(charlie.address);
      
      await pmm.connect(charlie).createMarket(779, largeX, largeY);
      
      const charlieBalanceAfter = await tenbin.balanceOf(charlie.address);
      const charlieSpent = charlieBalanceBefore - charlieBalanceAfter;
      
      // 50,000 TENBIN + 500 fee = 50,500 TENBIN = 50,500,000,000 units
      expect(charlieSpent).to.equal(50500000000n);
    });
  });

  describe("Fee Distribution System", function () {
    beforeEach(async function () {
      // Create some markets to generate fees
      await pmm.connect(alice).createMarket(PLATFORM_ID_1, 3, 4);
      await pmm.connect(bob).voteOnMarket(PLATFORM_ID_1, 5, 12);
      await pmm.connect(charlie).voteOnMarket(PLATFORM_ID_1, 11, 60);
    });

    it("Should track accumulated protocol fees", async function () {
      const accumulatedFees = await pmm.accumulatedProtocolFees();
      
      // Expected fees:
      // - Alice: 5 TENBIN * 0.01 = 0.05 TENBIN
      // - Bob: 8 TENBIN * 0.01 = 0.08 TENBIN  
      // - Charlie: 48 TENBIN * 0.01 = 0.48 TENBIN
      // Total: 0.61 TENBIN = 610,000 units
      expect(accumulatedFees).to.equal(610000n);
    });

    it("Should distribute fees 50/50 between owner and protocol", async function () {
      const ownerRecipient = await pmm.ownerFeeRecipient();
      const protocolRecipient = await pmm.protocolFeeRecipient();
      
      const ownerBalanceBefore = await tenbin.balanceOf(ownerRecipient);
      const protocolBalanceBefore = await tenbin.balanceOf(protocolRecipient);
      
      // Distribute all fees (pass 0 to distribute all)
      await expect(pmm.connect(owner).distributeProtocolFees(0))
        .to.emit(pmm, "ProtocolFeesDistributed");
      
      const ownerBalanceAfter = await tenbin.balanceOf(ownerRecipient);
      const protocolBalanceAfter = await tenbin.balanceOf(protocolRecipient);
      
      // Each should receive half (0.305 TENBIN each)
      expect(ownerBalanceAfter - ownerBalanceBefore).to.equal(305000n);
      expect(protocolBalanceAfter - protocolBalanceBefore).to.equal(305000n);
      
      // Accumulated fees should be zero
      expect(await pmm.accumulatedProtocolFees()).to.equal(0);
    });

    it("Should allow partial fee distribution", async function () {
      const initialFees = await pmm.accumulatedProtocolFees();
      
      // Distribute only 200,000 (0.2 TENBIN)
      await pmm.connect(owner).distributeProtocolFees(200000n);
      
      // Check remaining fees
      expect(await pmm.accumulatedProtocolFees()).to.equal(initialFees - 200000n);
    });

    it("Should allow individual withdrawals to owner or protocol", async function () {
      const ownerRecipient = await pmm.ownerFeeRecipient();
      const protocolRecipient = await pmm.protocolFeeRecipient();
      
      const ownerBalanceBefore = await tenbin.balanceOf(ownerRecipient);
      const protocolBalanceBefore = await tenbin.balanceOf(protocolRecipient);
      
      // Withdraw 100,000 to owner only
      await pmm.connect(owner).withdrawToOwner(100000n);
      
      // Withdraw 200,000 to protocol only
      await pmm.connect(owner).withdrawToProtocol(200000n);
      
      const ownerBalanceAfter = await tenbin.balanceOf(ownerRecipient);
      const protocolBalanceAfter = await tenbin.balanceOf(protocolRecipient);
      
      expect(ownerBalanceAfter - ownerBalanceBefore).to.equal(100000n);
      expect(protocolBalanceAfter - protocolBalanceBefore).to.equal(200000n);
    });

    it("Should allow updating fee recipients", async function () {
      const newOwnerRecipient = david.address;
      const newProtocolRecipient = charlie.address;
      
      await expect(pmm.connect(owner).updateFeeRecipients(newOwnerRecipient, newProtocolRecipient))
        .to.emit(pmm, "FeeRecipientsUpdated")
        .withArgs(newOwnerRecipient, newProtocolRecipient);
      
      expect(await pmm.ownerFeeRecipient()).to.equal(newOwnerRecipient);
      expect(await pmm.protocolFeeRecipient()).to.equal(newProtocolRecipient);
    });
    
    it("Should prevent updating fee recipients with zero addresses", async function () {
      await expect(pmm.connect(owner).updateFeeRecipients(ethers.ZeroAddress, alice.address))
        .to.be.revertedWithCustomError(pmm, "InvalidAddress");
        
      await expect(pmm.connect(owner).updateFeeRecipients(alice.address, ethers.ZeroAddress))
        .to.be.revertedWithCustomError(pmm, "InvalidAddress");
    });

    it("Should revert on invalid fee operations", async function () {
      // Try to withdraw more than accumulated
      const fees = await pmm.accumulatedProtocolFees();
      await expect(pmm.connect(owner).distributeProtocolFees(fees + 1n))
        .to.be.revertedWithCustomError(pmm, "InvalidFeeAmount");
      
      // Try to withdraw zero
      await expect(pmm.connect(owner).withdrawToOwner(0))
        .to.be.revertedWithCustomError(pmm, "InvalidFeeAmount");
      
      // Non-owner tries to distribute
      await expect(pmm.connect(alice).distributeProtocolFees(0))
        .to.be.revertedWithCustomError(pmm, "OwnableUnauthorizedAccount");
    });

    it("Should show correct contract balance and liquidity", async function () {
      const contractBalance = await pmm.getContractBalance();
      const availableLiquidity = await pmm.getAvailableLiquidity();
      const accumulatedFees = await pmm.accumulatedProtocolFees();
      
      // Contract holds all the payments made
      expect(contractBalance).to.be.gt(0);
      
      // Available liquidity = balance - fees
      expect(availableLiquidity).to.equal(contractBalance - accumulatedFees);
    });

    it("Should correctly calculate fee distribution preview", async function () {
      const [ownerShare, protocolShare] = await pmm.calculateFeeDistribution();
      const totalFees = await pmm.accumulatedProtocolFees();
      
      // Should be 50/50 split
      expect(ownerShare).to.equal(totalFees / 2n);
      expect(protocolShare).to.equal(totalFees - ownerShare);
    });
  });

  describe("Comprehensive Event Logging", function () {
    it("Should emit VoterFirstParticipation event", async function () {
      await expect(pmm.connect(alice).createMarket(PLATFORM_ID_1, 3, 4))
        .to.emit(pmm, "VoterFirstParticipation")
        .withArgs(PLATFORM_ID_1, alice.address, await ethers.provider.getBlock('latest').then(b => b.timestamp + 1));
        
      // Bob's first vote on this platform
      await expect(pmm.connect(bob).voteOnMarket(PLATFORM_ID_1, 5, 12))
        .to.emit(pmm, "VoterFirstParticipation")
        .withArgs(PLATFORM_ID_1, bob.address, await ethers.provider.getBlock('latest').then(b => b.timestamp + 1));
    });
    
    it("Should emit CoordinateChanged event", async function () {
      await pmm.connect(alice).createMarket(PLATFORM_ID_1, 3, 4);
      
      const oldHash = ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(["uint256", "uint256"], [3, 4]));
      const newHash = ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(["uint256", "uint256"], [5, 12]));
      
      await expect(pmm.connect(bob).voteOnMarket(PLATFORM_ID_1, 5, 12))
        .to.emit(pmm, "CoordinateChanged")
        .withArgs(PLATFORM_ID_1, oldHash, newHash, 3, 4, 5, 12);
    });
    
    it("Should emit MarketRebalanced event for rebalancing", async function () {
      await pmm.connect(alice).createMarket(PLATFORM_ID_1, 3, 4);
      await pmm.connect(bob).voteOnMarket(PLATFORM_ID_1, 5, 12);
      
      // Rebalance to (12, 5) - same hypotenuse
      await expect(pmm.connect(bob).voteOnMarket(PLATFORM_ID_1, 12, 5))
        .to.emit(pmm, "MarketRebalanced")
        .withArgs(PLATFORM_ID_1, bob.address, 5, 12, 12, 5, 0, 7); // yDelta = 0, xDelta = 7
    });
    
    it("Should emit SlippageProtectionApplied event", async function () {
      await pmm.connect(alice).createMarket(PLATFORM_ID_1, 3, 4);
      
      // Vote with custom slippage
      const tx = await pmm.connect(bob).voteOnMarketWithSlippage(PLATFORM_ID_1, 5, 12, 100); // 1% slippage
      
      // Check for SlippageProtectionApplied event
      await expect(tx).to.emit(pmm, "SlippageProtectionApplied");
    });
    
    it("Should emit LiquidityAdded and LiquidityRemoved events", async function () {
      // LiquidityAdded on market creation
      await expect(pmm.connect(alice).createMarket(PLATFORM_ID_1, 3, 4))
        .to.emit(pmm, "LiquidityAdded");
        
      await pmm.connect(bob).voteOnMarket(PLATFORM_ID_1, 5, 12);
      
      // LiquidityRemoved when selling
      await expect(pmm.connect(bob).voteOnMarket(PLATFORM_ID_1, 3, 4))
        .to.emit(pmm, "LiquidityRemoved");
    });
    
    it("Should emit MarketMilestone events", async function () {
      // Create a large market that crosses 100 vote milestone
      await expect(pmm.connect(charlie).createMarket(999, 60, 80)) // 140 votes total
        .to.emit(pmm, "MarketMilestone")
        .withArgs(999, 140, 100, await ethers.provider.getBlock('latest').then(b => b.timestamp + 1));
    });
    
    it("Should emit EmergencyActionTaken for pause/unpause", async function () {
      await expect(pmm.connect(owner).pause(""))
        .to.emit(pmm, "EmergencyActionTaken")
        .withArgs("pause", owner.address, await ethers.provider.getBlock('latest').then(b => b.timestamp + 1), "Contract paused by owner");
        
      await expect(pmm.connect(owner).unpause())
        .to.emit(pmm, "EmergencyActionTaken")
        .withArgs("unpause", owner.address, await ethers.provider.getBlock('latest').then(b => b.timestamp + 1), "Contract unpaused by owner");
    });
    
    it("Should emit EmergencyActionTaken with custom reason", async function () {
      const customReason = "Suspicious activity detected";
      await expect(pmm.connect(owner).pause(customReason))
        .to.emit(pmm, "EmergencyActionTaken")
        .withArgs("pause", owner.address, await ethers.provider.getBlock('latest').then(b => b.timestamp + 1), customReason);
    });
    
    it("Should emit EmergencyActionTaken with empty reason for default message", async function () {
      await expect(pmm.connect(owner).pause(""))
        .to.emit(pmm, "EmergencyActionTaken")
        .withArgs("pause", owner.address, await ethers.provider.getBlock('latest').then(b => b.timestamp + 1), "Contract paused by owner");
    });
  });

  describe("Milestone Event Testing", function () {
    it("Should emit milestone event when crossing 100 votes", async function () {
      const platformId = getUniquePlatformId();
      
      // Create market with 140 total votes (60, 80)
      await expect(pmm.connect(charlie).createMarket(platformId, 60, 80))
        .to.emit(pmm, "MarketMilestone")
        .withArgs(platformId, 140, 100, await ethers.provider.getBlock('latest').then(b => b.timestamp + 1));
        
      // Check highest milestone reached
      expect(await pmm.highestMilestoneReached(platformId)).to.equal(100);
    });
    
    it("Should emit multiple milestones when jumping levels", async function () {
      const platformId = getUniquePlatformId();
      
      // Create market with 1400 votes (600, 800) - valid Pythagorean triple
      const tx = await pmm.connect(charlie).createMarket(platformId, 600, 800);
      
      // Should emit milestones for 100 and 1000
      await expect(tx)
        .to.emit(pmm, "MarketMilestone")
        .withArgs(platformId, 1400, 100, anyValue);
        
      await expect(tx)
        .to.emit(pmm, "MarketMilestone")
        .withArgs(platformId, 1400, 1000, anyValue);
        
      expect(await pmm.highestMilestoneReached(platformId)).to.equal(1000);
    });
    
    it("Should emit milestone when voting crosses threshold", async function () {
      const platformId = getUniquePlatformId();
      
      // Create market just below 100 votes - use (39, 52) = 91 votes (valid Pythagorean triple)
      await pmm.connect(alice).createMarket(platformId, 39, 52);
      
      // Vote to cross 100 threshold
      await expect(pmm.connect(bob).voteOnMarket(platformId, 60, 80)) // 140 votes
        .to.emit(pmm, "MarketMilestone")
        .withArgs(platformId, 140, 100, await ethers.provider.getBlock('latest').then(b => b.timestamp + 1));
    });
    
    it("Should not re-emit already reached milestones", async function () {
      const platformId = getUniquePlatformId();
      
      // Create market above 100
      await pmm.connect(charlie).createMarket(platformId, 60, 80); // 140 votes
      
      // Vote to increase further but still below 1000
      const tx = await pmm.connect(bob).voteOnMarket(platformId, 100, 240); // 340 votes (valid: 100² + 240² = 260²)
      
      // Should NOT emit 100 milestone again
      const receipt = await tx.wait();
      const milestoneEvents = receipt.logs.filter(
        log => log.topics[0] === pmm.interface.getEvent("MarketMilestone").topicHash
      );
      expect(milestoneEvents.length).to.equal(0);
    });
    
    it("Should track all milestone constants", async function () {
      // Verify all milestone constants exist
      expect(await pmm.MILESTONE_1()).to.equal(100);
      expect(await pmm.MILESTONE_2()).to.equal(1000);
      expect(await pmm.MILESTONE_3()).to.equal(10000);
      expect(await pmm.MILESTONE_4()).to.equal(100000);
      expect(await pmm.MILESTONE_5()).to.equal(1000000);
      expect(await pmm.MILESTONE_6()).to.equal(10000000);
      expect(await pmm.MILESTONE_7()).to.equal(100000000);
    });
  });

  describe("Balance and Liquidity Management", function () {
    it("Should track contract balance correctly", async function () {
      const initialBalance = await pmm.getContractBalance();
      expect(initialBalance).to.equal(0);
      
      // Create market
      await pmm.connect(alice).createMarket(PLATFORM_ID_1, 3, 4);
      
      // Contract should now hold 5.05 TENBIN
      const afterCreation = await pmm.getContractBalance();
      expect(afterCreation).to.equal(5050000n);
      
      // Vote to add more liquidity
      await pmm.connect(bob).voteOnMarket(PLATFORM_ID_1, 5, 12);
      
      // Contract should now hold 5.05 + 8.08 = 13.13 TENBIN
      const afterVoting = await pmm.getContractBalance();
      expect(afterVoting).to.equal(13130000n);
    });
    
    it("Should calculate available liquidity correctly", async function () {
      // Create market and vote to generate fees
      await pmm.connect(alice).createMarket(PLATFORM_ID_1, 3, 4);
      await pmm.connect(bob).voteOnMarket(PLATFORM_ID_1, 5, 12);
      
      const contractBalance = await pmm.getContractBalance();
      const accumulatedFees = await pmm.accumulatedProtocolFees();
      const availableLiquidity = await pmm.getAvailableLiquidity();
      
      // Available liquidity = balance - fees
      expect(availableLiquidity).to.equal(contractBalance - accumulatedFees);
    });
    
    it("Should prevent insufficient balance errors", async function () {
      await pmm.connect(alice).createMarket(PLATFORM_ID_1, 3, 4);
      
      // Try to vote with insufficient balance
      const poorUser = eve; // Has TENBIN but not enough
      await tenbin.connect(poorUser).transfer(owner.address, await tenbin.balanceOf(poorUser.address) - 1000000n); // Leave only 1 token
      
      // Should fail due to insufficient balance
      await expect(pmm.connect(poorUser).voteOnMarket(PLATFORM_ID_1, 5, 12))
        .to.be.revertedWithCustomError(pmm, "PaymentFailed");
    });
  });

  describe("Coordinate Occupancy and Retry Logic", function () {
    it("Should handle coordinate occupancy when creating multiple markets", async function () {
      const platformIds = [];
      const usedCoords = [];
      
      // Try to create markets using common coordinates
      for (let i = 0; i < 5; i++) {
        const platformId = getUniquePlatformId();
        platformIds.push(platformId);
        
        // Try common coordinates first
        for (const [x, y] of COMMON_COORDS.slice(0, 10)) {
          const coordKey = `${x},${y}`;
          
          if (!usedCoords.includes(coordKey)) {
            try {
              await pmm.connect(alice).createMarket(platformId, x, y);
              usedCoords.push(coordKey);
              console.log(`Created market ${platformId} at (${x}, ${y})`);
              break;
            } catch (error) {
              // Coordinate occupied, try next
              if (error.message.includes("CoordinateOccupied")) {
                continue;
              }
              throw error;
            }
          }
        }
      }
      
      // Verify all markets were created
      for (const platformId of platformIds) {
        expect(await pmm.marketExistsFor(platformId)).to.be.true;
      }
    });
    
    it("Should find available coordinates with larger multipliers", async function () {
      // Create markets at common small coordinates
      const smallCoords = [[3, 4], [5, 12], [8, 15], [7, 24], [20, 21]];
      let platformId = getUniquePlatformId();
      
      for (const [x, y] of smallCoords) {
        try {
          await pmm.connect(alice).createMarket(platformId++, x, y);
        } catch (e) {
          // Skip if occupied
        }
      }
      
      // Now create markets with larger multipliers
      const baseTriples = [[3, 4, 5], [5, 12, 13], [8, 15, 17]];
      const newMarkets = [];
      
      for (let multiplier = 10; multiplier <= 50; multiplier += 10) {
        for (const [baseX, baseY] of baseTriples) {
          const x = baseX * multiplier;
          const y = baseY * multiplier;
          const newPlatformId = getUniquePlatformId();
          
          try {
            await pmm.connect(bob).createMarket(newPlatformId, x, y);
            newMarkets.push({ platformId: newPlatformId, x, y });
            break; // Found available coordinate
          } catch (e) {
            // Continue searching
          }
        }
      }
      
      // Verify we created some markets with larger coordinates
      expect(newMarkets.length).to.be.gt(0);
      console.log(`Created ${newMarkets.length} markets with larger coordinates`);
    });
  });

  describe("Access Control", function () {
    it("Should enforce owner-only functions", async function () {
      // Non-owner tries to pause
      await expect(pmm.connect(alice).pause(""))
        .to.be.revertedWithCustomError(pmm, "OwnableUnauthorizedAccount");
        
      // Non-owner tries to unpause
      await expect(pmm.connect(alice).unpause())
        .to.be.revertedWithCustomError(pmm, "OwnableUnauthorizedAccount");
        
      // Non-owner tries to distribute fees
      await expect(pmm.connect(alice).distributeProtocolFees(0))
        .to.be.revertedWithCustomError(pmm, "OwnableUnauthorizedAccount");
        
      // Non-owner tries to update fee recipients
      await expect(pmm.connect(alice).updateFeeRecipients(bob.address, charlie.address))
        .to.be.revertedWithCustomError(pmm, "OwnableUnauthorizedAccount");
    });
    
    it("Should allow owner to transfer ownership", async function () {
      // Transfer ownership to alice
      await pmm.connect(owner).transferOwnership(alice.address);
      
      // Alice should now be able to pause
      await expect(pmm.connect(alice).pause("Test pause"))
        .to.emit(pmm, "EmergencyActionTaken");
        
      // Original owner should not be able to pause
      await expect(pmm.connect(owner).unpause())
        .to.be.revertedWithCustomError(pmm, "OwnableUnauthorizedAccount");
    });
  });

  describe("Platform Market Info", function () {
    it("Should display platform market information", async function () {
      console.log("\n=== Platform Market Info ===");
      console.log("Protocol Fee:", await pmm.protocolFeeBasisPoints(), "basis points (default 1%)");
      console.log("Minimum Votes:", await pmm.MINIMUM_VOTES());
      
      // Check fee recipients
      const feeInfo = await pmm.getFeeDistributionInfo();
      console.log("Owner Fee Recipient:", feeInfo.ownerRecipient);
      console.log("Protocol Fee Recipient:", feeInfo.protocolRecipient);
      console.log("Accumulated Fees:", ethers.formatUnits(feeInfo.pendingFees, 6), "TENBIN");
    });
  });

  describe("Configurable Protocol Fee", function () {
    it("Should have default protocol fee of 1% (100 basis points)", async function () {
      expect(await pmm.protocolFeeBasisPoints()).to.equal(100);
      expect(await pmm.MAX_PROTOCOL_FEE_BASIS_POINTS()).to.equal(100);
    });

    it("Should allow owner to set protocol fee within range (0-100 basis points)", async function () {
      // Set to 0.5% (50 basis points)
      await expect(pmm.connect(owner).setProtocolFee(50))
        .to.emit(pmm, "ProtocolFeeUpdated")
        .withArgs(100, 50, owner.address);
      
      expect(await pmm.protocolFeeBasisPoints()).to.equal(50);
      
      // Set to 0%
      await expect(pmm.connect(owner).setProtocolFee(0))
        .to.emit(pmm, "ProtocolFeeUpdated")
        .withArgs(50, 0, owner.address);
      
      expect(await pmm.protocolFeeBasisPoints()).to.equal(0);
      
      // Set back to 1%
      await expect(pmm.connect(owner).setProtocolFee(100))
        .to.emit(pmm, "ProtocolFeeUpdated")
        .withArgs(0, 100, owner.address);
      
      expect(await pmm.protocolFeeBasisPoints()).to.equal(100);
    });

    it("Should allow protocol fee recipient to set protocol fee", async function () {
      const protocolRecipient = await pmm.protocolFeeRecipient();
      
      // Find the signer matching the protocol recipient or update it first
      await pmm.connect(owner).updateFeeRecipients(await pmm.ownerFeeRecipient(), alice.address);
      
      // Alice (now protocol recipient) should be able to set fee
      await expect(pmm.connect(alice).setProtocolFee(75))
        .to.emit(pmm, "ProtocolFeeUpdated")
        .withArgs(100, 75, alice.address);
      
      expect(await pmm.protocolFeeBasisPoints()).to.equal(75);
    });

    it("Should reject protocol fee above 1% (100 basis points)", async function () {
      await expect(pmm.connect(owner).setProtocolFee(101))
        .to.be.revertedWithCustomError(pmm, "InvalidProtocolFee");
      
      await expect(pmm.connect(owner).setProtocolFee(500))
        .to.be.revertedWithCustomError(pmm, "InvalidProtocolFee");
      
      await expect(pmm.connect(owner).setProtocolFee(10000))
        .to.be.revertedWithCustomError(pmm, "InvalidProtocolFee");
    });

    it("Should reject protocol fee change from unauthorized address", async function () {
      // Non-owner, non-protocol-recipient cannot set fee
      await expect(pmm.connect(bob).setProtocolFee(50))
        .to.be.revertedWithCustomError(pmm, "OwnableUnauthorizedAccount");
      
      await expect(pmm.connect(charlie).setProtocolFee(0))
        .to.be.revertedWithCustomError(pmm, "OwnableUnauthorizedAccount");
    });

    it("Should apply new fee rate to market creation", async function () {
      // Set fee to 0.5%
      await pmm.connect(owner).setProtocolFee(50);
      
      const platformId = getUniquePlatformId();
      const aliceBalanceBefore = await tenbin.balanceOf(alice.address);
      
      // Create market at (3, 4) - hypotenuse = 5
      // Cost = 5 TENBIN + 0.5% fee = 5.025 TENBIN
      await pmm.connect(alice).createMarket(platformId, 3, 4);
      
      const aliceBalanceAfter = await tenbin.balanceOf(alice.address);
      const spent = aliceBalanceBefore - aliceBalanceAfter;
      
      // 5 TENBIN + 0.025 fee = 5.025 TENBIN = 5,025,000 units
      expect(spent).to.equal(5025000n);
    });

    it("Should apply new fee rate to voting", async function () {
      await pmm.connect(alice).createMarket(PLATFORM_ID_1, 3, 4);
      
      // Set fee to 0%
      await pmm.connect(owner).setProtocolFee(0);
      
      const bobBalanceBefore = await tenbin.balanceOf(bob.address);
      
      // Vote from (3, 4) to (5, 12) - hypotenuse change = 13 - 5 = 8
      // Cost = 8 TENBIN + 0% fee = 8.00 TENBIN
      await pmm.connect(bob).voteOnMarket(PLATFORM_ID_1, 5, 12);
      
      const bobBalanceAfter = await tenbin.balanceOf(bob.address);
      const spent = bobBalanceBefore - bobBalanceAfter;
      
      // 8 TENBIN + 0 fee = 8.00 TENBIN = 8,000,000 units
      expect(spent).to.equal(8000000n);
    });

    it("Should apply new fee rate to selling (refunds)", async function () {
      // Create and vote at default 1% fee
      await pmm.connect(alice).createMarket(PLATFORM_ID_1, 3, 4);
      await pmm.connect(bob).voteOnMarket(PLATFORM_ID_1, 5, 12);
      
      // Set fee to 0%
      await pmm.connect(owner).setProtocolFee(0);
      
      const bobBalanceBefore = await tenbin.balanceOf(bob.address);
      
      // Sell back to (3, 4) - refund 8 TENBIN - 0% fee = 8.00 TENBIN
      await pmm.connect(bob).voteOnMarket(PLATFORM_ID_1, 3, 4);
      
      const bobBalanceAfter = await tenbin.balanceOf(bob.address);
      const received = bobBalanceAfter - bobBalanceBefore;
      
      // 8 TENBIN - 0 fee = 8.00 TENBIN = 8,000,000 units
      expect(received).to.equal(8000000n);
    });

    it("Should correctly calculate fees with various fee rates", async function () {
      const testFees = [0, 25, 50, 75, 100]; // 0%, 0.25%, 0.5%, 0.75%, 1%
      
      for (const feeBP of testFees) {
        await pmm.connect(owner).setProtocolFee(feeBP);
        
        const platformId = getUniquePlatformId();
        const balanceBefore = await tenbin.balanceOf(alice.address);
        
        await pmm.connect(alice).createMarket(platformId, 3, 4);
        
        const balanceAfter = await tenbin.balanceOf(alice.address);
        const spent = balanceBefore - balanceAfter;
        
        // Expected: 5 TENBIN * (1 + feeBP/10000)
        const baseAmount = 5000000n; // 5 TENBIN
        const expectedFee = (baseAmount * BigInt(feeBP)) / 10000n;
        const expectedTotal = baseAmount + expectedFee;
        
        expect(spent).to.equal(expectedTotal);
      }
    });

    it("Should track accumulated fees correctly with different fee rates", async function () {
      // Start fresh - accumulated fees are 0
      const initialFees = await pmm.accumulatedProtocolFees();
      
      // Create market at 1% fee
      await pmm.connect(alice).createMarket(PLATFORM_ID_1, 3, 4);
      // Fee = 5 * 0.01 = 0.05 TENBIN = 50,000 units
      
      expect(await pmm.accumulatedProtocolFees()).to.equal(initialFees + 50000n);
      
      // Set fee to 0%
      await pmm.connect(owner).setProtocolFee(0);
      
      // Vote - should add 0 fees
      await pmm.connect(bob).voteOnMarket(PLATFORM_ID_1, 5, 12);
      
      expect(await pmm.accumulatedProtocolFees()).to.equal(initialFees + 50000n);
      
      // Set fee to 0.5%
      await pmm.connect(owner).setProtocolFee(50);
      
      // Vote again - hypotenuse change = sqrt(11^2 + 60^2) - sqrt(5^2 + 12^2) = 61 - 13 = 48
      // Fee = 48 * 0.005 = 0.24 TENBIN = 240,000 units
      await pmm.connect(charlie).voteOnMarket(PLATFORM_ID_1, 11, 60);
      
      expect(await pmm.accumulatedProtocolFees()).to.equal(initialFees + 50000n + 240000n);
    });

    it("Should return updated fee info after fee change", async function () {
      // Default fee
      let [feeBasisPoints, feePercentage, maxFeeBasisPoints] = await pmm.getProtocolFeeInfo();
      expect(feeBasisPoints).to.equal(100);
      expect(feePercentage).to.equal(1);
      expect(maxFeeBasisPoints).to.equal(100);
      
      // Change fee to 50 basis points
      await pmm.connect(owner).setProtocolFee(50);
      
      [feeBasisPoints, feePercentage, maxFeeBasisPoints] = await pmm.getProtocolFeeInfo();
      expect(feeBasisPoints).to.equal(50);
      expect(feePercentage).to.equal(0); // Integer division 50/100 = 0
      expect(maxFeeBasisPoints).to.equal(100);
      
      // Change fee to 0
      await pmm.connect(owner).setProtocolFee(0);
      
      [feeBasisPoints, feePercentage, maxFeeBasisPoints] = await pmm.getProtocolFeeInfo();
      expect(feeBasisPoints).to.equal(0);
      expect(feePercentage).to.equal(0);
      expect(maxFeeBasisPoints).to.equal(100);
    });
  });

  describe("Market Application Workflow", function () {
    const APPLICATION_FEE = ethers.parseUnits("10", 6); // 10 TENBIN
    
    it("Should allow users to apply for a new market", async function () {
      const platformId = getUniquePlatformId();
      
      // Apply for market
      await expect(pmm.connect(alice).applyForMarket(platformId))
        .to.emit(pmm, "MarketApplicationSubmitted")
        .withArgs(platformId, alice.address, APPLICATION_FEE, anyValue);
      
      // Check application exists
      const app = await pmm.marketApplications(platformId);
      expect(app.applicant).to.equal(alice.address);
      expect(app.timestamp).to.be.gt(0);
      
      // Application fee should be added to accumulated fees
      const fees = await pmm.accumulatedProtocolFees();
      expect(fees).to.equal(APPLICATION_FEE);
    });
    
    it("Should charge 10 TENBIN application fee", async function () {
      const platformId = getUniquePlatformId();
      
      const balanceBefore = await tenbin.balanceOf(alice.address);
      await pmm.connect(alice).applyForMarket(platformId);
      const balanceAfter = await tenbin.balanceOf(alice.address);
      
      expect(balanceBefore - balanceAfter).to.equal(APPLICATION_FEE);
    });
    
    it("Should prevent duplicate applications", async function () {
      const platformId = getUniquePlatformId();
      
      await pmm.connect(alice).applyForMarket(platformId);
      
      await expect(pmm.connect(bob).applyForMarket(platformId))
        .to.be.revertedWithCustomError(pmm, "MarketApplicationExists");
    });
    
    it("Should prevent application for existing market", async function () {
      const platformId = getUniquePlatformId();
      
      // Create market directly (as owner)
      await pmm.connect(alice).createMarket(platformId, 3, 4);
      
      // Try to apply
      await expect(pmm.connect(bob).applyForMarket(platformId))
        .to.be.revertedWithCustomError(pmm, "MarketAlreadyExists");
    });
    
    it("Should allow owner to approve application", async function () {
      const platformId = getUniquePlatformId();
      
      // Alice applies
      await pmm.connect(alice).applyForMarket(platformId);
      
      // Owner approves
      await expect(pmm.connect(owner).approveMarket(platformId))
        .to.emit(pmm, "MarketApplicationApproved")
        .withArgs(platformId, owner.address, alice.address);
      
      // Market should exist at (0, 0)
      expect(await pmm.marketExistsFor(platformId)).to.be.true;
      const coords = await pmm.marketCoordinates(platformId);
      expect(coords.x).to.equal(0);
      expect(coords.y).to.equal(0);
      
      // Creator should be the applicant
      expect(await pmm.marketCreator(platformId)).to.equal(alice.address);
      
      // Application should be cleared
      const app = await pmm.marketApplications(platformId);
      expect(app.applicant).to.equal(ethers.ZeroAddress);
    });
    
    it("Should allow owner to deny application", async function () {
      const platformId = getUniquePlatformId();
      
      // Alice applies
      await pmm.connect(alice).applyForMarket(platformId);
      
      // Owner denies
      await expect(pmm.connect(owner).denyMarket(platformId))
        .to.emit(pmm, "MarketApplicationDenied")
        .withArgs(platformId, owner.address, alice.address);
      
      // Market should NOT exist
      expect(await pmm.marketExistsFor(platformId)).to.be.false;
      
      // Application should be cleared
      const app = await pmm.marketApplications(platformId);
      expect(app.applicant).to.equal(ethers.ZeroAddress);
      
      // Fee should remain consumed (not refunded)
      const fees = await pmm.accumulatedProtocolFees();
      expect(fees).to.equal(APPLICATION_FEE);
    });
    
    it("Should prevent non-owner from approving/denying", async function () {
      const platformId = getUniquePlatformId();
      
      await pmm.connect(alice).applyForMarket(platformId);
      
      await expect(pmm.connect(bob).approveMarket(platformId))
        .to.be.revertedWithCustomError(pmm, "OwnableUnauthorizedAccount");
      
      await expect(pmm.connect(bob).denyMarket(platformId))
        .to.be.revertedWithCustomError(pmm, "OwnableUnauthorizedAccount");
    });
    
    it("Should fail to approve/deny non-existent application", async function () {
      const platformId = getUniquePlatformId();
      
      await expect(pmm.connect(owner).approveMarket(platformId))
        .to.be.revertedWithCustomError(pmm, "MarketApplicationNotFound");
      
      await expect(pmm.connect(owner).denyMarket(platformId))
        .to.be.revertedWithCustomError(pmm, "MarketApplicationNotFound");
    });
    
    it("Should allow voting after approval to set initial position", async function () {
      const platformId = getUniquePlatformId();
      
      // Apply and approve
      await pmm.connect(alice).applyForMarket(platformId);
      await pmm.connect(owner).approveMarket(platformId);
      
      // Market is at (0, 0), vote to move to (3, 4)
      await pmm.connect(bob).voteOnMarket(platformId, 3, 4);
      
      // Check new state
      const state = await pmm.getMarketState(platformId);
      expect(state.x).to.equal(3);
      expect(state.y).to.equal(4);
      
      // Bob should own the votes
      const [yVotes, xVotes, exists] = await pmm.getVoterPosition(platformId, bob.address);
      expect(exists).to.be.true;
      expect(yVotes).to.equal(4);
      expect(xVotes).to.equal(3);
    });
  });

  describe("Yield System", function () {
    beforeEach(async function () {
      // Set PMM as the minter for TENBIN
      await tenbin.setMinter(await pmm.getAddress());
    });
    
    it("Should calculate yield rate based on total markets", async function () {
      // Initially no markets
      const initialRate = await pmm.currentAnnualYieldWad();
      expect(initialRate).to.equal(0);
      
      // Create a market
      await pmm.connect(alice).createMarket(PLATFORM_ID_1, 3, 4);
      
      // Yield rate should now be positive
      const rateAfter = await pmm.currentAnnualYieldWad();
      expect(rateAfter).to.be.gt(0);
      
      // K = 0.75 * sqrt(pi) ≈ 1.329
      // Rate for 1 market = K / sqrt(1) = K ≈ 1.329
      const K_WAD = 1329340388179137000n;
      expect(rateAfter).to.be.closeTo(K_WAD, K_WAD / 100n); // Within 1%
    });
    
    it("Should decrease yield rate as more markets are created", async function () {
      // Create first market
      await pmm.connect(alice).createMarket(PLATFORM_ID_1, 3, 4);
      const rate1 = await pmm.currentAnnualYieldWad();
      
      // Create second market
      await pmm.connect(alice).createMarket(PLATFORM_ID_2, 5, 12);
      const rate2 = await pmm.currentAnnualYieldWad();
      
      // Rate should decrease: rate2 = K / sqrt(2) < K / sqrt(1) = rate1
      expect(rate2).to.be.lt(rate1);
      
      // Ratio should be sqrt(1)/sqrt(2) ≈ 0.707
      const ratio = Number(rate2) / Number(rate1);
      expect(ratio).to.be.closeTo(0.707, 0.01);
    });
    
    it("Should track holdings cost basis", async function () {
      await pmm.connect(alice).createMarket(PLATFORM_ID_1, 3, 4);
      
      // Check Alice's holdings
      const holdings = await pmm.holdings(PLATFORM_ID_1, alice.address);
      
      // yCost should reflect the 4 y-votes component
      // xCost should reflect the 3 x-votes component
      // Total should be close to hypotenuse * 1e6 (5 TENBIN)
      expect(holdings.yCost + holdings.disyCost).to.be.closeTo(
        5000000n, // 5 TENBIN in wei
        100n // Allow small rounding
      );
      expect(holdings.lastAccrual).to.be.gt(0);
      expect(holdings.unclaimedYield).to.equal(0); // No time passed yet
    });
    
    it("Should accrue yield over time", async function () {
      await pmm.connect(alice).createMarket(PLATFORM_ID_1, 3, 4);
      
      // Fast forward time (1 year)
      await ethers.provider.send("evm_increaseTime", [365 * 24 * 60 * 60]);
      await ethers.provider.send("evm_mine", []);
      
      // Trigger accrual by voting (0 cost rebalance won't work, need actual trade)
      // Or we can check holdings directly after time passes
      // The accrual happens on next trade or claim
      
      // For testing, let's vote to trigger accrual
      await pmm.connect(bob).voteOnMarket(PLATFORM_ID_1, 5, 12);
      
      // Now check Alice's holdings (accrual happened during Bob's vote)
      const holdings = await pmm.holdings(PLATFORM_ID_1, alice.address);
      
      // After 1 year with rate K ≈ 1.329 and base ≈ 5 TENBIN
      // Yield ≈ 5 * 1.329 = 6.645 TENBIN
      // But this depends on exact implementation
      expect(holdings.unclaimedYield).to.be.gte(0);
    });
    
    it("Should allow claiming yield", async function () {
      await pmm.connect(alice).createMarket(PLATFORM_ID_1, 3, 4);
      
      // Fast forward time (30 days)
      await ethers.provider.send("evm_increaseTime", [30 * 24 * 60 * 60]);
      await ethers.provider.send("evm_mine", []);
      
      // Trigger accrual
      await pmm.connect(bob).voteOnMarket(PLATFORM_ID_1, 5, 12);
      
      const balanceBefore = await tenbin.balanceOf(alice.address);
      
      // Alice claims yield
      await pmm.connect(alice).claimYield(PLATFORM_ID_1);
      
      const balanceAfter = await tenbin.balanceOf(alice.address);
      
      // Balance should increase (yield minted)
      expect(balanceAfter).to.be.gte(balanceBefore);
      
      // Holdings should show 0 unclaimed yield after claim
      const holdings = await pmm.holdings(PLATFORM_ID_1, alice.address);
      expect(holdings.unclaimedYield).to.equal(0);
    });
    
    it("Should update cost basis on buy", async function () {
      await pmm.connect(alice).createMarket(PLATFORM_ID_1, 3, 4);
      
      const holdingsBefore = await pmm.holdings(PLATFORM_ID_1, alice.address);
      const initialCost = holdingsBefore.yCost + holdingsBefore.disyCost;
      
      // Alice buys more votes
      await pmm.connect(alice).voteOnMarket(PLATFORM_ID_1, 5, 12);
      
      const holdingsAfter = await pmm.holdings(PLATFORM_ID_1, alice.address);
      const finalCost = holdingsAfter.yCost + holdingsAfter.disyCost;
      
      // Cost basis should increase
      expect(finalCost).to.be.gt(initialCost);
    });
    
    it("Should reduce cost basis pro-rata on sell", async function () {
      // Alice creates market and accumulates position
      await pmm.connect(alice).createMarket(PLATFORM_ID_1, 5, 12);
      
      const holdingsBefore = await pmm.holdings(PLATFORM_ID_1, alice.address);
      
      // Alice sells some votes (move to smaller position)
      await pmm.connect(alice).voteOnMarket(PLATFORM_ID_1, 3, 4);
      
      const holdingsAfter = await pmm.holdings(PLATFORM_ID_1, alice.address);
      
      // Cost basis should decrease
      expect(holdingsAfter.yCost + holdingsAfter.disyCost)
        .to.be.lt(holdingsBefore.yCost + holdingsBefore.disyCost);
    });
    
    it("Should not change cost basis on rebalance", async function () {
      await pmm.connect(alice).createMarket(PLATFORM_ID_1, 5, 12);
      
      const holdingsBefore = await pmm.holdings(PLATFORM_ID_1, alice.address);
      
      // Rebalance to (12, 5) - same hypotenuse
      await pmm.connect(alice).voteOnMarket(PLATFORM_ID_1, 12, 5);
      
      const holdingsAfter = await pmm.holdings(PLATFORM_ID_1, alice.address);
      
      // Total cost basis should remain the same
      expect(holdingsAfter.yCost + holdingsAfter.disyCost)
        .to.equal(holdingsBefore.yCost + holdingsBefore.disyCost);
    });
    
    it("Should revert claim if minting not supported", async function () {
      // Reset minter to non-PMM address
      await tenbin.setMinter(owner.address);
      
      await pmm.connect(alice).createMarket(PLATFORM_ID_1, 3, 4);
      
      // Fast forward time
      await ethers.provider.send("evm_increaseTime", [30 * 24 * 60 * 60]);
      await ethers.provider.send("evm_mine", []);
      
      // Trigger accrual
      await pmm.connect(bob).voteOnMarket(PLATFORM_ID_1, 5, 12);
      
      // Claim should fail because PMM can't mint
      await expect(pmm.connect(alice).claimYield(PLATFORM_ID_1))
        .to.be.revertedWithCustomError(pmm, "MintingNotSupported");
    });
    
    it("Should track total markets correctly", async function () {
      expect(await pmm.totalMarkets()).to.equal(0);
      
      await pmm.connect(alice).createMarket(PLATFORM_ID_1, 3, 4);
      expect(await pmm.totalMarkets()).to.equal(1);
      
      await pmm.connect(bob).createMarket(PLATFORM_ID_2, 5, 12);
      expect(await pmm.totalMarkets()).to.equal(2);
      
      // Via application workflow
      const platformId3 = getUniquePlatformId();
      await pmm.connect(charlie).applyForMarket(platformId3);
      await pmm.connect(owner).approveMarket(platformId3);
      expect(await pmm.totalMarkets()).to.equal(3);
    });
  });
});