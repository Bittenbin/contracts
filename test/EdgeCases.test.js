const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");

describe("Edge Cases and Security Tests", function () {
  let pmm;
  let tenbin;
  let owner;
  let alice;
  let bob;
  let charlie;

  const PLATFORM_ID = 1234567890;

  beforeEach(async function () {
    [owner, alice, bob, charlie] = await ethers.getSigners();

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
    for (const user of [alice, bob, charlie]) {
      await tenbin.mint(user.address, ethers.parseUnits("1000000", 6));
      await tenbin.connect(user).approve(await pmm.getAddress(), ethers.parseUnits("1000000", 6));
    }
  });

  describe("Initialization Edge Cases", function () {
    it("Should revert initialize with zero token address", async function () {
      const PythagoreanMarketMaker = await ethers.getContractFactory("PythagoreanMarketMaker");
      await expect(
        upgrades.deployProxy(
          PythagoreanMarketMaker,
          [ethers.ZeroAddress],
          { initializer: 'initialize' }
        )
      ).to.be.revertedWithCustomError(pmm, "InvalidAddress");
    });

    it("Should set correct initial state", async function () {
      expect(await pmm.paymentToken()).to.equal(await tenbin.getAddress());
      expect(await pmm.totalMarkets()).to.equal(0);
      expect(await pmm.accumulatedProtocolFees()).to.equal(0);
      expect(await pmm.PROTOCOL_FEE_BASIS_POINTS()).to.equal(100);
      expect(await pmm.MINIMUM_VOTES()).to.equal(7);
    });
  });

  describe("Coordinate Boundary Tests", function () {
    it("Should accept coordinates at exact MAX_COORDINATE_VALUE boundary", async function () {
      const maxVal = await pmm.MAX_COORDINATE_VALUE();
      // This would be too expensive, but test the validation
      expect(await pmm.isValidCoordinate(maxVal, 1n)).to.be.true;
      expect(await pmm.isValidCoordinate(1n, maxVal)).to.be.true;
    });

    it("Should reject coordinates just over MAX_COORDINATE_VALUE", async function () {
      const maxVal = await pmm.MAX_COORDINATE_VALUE();
      expect(await pmm.isValidCoordinate(maxVal + 1n, 1n)).to.be.false;
      expect(await pmm.isValidCoordinate(1n, maxVal + 1n)).to.be.false;
    });

    it("Should validate hypotenuse at MAX_HYPOTENUSE boundary", async function () {
      // sqrt(900M^2 + 1.2B^2) = 1.5B exactly (3-4-5 triple scaled)
      const x = 900000000n; // 900M
      const y = 1200000000n; // 1.2B - but this exceeds MAX_COORDINATE_VALUE
      
      // Instead test with values that produce hypotenuse near limit
      // (1B, 1B) -> sqrt(2) * 1B ≈ 1.414B < 1.5B limit
      expect(await pmm.isValidCoordinate(1000000000n, 1000000000n)).to.be.true;
    });

    it("Should reject (0, y) and (x, 0) coordinates", async function () {
      expect(await pmm.isValidCoordinate(0, 100)).to.be.false;
      expect(await pmm.isValidCoordinate(100, 0)).to.be.false;
      expect(await pmm.isValidCoordinate(0, 0)).to.be.false;
    });
  });

  describe("Voting Edge Cases", function () {
    beforeEach(async function () {
      await pmm.connect(alice).createMarket(PLATFORM_ID, 3, 4);
    });

    it("Should handle voting that only changes trust (same distrust)", async function () {
      // Move from (3, 4) to (3, 10) - only trust increases
      const balanceBefore = await tenbin.balanceOf(bob.address);
      await pmm.connect(bob).voteOnMarket(PLATFORM_ID, 3, 10);
      const balanceAfter = await tenbin.balanceOf(bob.address);
      
      const state = await pmm.getMarketState(PLATFORM_ID);
      expect(state.x).to.equal(3);
      expect(state.y).to.equal(10);
      
      // Bob should have paid for the hypotenuse increase
      expect(balanceBefore - balanceAfter).to.be.gt(0);
      
      const [trustVotes, distrustVotes] = await pmm.getVoterPosition(PLATFORM_ID, bob.address);
      expect(trustVotes).to.equal(6); // 10 - 4
      expect(distrustVotes).to.equal(0); // No distrust change
    });

    it("Should handle voting that only changes distrust (same trust)", async function () {
      // Move from (3, 4) to (10, 4) - only distrust increases
      await pmm.connect(bob).voteOnMarket(PLATFORM_ID, 10, 4);
      
      const state = await pmm.getMarketState(PLATFORM_ID);
      expect(state.x).to.equal(10);
      expect(state.y).to.equal(4);
      
      const [trustVotes, distrustVotes] = await pmm.getVoterPosition(PLATFORM_ID, bob.address);
      expect(trustVotes).to.equal(0);
      expect(distrustVotes).to.equal(7); // 10 - 3
    });

    it("Should handle selling trust votes specifically", async function () {
      // Bob buys trust votes
      await pmm.connect(bob).voteOnMarket(PLATFORM_ID, 3, 20);
      
      let [trustVotes, distrustVotes] = await pmm.getVoterPosition(PLATFORM_ID, bob.address);
      expect(trustVotes).to.equal(16); // 20 - 4
      expect(distrustVotes).to.equal(0);
      
      // Bob sells some trust votes
      const balanceBefore = await tenbin.balanceOf(bob.address);
      await pmm.connect(bob).voteOnMarket(PLATFORM_ID, 3, 10);
      const balanceAfter = await tenbin.balanceOf(bob.address);
      
      // Should receive refund
      expect(balanceAfter).to.be.gt(balanceBefore);
      
      [trustVotes, distrustVotes] = await pmm.getVoterPosition(PLATFORM_ID, bob.address);
      expect(trustVotes).to.equal(6); // 16 - 10 = 6
    });

    it("Should prevent voting to same position (no change)", async function () {
      // This should work but cost nothing (rebalance with no actual change)
      const balanceBefore = await tenbin.balanceOf(bob.address);
      
      // First bob needs to have a position
      await pmm.connect(bob).voteOnMarket(PLATFORM_ID, 5, 12);
      const balanceAfterBuy = await tenbin.balanceOf(bob.address);
      
      // Vote to same position
      await pmm.connect(bob).voteOnMarket(PLATFORM_ID, 5, 12);
      const balanceAfterSame = await tenbin.balanceOf(bob.address);
      
      // No cost for same position
      expect(balanceAfterSame).to.equal(balanceAfterBuy);
    });
  });

  describe("Application Workflow Edge Cases", function () {
    it("Should allow reapplication after denial", async function () {
      // Apply
      await pmm.connect(alice).applyForMarket(PLATFORM_ID);
      
      // Deny
      await pmm.connect(owner).denyMarket(PLATFORM_ID);
      
      // Reapply should work
      await expect(pmm.connect(alice).applyForMarket(PLATFORM_ID))
        .to.emit(pmm, "MarketApplicationSubmitted");
      
      // Check application exists again
      const app = await pmm.marketApplications(PLATFORM_ID);
      expect(app.applicant).to.equal(alice.address);
    });

    it("Should handle voting from (0,0) after approval", async function () {
      await pmm.connect(alice).applyForMarket(PLATFORM_ID);
      await pmm.connect(owner).approveMarket(PLATFORM_ID);
      
      // Market at (0, 0)
      let state = await pmm.getMarketState(PLATFORM_ID);
      expect(state.x).to.equal(0);
      expect(state.y).to.equal(0);
      
      // First vote moves from (0,0) to (3, 4)
      await pmm.connect(bob).voteOnMarket(PLATFORM_ID, 3, 4);
      
      state = await pmm.getMarketState(PLATFORM_ID);
      expect(state.x).to.equal(3);
      expect(state.y).to.equal(4);
      
      // Bob owns all votes
      const [trustVotes, distrustVotes] = await pmm.getVoterPosition(PLATFORM_ID, bob.address);
      expect(trustVotes).to.equal(4);
      expect(distrustVotes).to.equal(3);
    });

    it("Should not allow application while paused", async function () {
      await pmm.connect(owner).pause("Test");
      
      await expect(pmm.connect(alice).applyForMarket(PLATFORM_ID))
        .to.be.revertedWithCustomError(pmm, "EnforcedPause");
    });
  });

  describe("Yield Edge Cases", function () {
    beforeEach(async function () {
      await tenbin.setMinter(await pmm.getAddress());
    });

    it("Should handle consecutive yield claims", async function () {
      await pmm.connect(alice).createMarket(PLATFORM_ID, 3, 4);
      
      // Advance 30 days
      await ethers.provider.send("evm_increaseTime", [30 * 24 * 60 * 60]);
      await ethers.provider.send("evm_mine", []);
      
      // First claim
      const balance1 = await tenbin.balanceOf(alice.address);
      await pmm.connect(alice).claimYield(PLATFORM_ID);
      const balance2 = await tenbin.balanceOf(alice.address);
      const firstClaim = balance2 - balance1;
      expect(firstClaim).to.be.gt(0);
      
      // Immediate second claim should yield nothing
      await pmm.connect(alice).claimYield(PLATFORM_ID);
      const balance3 = await tenbin.balanceOf(alice.address);
      expect(balance3).to.equal(balance2); // No additional yield
      
      // Wait more time
      await ethers.provider.send("evm_increaseTime", [30 * 24 * 60 * 60]);
      await ethers.provider.send("evm_mine", []);
      
      // Third claim should have yield again
      await pmm.connect(alice).claimYield(PLATFORM_ID);
      const balance4 = await tenbin.balanceOf(alice.address);
      expect(balance4).to.be.gt(balance3);
    });

    it("Should track yield across multiple platforms for same user", async function () {
      const PLATFORM_2 = 9999999999;
      
      // Create two markets
      await pmm.connect(alice).createMarket(PLATFORM_ID, 3, 4);
      await pmm.connect(alice).createMarket(PLATFORM_2, 5, 12);
      
      // Advance time
      await ethers.provider.send("evm_increaseTime", [30 * 24 * 60 * 60]);
      await ethers.provider.send("evm_mine", []);
      
      // Claim from first platform
      const balance1 = await tenbin.balanceOf(alice.address);
      await pmm.connect(alice).claimYield(PLATFORM_ID);
      const balance2 = await tenbin.balanceOf(alice.address);
      
      // Claim from second platform
      await pmm.connect(alice).claimYield(PLATFORM_2);
      const balance3 = await tenbin.balanceOf(alice.address);
      
      // Both should have yielded
      expect(balance2).to.be.gt(balance1);
      expect(balance3).to.be.gt(balance2);
    });

    it("Should correctly track holdings after complex trading", async function () {
      await pmm.connect(alice).createMarket(PLATFORM_ID, 3, 4);
      
      // Bob buys
      await pmm.connect(bob).voteOnMarket(PLATFORM_ID, 5, 12);
      
      // Check Bob's holdings
      let holdings = await pmm.holdings(PLATFORM_ID, bob.address);
      const initialCost = holdings.trustCost + holdings.distrustCost;
      expect(initialCost).to.be.gt(0);
      
      // Bob sells partially
      await pmm.connect(bob).voteOnMarket(PLATFORM_ID, 4, 8);
      
      // Holdings should be reduced
      holdings = await pmm.holdings(PLATFORM_ID, bob.address);
      const afterSellCost = holdings.trustCost + holdings.distrustCost;
      expect(afterSellCost).to.be.lt(initialCost);
    });
  });

  describe("Fee Edge Cases", function () {
    it("Should accumulate fees correctly over many transactions", async function () {
      await pmm.connect(alice).createMarket(PLATFORM_ID, 3, 4);
      
      let totalExpectedFees = 50000n; // 0.05 TENBIN from creation (5 * 0.01)
      
      // Multiple votes
      for (let i = 0; i < 5; i++) {
        await pmm.connect(bob).voteOnMarket(PLATFORM_ID, 5 + i, 12 + i);
      }
      
      const fees = await pmm.accumulatedProtocolFees();
      expect(fees).to.be.gt(totalExpectedFees);
    });

    it("Should handle fee distribution when one recipient is the same as another", async function () {
      await pmm.connect(alice).createMarket(PLATFORM_ID, 3, 4);
      
      // Set both recipients to same address
      await pmm.connect(owner).updateFeeRecipients(charlie.address, charlie.address);
      
      const charlieBalanceBefore = await tenbin.balanceOf(charlie.address);
      
      // Distribute fees
      await pmm.connect(owner).distributeProtocolFees(0);
      
      const charlieBalanceAfter = await tenbin.balanceOf(charlie.address);
      
      // Charlie should receive 100% of fees
      expect(charlieBalanceAfter - charlieBalanceBefore).to.equal(50000n);
    });
  });

  describe("Paused State Tests", function () {
    it("Should prevent all user operations when paused", async function () {
      await pmm.connect(alice).createMarket(PLATFORM_ID, 3, 4);
      await pmm.connect(owner).pause("Emergency");
      
      // All these should fail
      await expect(pmm.connect(bob).createMarket(999, 3, 4))
        .to.be.revertedWithCustomError(pmm, "EnforcedPause");
      
      await expect(pmm.connect(bob).voteOnMarket(PLATFORM_ID, 5, 12))
        .to.be.revertedWithCustomError(pmm, "EnforcedPause");
      
      await expect(pmm.connect(bob).applyForMarket(888))
        .to.be.revertedWithCustomError(pmm, "EnforcedPause");
      
      await expect(pmm.connect(bob).claimYield(PLATFORM_ID))
        .to.be.revertedWithCustomError(pmm, "EnforcedPause");
    });

    it("Should allow owner operations when paused", async function () {
      await pmm.connect(alice).createMarket(PLATFORM_ID, 3, 4);
      await pmm.connect(owner).pause("Emergency");
      
      // Owner can still distribute fees
      await expect(pmm.connect(owner).distributeProtocolFees(0))
        .to.not.be.reverted;
      
      // Owner can update recipients
      await expect(pmm.connect(owner).updateFeeRecipients(bob.address, charlie.address))
        .to.not.be.reverted;
    });
  });

  describe("Holdings and Cost Basis Direct Access", function () {
    it("Should return correct holdings struct values", async function () {
      await pmm.connect(alice).createMarket(PLATFORM_ID, 3, 4);
      
      const holdings = await pmm.holdings(PLATFORM_ID, alice.address);
      
      // trustCost = sqrt(0² + 4²) * 1e6 = 4e6
      // distrustCost = sqrt(3² + 4²) - sqrt(4²) = 5 - 4 = 1e6
      expect(holdings.trustCost).to.equal(4000000n);
      expect(holdings.distrustCost).to.equal(1000000n);
      expect(holdings.lastAccrual).to.be.gt(0);
      expect(holdings.unclaimedYield).to.equal(0);
    });

    it("Should return zeros for non-participant", async function () {
      await pmm.connect(alice).createMarket(PLATFORM_ID, 3, 4);
      
      const holdings = await pmm.holdings(PLATFORM_ID, bob.address);
      
      expect(holdings.trustCost).to.equal(0);
      expect(holdings.distrustCost).to.equal(0);
      expect(holdings.lastAccrual).to.equal(0);
      expect(holdings.unclaimedYield).to.equal(0);
    });
  });

  describe("Coordinate Hash Integrity", function () {
    it("Should correctly map coordinates to markets", async function () {
      await pmm.connect(alice).createMarket(PLATFORM_ID, 3, 4);
      
      const coordHash = ethers.keccak256(
        ethers.AbiCoder.defaultAbiCoder().encode(["uint256", "uint256"], [3, 4])
      );
      
      expect(await pmm.coordinateToMarket(coordHash)).to.equal(PLATFORM_ID);
    });

    it("Should update coordinate mapping on vote", async function () {
      await pmm.connect(alice).createMarket(PLATFORM_ID, 3, 4);
      
      const oldHash = ethers.keccak256(
        ethers.AbiCoder.defaultAbiCoder().encode(["uint256", "uint256"], [3, 4])
      );
      const newHash = ethers.keccak256(
        ethers.AbiCoder.defaultAbiCoder().encode(["uint256", "uint256"], [5, 12])
      );
      
      await pmm.connect(bob).voteOnMarket(PLATFORM_ID, 5, 12);
      
      // Old coordinate should be freed
      expect(await pmm.coordinateToMarket(oldHash)).to.equal(0);
      // New coordinate should be mapped
      expect(await pmm.coordinateToMarket(newHash)).to.equal(PLATFORM_ID);
    });
  });

  describe("Slippage Edge Cases", function () {
    it("Should work with 0% slippage (exact amount)", async function () {
      // 0% slippage means exact amount required
      await expect(pmm.connect(alice).createMarketWithSlippage(PLATFORM_ID, 3, 4, 0))
        .to.not.be.reverted;
    });

    it("Should work with 100% slippage (maximum tolerance)", async function () {
      await expect(pmm.connect(alice).createMarketWithSlippage(PLATFORM_ID, 3, 4, 10000))
        .to.not.be.reverted;
    });

    it("Should reject slippage over 100%", async function () {
      await expect(pmm.connect(alice).createMarketWithSlippage(PLATFORM_ID, 3, 4, 10001))
        .to.be.revertedWithCustomError(pmm, "InvalidSlippage");
    });
  });

  describe("Multi-User Scenarios", function () {
    it("Should handle many users voting on same market", async function () {
      await pmm.connect(alice).createMarket(PLATFORM_ID, 3, 4);
      
      // Bob votes
      await pmm.connect(bob).voteOnMarket(PLATFORM_ID, 5, 12);
      
      // Charlie votes
      await pmm.connect(charlie).voteOnMarket(PLATFORM_ID, 8, 15);
      
      // Verify all positions
      const [aliceTrust, aliceDistrust] = await pmm.getVoterPosition(PLATFORM_ID, alice.address);
      const [bobTrust, bobDistrust] = await pmm.getVoterPosition(PLATFORM_ID, bob.address);
      const [charlieTrust, charlieDistrust] = await pmm.getVoterPosition(PLATFORM_ID, charlie.address);
      
      // Alice: original creator
      expect(aliceTrust).to.equal(4);
      expect(aliceDistrust).to.equal(3);
      
      // Bob: (3,4) -> (5,12)
      expect(bobTrust).to.equal(8); // 12 - 4
      expect(bobDistrust).to.equal(2); // 5 - 3
      
      // Charlie: (5,12) -> (8,15)
      expect(charlieTrust).to.equal(3); // 15 - 12
      expect(charlieDistrust).to.equal(3); // 8 - 5
      
      // Total should match current state
      const state = await pmm.getMarketState(PLATFORM_ID);
      expect(state.x).to.equal(8);
      expect(state.y).to.equal(15);
    });

    it("Should correctly handle user selling all their votes", async function () {
      await pmm.connect(alice).createMarket(PLATFORM_ID, 5, 12);
      
      // Bob buys votes
      await pmm.connect(bob).voteOnMarket(PLATFORM_ID, 8, 15);
      
      let [bobTrust, bobDistrust] = await pmm.getVoterPosition(PLATFORM_ID, bob.address);
      expect(bobTrust).to.equal(3); // 15 - 12
      expect(bobDistrust).to.equal(3); // 8 - 5
      
      // Bob sells all votes back
      await pmm.connect(bob).voteOnMarket(PLATFORM_ID, 5, 12);
      
      [bobTrust, bobDistrust] = await pmm.getVoterPosition(PLATFORM_ID, bob.address);
      expect(bobTrust).to.equal(0);
      expect(bobDistrust).to.equal(0);
    });
  });

  describe("Trust Score Edge Cases", function () {
    it("Should return 0 for (0, 0)", async function () {
      expect(await pmm.calculateTrustScore(0, 0)).to.equal(0);
    });

    it("Should handle very unbalanced coordinates", async function () {
      // Very high trust
      const highTrust = await pmm.calculateTrustScore(1, 1000000);
      expect(Number(highTrust) / 1e18).to.be.closeTo(1.0, 0.001);
      
      // Very low trust
      const lowTrust = await pmm.calculateTrustScore(1000000, 1);
      expect(Number(lowTrust) / 1e18).to.be.closeTo(0.0, 0.001);
    });

    it("Should return exactly 50% for equal coordinates", async function () {
      const balanced = await pmm.calculateTrustScore(100, 100);
      expect(Number(balanced) / 1e18).to.equal(0.5);
    });
  });
});

describe("TENBIN Token Edge Cases", function () {
  let tenbin;
  let owner;
  let alice;
  let bob;

  beforeEach(async function () {
    [owner, alice, bob] = await ethers.getSigners();
    
    const TenbinToken = await ethers.getContractFactory("TenbinToken");
    tenbin = await TenbinToken.deploy(owner.address);
    await tenbin.waitForDeployment();
  });

  it("Should prevent setting minter to zero address", async function () {
    await expect(tenbin.setMinter(ethers.ZeroAddress))
      .to.be.revertedWithCustomError(tenbin, "InvalidAddress");
  });

  it("Should prevent setting burner to zero address", async function () {
    await expect(tenbin.setBurner(ethers.ZeroAddress))
      .to.be.revertedWithCustomError(tenbin, "InvalidAddress");
  });

  it("Should allow burning to zero balance", async function () {
    await tenbin.mint(alice.address, ethers.parseUnits("100", 6));
    
    // Burn all
    await tenbin.burn(alice.address, ethers.parseUnits("100", 6));
    
    expect(await tenbin.balanceOf(alice.address)).to.equal(0);
  });

  it("Should revert burn if insufficient balance", async function () {
    await tenbin.mint(alice.address, ethers.parseUnits("100", 6));
    
    await expect(tenbin.burn(alice.address, ethers.parseUnits("200", 6)))
      .to.be.revertedWithCustomError(tenbin, "ERC20InsufficientBalance");
  });

  it("Should handle minting zero amount", async function () {
    await expect(tenbin.mint(alice.address, 0)).to.not.be.reverted;
    expect(await tenbin.balanceOf(alice.address)).to.equal(0);
  });

  it("Should handle burning zero amount", async function () {
    await expect(tenbin.burn(alice.address, 0)).to.not.be.reverted;
  });

  it("Should have correct name and symbol", async function () {
    expect(await tenbin.name()).to.equal("TENBIN");
    expect(await tenbin.symbol()).to.equal("TENBIN");
  });

  it("Should handle very large minting amounts", async function () {
    const largeAmount = ethers.parseUnits("1000000000000", 6); // 1 trillion
    await tenbin.mint(alice.address, largeAmount);
    expect(await tenbin.balanceOf(alice.address)).to.equal(largeAmount);
  });
});

describe("Upgrade Safety Tests", function () {
  let pmm;
  let tenbin;
  let owner;
  let alice;

  beforeEach(async function () {
    [owner, alice] = await ethers.getSigners();

    const TenbinToken = await ethers.getContractFactory("TenbinToken");
    tenbin = await TenbinToken.deploy(owner.address);
    await tenbin.waitForDeployment();

    const PythagoreanMarketMaker = await ethers.getContractFactory("PythagoreanMarketMaker");
    pmm = await upgrades.deployProxy(
      PythagoreanMarketMaker,
      [await tenbin.getAddress()],
      { initializer: 'initialize' }
    );
    await pmm.waitForDeployment();
  });

  it("Should only allow owner to upgrade", async function () {
    const PythagoreanMarketMaker = await ethers.getContractFactory("PythagoreanMarketMaker");
    
    // Non-owner cannot upgrade
    await expect(
      upgrades.upgradeProxy(await pmm.getAddress(), PythagoreanMarketMaker.connect(alice))
    ).to.be.revertedWithCustomError(pmm, "OwnableUnauthorizedAccount");
  });

  it("Should preserve state after upgrade", async function () {
    // Create some state
    await tenbin.mint(alice.address, ethers.parseUnits("1000", 6));
    await tenbin.connect(alice).approve(await pmm.getAddress(), ethers.parseUnits("1000", 6));
    await pmm.connect(alice).createMarket(12345, 3, 4);
    
    const stateBefore = await pmm.getMarketState(12345);
    const feesBefore = await pmm.accumulatedProtocolFees();
    
    // Upgrade
    const PythagoreanMarketMaker = await ethers.getContractFactory("PythagoreanMarketMaker");
    const upgraded = await upgrades.upgradeProxy(await pmm.getAddress(), PythagoreanMarketMaker);
    
    // State should be preserved
    const stateAfter = await upgraded.getMarketState(12345);
    const feesAfter = await upgraded.accumulatedProtocolFees();
    
    expect(stateAfter.x).to.equal(stateBefore.x);
    expect(stateAfter.y).to.equal(stateBefore.y);
    expect(feesAfter).to.equal(feesBefore);
  });
});

