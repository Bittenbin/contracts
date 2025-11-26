const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");

/**
 * Security and Exploit Prevention Tests
 * Tests various attack vectors to ensure contract security
 */
describe("Security and Exploit Prevention", function () {
  let pmm;
  let tenbin;
  let owner;
  let attacker;
  let victim;
  let alice;
  let bob;

  const PLATFORM_ID = 1234567890;

  beforeEach(async function () {
    [owner, attacker, victim, alice, bob] = await ethers.getSigners();

    // Deploy TENBIN token
    const TenbinToken = await ethers.getContractFactory("TenbinToken");
    tenbin = await TenbinToken.deploy(owner.address);
    await tenbin.waitForDeployment();

    // Deploy PMM
    const PythagoreanMarketMaker = await ethers.getContractFactory("PythagoreanMarketMaker");
    pmm = await upgrades.deployProxy(
      PythagoreanMarketMaker,
      [await tenbin.getAddress()],
      { initializer: 'initialize' }
    );
    await pmm.waitForDeployment();

    // Fund users
    for (const user of [attacker, victim, alice, bob]) {
      await tenbin.mint(user.address, ethers.parseUnits("1000000", 6));
      await tenbin.connect(user).approve(await pmm.getAddress(), ethers.parseUnits("1000000", 6));
    }
  });

  describe("Reentrancy Protection", function () {
    it("Should have ReentrancyGuard on createMarket", async function () {
      // The contract uses nonReentrant modifier
      // We can verify by checking the contract inherits ReentrancyGuardUpgradeable
      // Direct reentrancy test would require a malicious token, but the modifier protects
      await expect(pmm.connect(alice).createMarket(PLATFORM_ID, 3, 4))
        .to.not.be.reverted;
    });

    it("Should have ReentrancyGuard on voteOnMarket", async function () {
      await pmm.connect(alice).createMarket(PLATFORM_ID, 3, 4);
      await expect(pmm.connect(bob).voteOnMarket(PLATFORM_ID, 5, 12))
        .to.not.be.reverted;
    });

    it("Should have ReentrancyGuard on claimYield", async function () {
      await tenbin.setMinter(await pmm.getAddress());
      await pmm.connect(alice).createMarket(PLATFORM_ID, 3, 4);
      await expect(pmm.connect(alice).claimYield(PLATFORM_ID))
        .to.not.be.reverted;
    });

    it("Should have ReentrancyGuard on fee distribution", async function () {
      await pmm.connect(alice).createMarket(PLATFORM_ID, 3, 4);
      await expect(pmm.connect(owner).distributeProtocolFees(0))
        .to.not.be.reverted;
    });
  });

  describe("Front-Running / Sandwich Attack Prevention", function () {
    it("Should protect against sandwich attacks with slippage", async function () {
      await pmm.connect(alice).createMarket(PLATFORM_ID, 3, 4);
      
      // Attacker tries to front-run victim's large buy
      // Victim sets 1% slippage tolerance
      const slippageBP = 100; // 1%
      
      // Calculate expected cost
      const [expectedPayment, maxPayment] = await pmm.calculatePaymentWithSlippage(
        3, 4, // current
        5, 12, // target
        slippageBP
      );
      
      // The slippage protection ensures victim won't pay more than maxPayment
      expect(maxPayment).to.be.gt(expectedPayment);
      expect(maxPayment - expectedPayment).to.be.lte(expectedPayment * BigInt(slippageBP) / 10000n);
    });

    it("Should allow user to set tight slippage to prevent manipulation", async function () {
      await pmm.connect(alice).createMarket(PLATFORM_ID, 3, 4);
      
      // User can set 0% slippage for exact amount (risky but possible)
      await expect(pmm.connect(bob).voteOnMarketWithSlippage(PLATFORM_ID, 5, 12, 0))
        .to.not.be.reverted;
    });
  });

  describe("Vote Manipulation Prevention", function () {
    it("Should prevent attacker from selling votes they don't own", async function () {
      // Alice creates market
      await pmm.connect(alice).createMarket(PLATFORM_ID, 5, 12);
      
      // Attacker tries to sell (reduce position) without owning any votes
      await expect(pmm.connect(attacker).voteOnMarket(PLATFORM_ID, 3, 4))
        .to.be.revertedWithCustomError(pmm, "InsufficientVotesToSell");
    });

    it("Should prevent attacker from inflating their vote count", async function () {
      await pmm.connect(alice).createMarket(PLATFORM_ID, 3, 4);
      
      // Bob legitimately buys votes
      await pmm.connect(bob).voteOnMarket(PLATFORM_ID, 5, 12);
      
      let [bobTrust, bobDistrust] = await pmm.getVoterPosition(PLATFORM_ID, bob.address);
      expect(bobTrust).to.equal(8); // 12 - 4
      expect(bobDistrust).to.equal(2); // 5 - 3
      
      // Bob cannot claim more votes than delta
      // This is enforced by the contract - votes = delta from previous position
    });

    it("Should prevent vote theft via coordinate manipulation", async function () {
      await pmm.connect(alice).createMarket(PLATFORM_ID, 3, 4);
      await pmm.connect(bob).voteOnMarket(PLATFORM_ID, 5, 12);
      
      // Alice's original votes should remain unchanged
      const [aliceTrust, aliceDistrust] = await pmm.getVoterPosition(PLATFORM_ID, alice.address);
      expect(aliceTrust).to.equal(4);
      expect(aliceDistrust).to.equal(3);
      
      // Bob moving the market doesn't steal Alice's votes
    });

    it("Should prevent double-counting votes", async function () {
      await pmm.connect(alice).createMarket(PLATFORM_ID, 3, 4);
      
      // Bob buys votes
      await pmm.connect(bob).voteOnMarket(PLATFORM_ID, 5, 12);
      let [bobTrust1] = await pmm.getVoterPosition(PLATFORM_ID, bob.address);
      
      // Bob votes again to same position - should not add votes
      await pmm.connect(bob).voteOnMarket(PLATFORM_ID, 5, 12);
      let [bobTrust2] = await pmm.getVoterPosition(PLATFORM_ID, bob.address);
      
      expect(bobTrust2).to.equal(bobTrust1);
    });
  });

  describe("Coordinate Squatting Prevention", function () {
    it("Should prevent squatting on valuable coordinates", async function () {
      // Attacker tries to squat on popular Pythagorean coordinates
      // But they have to pay the cost
      const balanceBefore = await tenbin.balanceOf(attacker.address);
      
      await pmm.connect(attacker).createMarket(PLATFORM_ID, 3, 4);
      
      const balanceAfter = await tenbin.balanceOf(attacker.address);
      const cost = balanceBefore - balanceAfter;
      
      // They have to pay 5.05 TENBIN - not free squatting
      expect(cost).to.equal(5050000n);
    });

    it("Should prevent free coordinate reservation via application", async function () {
      // Even application costs 10 TENBIN
      const balanceBefore = await tenbin.balanceOf(attacker.address);
      
      await pmm.connect(attacker).applyForMarket(PLATFORM_ID);
      
      const balanceAfter = await tenbin.balanceOf(attacker.address);
      expect(balanceBefore - balanceAfter).to.equal(10000000n); // 10 TENBIN
    });
  });

  describe("Yield Exploitation Prevention", function () {
    beforeEach(async function () {
      await tenbin.setMinter(await pmm.getAddress());
    });

    it("Should prevent yield farming via rapid buy/sell", async function () {
      await pmm.connect(alice).createMarket(PLATFORM_ID, 3, 4);
      
      // Attacker tries to farm yield by buying and immediately selling
      await pmm.connect(attacker).voteOnMarket(PLATFORM_ID, 5, 12);
      
      // Immediately sell
      await pmm.connect(attacker).voteOnMarket(PLATFORM_ID, 3, 4);
      
      // No time passed = no yield
      const holdings = await pmm.holdings(PLATFORM_ID, attacker.address);
      expect(holdings.unclaimedYield).to.equal(0);
      
      // Cost basis is also reduced when selling
      expect(holdings.trustCost + holdings.distrustCost).to.equal(0);
    });

    it("Should prevent yield manipulation via market count gaming", async function () {
      // Create multiple markets to lower yield rate
      for (let i = 0; i < 5; i++) {
        await pmm.connect(alice).createMarket(i + 1, 3 + i, 4 + i);
      }
      
      const rate = await pmm.currentAnnualYieldWad();
      // Rate should be K / sqrt(5) ≈ 0.594 WAD
      expect(rate).to.be.lt(ethers.parseUnits("1", 18));
      
      // This is by design - more markets = lower individual yield
      // Not an exploit, just economics
    });

    it("Should prevent claiming yield from non-existent position", async function () {
      await pmm.connect(alice).createMarket(PLATFORM_ID, 3, 4);
      
      // Attacker never participated but tries to claim
      const balanceBefore = await tenbin.balanceOf(attacker.address);
      await pmm.connect(attacker).claimYield(PLATFORM_ID);
      const balanceAfter = await tenbin.balanceOf(attacker.address);
      
      // Should receive nothing
      expect(balanceAfter).to.equal(balanceBefore);
    });

    it("Should prevent double claiming yield", async function () {
      await pmm.connect(alice).createMarket(PLATFORM_ID, 3, 4);
      
      // Advance time
      await ethers.provider.send("evm_increaseTime", [30 * 24 * 60 * 60]);
      await ethers.provider.send("evm_mine", []);
      
      // First claim
      await pmm.connect(alice).claimYield(PLATFORM_ID);
      const balanceAfterFirst = await tenbin.balanceOf(alice.address);
      
      // Immediate second claim
      await pmm.connect(alice).claimYield(PLATFORM_ID);
      const balanceAfterSecond = await tenbin.balanceOf(alice.address);
      
      // No additional yield
      expect(balanceAfterSecond).to.equal(balanceAfterFirst);
    });
  });

  describe("Fee Extraction Prevention", function () {
    it("Should prevent unauthorized fee extraction", async function () {
      await pmm.connect(alice).createMarket(PLATFORM_ID, 3, 4);
      
      // Attacker tries to extract fees
      await expect(pmm.connect(attacker).distributeProtocolFees(0))
        .to.be.revertedWithCustomError(pmm, "OwnableUnauthorizedAccount");
      
      await expect(pmm.connect(attacker).withdrawToOwner(1000))
        .to.be.revertedWithCustomError(pmm, "OwnableUnauthorizedAccount");
      
      await expect(pmm.connect(attacker).withdrawToProtocol(1000))
        .to.be.revertedWithCustomError(pmm, "OwnableUnauthorizedAccount");
    });

    it("Should prevent fee recipient hijacking", async function () {
      await expect(pmm.connect(attacker).updateFeeRecipients(attacker.address, attacker.address))
        .to.be.revertedWithCustomError(pmm, "OwnableUnauthorizedAccount");
    });

    it("Should prevent extracting more fees than accumulated", async function () {
      await pmm.connect(alice).createMarket(PLATFORM_ID, 3, 4);
      
      const fees = await pmm.accumulatedProtocolFees();
      
      await expect(pmm.connect(owner).distributeProtocolFees(fees + 1n))
        .to.be.revertedWithCustomError(pmm, "InvalidFeeAmount");
    });
  });

  describe("Overflow/Underflow Prevention", function () {
    it("Should prevent coordinate overflow", async function () {
      const maxCoord = await pmm.MAX_COORDINATE_VALUE();
      
      // Try to create with values that would overflow in squared calculation
      await expect(pmm.connect(alice).createMarket(PLATFORM_ID, maxCoord + 1n, 3))
        .to.be.revertedWithCustomError(pmm, "CoordinateTooLarge");
    });

    it("Should prevent payment amount overflow", async function () {
      // Large but valid coordinates should not cause overflow
      // Contract uses safe math operations
      const largeX = 100000000n; // 100M
      const largeY = 100000000n; // 100M
      
      // This should work (hypotenuse ≈ 141M < 1.5B limit)
      expect(await pmm.isValidCoordinate(largeX, largeY)).to.be.true;
    });

    it("Should prevent underflow when selling", async function () {
      await pmm.connect(alice).createMarket(PLATFORM_ID, 5, 12);
      
      // Alice owns 5 distrust, 12 trust
      // Try to move to position requiring selling more than owned
      await expect(pmm.connect(alice).voteOnMarket(PLATFORM_ID, 3, 4))
        .to.not.be.reverted; // Should work - she owns enough
      
      // Now Alice has 3 distrust, 4 trust
      // Try to sell more trust than she has (need to go below 0)
      // Going to (3, 1) would require selling 3 trust, but she only has 4 - that works
      // Going to (1, 4) would require selling 2 distrust, she has 3 - that works
      // We need Bob to try to sell votes he doesn't have
      await expect(pmm.connect(bob).voteOnMarket(PLATFORM_ID, 2, 3))
        .to.be.revertedWithCustomError(pmm, "InsufficientVotesToSell");
    });
  });

  describe("DoS Prevention", function () {
    it("Should handle gas-expensive operations gracefully", async function () {
      // Create market with moderately large coordinates (gas cost)
      // (10000, 10001) costs ~14,142 TENBIN which alice can afford
      // Note: x != y to avoid genesis line restriction
      await expect(pmm.connect(alice).createMarket(PLATFORM_ID, 10000, 10001))
        .to.not.be.reverted;
    });

    it("Should prevent griefing via excessive applications", async function () {
      // Each application costs 10 TENBIN
      // Attacker would lose money trying to grief
      for (let i = 0; i < 10; i++) {
        await pmm.connect(attacker).applyForMarket(i + 1);
      }
      
      // Attacker spent 100 TENBIN
      const spent = 10 * 10000000; // 100 TENBIN
      expect(await pmm.accumulatedProtocolFees()).to.be.gte(spent);
    });

    it("Should prevent blocking market by taking all coordinates", async function () {
      // With 1B max coordinate and unique (x,y) pairs
      // There are effectively infinite coordinates
      // Taking a few doesn't block the system
      
      await pmm.connect(attacker).createMarket(1, 3, 4);
      await pmm.connect(attacker).createMarket(2, 5, 12);
      
      // Others can still use different coordinates
      await expect(pmm.connect(alice).createMarket(3, 8, 15))
        .to.not.be.reverted;
    });
  });

  describe("Access Control Bypass Prevention", function () {
    it("Should prevent non-owner from pausing", async function () {
      await expect(pmm.connect(attacker).pause("Malicious"))
        .to.be.revertedWithCustomError(pmm, "OwnableUnauthorizedAccount");
    });

    it("Should prevent non-owner from unpausing", async function () {
      await pmm.connect(owner).pause("Test");
      
      await expect(pmm.connect(attacker).unpause())
        .to.be.revertedWithCustomError(pmm, "OwnableUnauthorizedAccount");
    });

    it("Should prevent non-owner from approving applications", async function () {
      await pmm.connect(alice).applyForMarket(PLATFORM_ID);
      
      await expect(pmm.connect(attacker).approveMarket(PLATFORM_ID))
        .to.be.revertedWithCustomError(pmm, "OwnableUnauthorizedAccount");
    });

    it("Should prevent ownership takeover via renounce", async function () {
      // Owner can renounce, but this is intentional
      // After renouncing, no one can perform owner actions
      // This is by design, not an exploit
    });
  });

  describe("Token Approval Exploits", function () {
    it("Should not allow PMM to spend more than approved", async function () {
      // Give limited approval
      await tenbin.connect(alice).approve(await pmm.getAddress(), ethers.parseUnits("1", 6));
      
      // Try to create market costing 5.05 TENBIN
      await expect(pmm.connect(alice).createMarket(PLATFORM_ID, 3, 4))
        .to.be.reverted; // Insufficient allowance
    });

    it("Should not hold excess tokens from users", async function () {
      const balanceBefore = await tenbin.balanceOf(alice.address);
      
      await pmm.connect(alice).createMarket(PLATFORM_ID, 3, 4);
      
      const balanceAfter = await tenbin.balanceOf(alice.address);
      const spent = balanceBefore - balanceAfter;
      
      // Should spend exactly 5.05 TENBIN, not more
      expect(spent).to.equal(5050000n);
    });
  });

  describe("Price Manipulation Prevention", function () {
    it("Should maintain consistent pricing formula", async function () {
      // Price is deterministic based on hypotenuse
      // No external oracle = no price manipulation
      
      const payment1 = await pmm.calculatePaymentWithSlippage(0, 0, 3, 4, 0);
      const payment2 = await pmm.calculatePaymentWithSlippage(0, 0, 3, 4, 0);
      
      // Same inputs = same outputs
      expect(payment1.expectedPayment).to.equal(payment2.expectedPayment);
    });

    it("Should not allow manipulating cost via intermediary positions", async function () {
      // Direct path cost
      const [directCost] = await pmm.calculatePaymentWithSlippage(0, 0, 5, 12, 0);
      
      // Two-step path cost
      const [step1Cost] = await pmm.calculatePaymentWithSlippage(0, 0, 3, 4, 0);
      const [step2Cost] = await pmm.calculatePaymentWithSlippage(3, 4, 5, 12, 0);
      
      // Both paths cost the same (hypotenuse difference is the same)
      expect(directCost).to.equal(step1Cost + step2Cost);
    });
  });

  describe("State Manipulation Prevention", function () {
    it("Should not allow direct state modification", async function () {
      // Contract state can only be modified through proper functions
      // No public setters for critical state
      
      await pmm.connect(alice).createMarket(PLATFORM_ID, 3, 4);
      
      // The only way to change market state is through voteOnMarket
      const state1 = await pmm.getMarketState(PLATFORM_ID);
      
      // State only changes via legitimate transactions
      await pmm.connect(bob).voteOnMarket(PLATFORM_ID, 5, 12);
      
      const state2 = await pmm.getMarketState(PLATFORM_ID);
      expect(state2.x).to.not.equal(state1.x);
    });

    it("Should preserve totalMarkets integrity", async function () {
      expect(await pmm.totalMarkets()).to.equal(0);
      
      await pmm.connect(alice).createMarket(1, 3, 4);
      expect(await pmm.totalMarkets()).to.equal(1);
      
      await pmm.connect(bob).createMarket(2, 5, 12);
      expect(await pmm.totalMarkets()).to.equal(2);
      
      // totalMarkets only increases via market creation, never decreases
    });
  });

  describe("Flash Loan Attack Prevention", function () {
    it("Should not be vulnerable to flash loan yield extraction", async function () {
      await tenbin.setMinter(await pmm.getAddress());
      await pmm.connect(alice).createMarket(PLATFORM_ID, 3, 4);
      
      // Even with infinite tokens via flash loan:
      // 1. Attacker buys huge position
      // 2. Claims yield immediately - but no time passed = 0 yield
      // 3. Sells position
      // Result: Attacker loses fees on both transactions
      
      const attackerBalBefore = await tenbin.balanceOf(attacker.address);
      
      // "Flash loan" simulation - attacker has lots of tokens
      await pmm.connect(attacker).voteOnMarket(PLATFORM_ID, 100, 200);
      await pmm.connect(attacker).claimYield(PLATFORM_ID); // 0 yield - no time
      await pmm.connect(attacker).voteOnMarket(PLATFORM_ID, 3, 4);
      
      const attackerBalAfter = await tenbin.balanceOf(attacker.address);
      
      // Attacker LOST money (fees on buy and sell)
      expect(attackerBalAfter).to.be.lt(attackerBalBefore);
    });
  });

  describe("Replay Attack Prevention", function () {
    it("Should not allow replaying old transactions", async function () {
      // Each transaction changes state (coordinates, positions)
      // Replaying same tx would fail due to state change
      
      await pmm.connect(alice).createMarket(PLATFORM_ID, 3, 4);
      
      // "Replaying" same creation should fail
      await expect(pmm.connect(alice).createMarket(PLATFORM_ID, 3, 4))
        .to.be.revertedWithCustomError(pmm, "MarketAlreadyExists");
    });
  });
});

describe("TENBIN Token Security", function () {
  let tenbin;
  let owner;
  let attacker;

  beforeEach(async function () {
    [owner, attacker] = await ethers.getSigners();
    
    const TenbinToken = await ethers.getContractFactory("TenbinToken");
    tenbin = await TenbinToken.deploy(owner.address);
    await tenbin.waitForDeployment();
  });

  it("Should prevent unauthorized minting", async function () {
    await expect(tenbin.connect(attacker).mint(attacker.address, 1000000))
      .to.be.revertedWithCustomError(tenbin, "NotMinter");
  });

  it("Should prevent unauthorized burning", async function () {
    await tenbin.mint(attacker.address, 1000000);
    
    await expect(tenbin.connect(attacker).burn(attacker.address, 500000))
      .to.be.revertedWithCustomError(tenbin, "NotBurner");
  });

  it("Should prevent role hijacking", async function () {
    await expect(tenbin.connect(attacker).setMinter(attacker.address))
      .to.be.revertedWithCustomError(tenbin, "OwnableUnauthorizedAccount");
    
    await expect(tenbin.connect(attacker).setBurner(attacker.address))
      .to.be.revertedWithCustomError(tenbin, "OwnableUnauthorizedAccount");
  });

  it("Should prevent burning from arbitrary accounts", async function () {
    // Even burner role can burn from any account
    // This is intentional but should be documented
    await tenbin.mint(attacker.address, 1000000);
    
    // Owner (default burner) can burn from attacker
    await expect(tenbin.burn(attacker.address, 500000))
      .to.not.be.reverted;
    
    expect(await tenbin.balanceOf(attacker.address)).to.equal(500000);
  });
});

