const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");

const WAD = 10n ** 18n;
const ONE_TOKEN = 10n ** 6n; // 6 decimals
const YEAR = 365n * 24n * 60n * 60n;
const REWARD_RATE = 31709n; // ~0.0317 TENBIN per second (same as contract constant)

async function increaseTime(seconds) {
  await ethers.provider.send("evm_increaseTime", [Number(seconds)]);
  await ethers.provider.send("evm_mine", []);
}

describe("Staking Rewards (Synthetix O(1) Pattern)", function () {
  let owner, alice, bob, carol;
  let tenbin, pmm;

  beforeEach(async function () {
    [owner, alice, bob, carol] = await ethers.getSigners();
    const TenbinToken = await ethers.getContractFactory("TenbinToken");
    tenbin = await TenbinToken.deploy(owner.address);
    await tenbin.waitForDeployment();

    const PythagoreanMarketMaker = await ethers.getContractFactory("PythagoreanMarketMaker");
    pmm = await upgrades.deployProxy(PythagoreanMarketMaker, [await tenbin.getAddress()], { initializer: "initialize" });
    await pmm.waitForDeployment();

    // Fund users and set approvals
    for (const user of [alice, bob, carol]) {
      await tenbin.mint(user.address, ethers.parseUnits("1000000", 6));
      await tenbin.connect(user).approve(await pmm.getAddress(), ethers.parseUnits("1000000", 6));
    }
  });

  describe("Emission Constants", function () {
    it("Should have correct emission rate (~1M TENBIN/year)", async function () {
      const rate = await pmm.REWARD_RATE();
      expect(rate).to.equal(REWARD_RATE);
      
      // Verify this equals ~1M per year
      const yearlyEmission = rate * YEAR;
      const expectedYearly = ethers.parseUnits("1000000", 6);
      // Allow 0.1% tolerance due to rounding
      expect(yearlyEmission).to.be.closeTo(expectedYearly, expectedYearly / 1000n);
    });

    it("Should have correct max emission (20M TENBIN)", async function () {
      const maxEmission = await pmm.MAX_EMISSION();
      expect(maxEmission).to.equal(ethers.parseUnits("20000000", 6));
    });

    it("Should have correct emission duration (20 years)", async function () {
      const duration = await pmm.EMISSION_DURATION();
      expect(duration).to.equal(20n * YEAR);
    });
  });

  describe("Non-minter claim reverts; becomes minter then claim works", function () {
    it("Should revert if PMM is not minter; work after setting minter", async function () {
      const platformId = 1234567890n;
      await pmm.connect(alice).applyForMarket(platformId);
      await pmm.connect(owner).approveMarket(platformId);

      // Bob buys from (0,0) -> (3,4) (base cost ~5 tokens)
      await pmm.connect(bob).voteOnMarket(platformId, 3, 4);

      // Advance time 30 days
      await increaseTime(30n * 24n * 60n * 60n);

      // Claim should revert when PMM is not the minter
      await expect(pmm.connect(bob).claimRewards()).to.be.revertedWithCustomError(pmm, "MintingNotSupported");

      // Make PMM the minter
      await tenbin.setMinter(await pmm.getAddress());

      // Now claim should mint some positive amount
      const balBefore = await tenbin.balanceOf(bob.address);
      await pmm.connect(bob).claimRewards();
      const balAfter = await tenbin.balanceOf(bob.address);
      expect(balAfter).to.be.gt(balBefore);
    });
  });

  describe("Rewards proportional to stake and time", function () {
    it("Should accrue rewards proportional to cost basis (stake) and time", async function () {
      await tenbin.setMinter(await pmm.getAddress());

      const platformId = 111n;
      await pmm.connect(alice).applyForMarket(platformId);
      await pmm.connect(owner).approveMarket(platformId);

      // Bob buys (0,0)->(3,4) -> cost basis = 5 tokens
      await pmm.connect(bob).voteOnMarket(platformId, 3, 4);
      
      const bobStake = await pmm.userTotalStake(bob.address);
      expect(bobStake).to.equal(ethers.parseUnits("5", 6)); // 5 TENBIN

      // Advance 30 days
      const dt = 30n * 24n * 60n * 60n;
      await increaseTime(dt);

      // Compute expected reward
      // With only Bob staking, he gets all the emission
      // reward = REWARD_RATE * dt
      const expectedReward = REWARD_RATE * dt;

      const earned = await pmm.earned(bob.address);
      // Allow small tolerance due to block timestamp variance
      expect(earned).to.be.closeTo(expectedReward, expectedReward / 100n);

      // Claim and verify
      const balBefore = await tenbin.balanceOf(bob.address);
      await pmm.connect(bob).claimRewards();
      const balAfter = await tenbin.balanceOf(bob.address);
      const minted = balAfter - balBefore;
      expect(minted).to.be.closeTo(expectedReward, expectedReward / 100n);
    });

    it("Should split rewards proportionally between multiple stakers", async function () {
      await tenbin.setMinter(await pmm.getAddress());

      const platformId = 222n;
      await pmm.connect(alice).applyForMarket(platformId);
      await pmm.connect(owner).approveMarket(platformId);

      // Bob stakes 5 tokens (3,4 -> hypotenuse 5)
      await pmm.connect(bob).voteOnMarket(platformId, 3, 4);
      const bobStake = await pmm.userTotalStake(bob.address);
      expect(bobStake).to.equal(ethers.parseUnits("5", 6));

      // Carol stakes ~12 tokens (5,12 -> hypotenuse ~13, minus Bob's 5 = 8 additional)
      // But Carol is voting on same market, so market moves from (3,4) to (8,16)
      // New hypotenuse = sqrt(64+256) = sqrt(320) ≈ 17.89
      // Carol pays: 17.89 - 5 ≈ 12.89 tokens
      await pmm.connect(carol).voteOnMarket(platformId, 8, 16);
      const carolStake = await pmm.userTotalStake(carol.address);
      
      const totalStaked = await pmm.totalStaked();
      expect(totalStaked).to.equal(bobStake + carolStake);

      // Advance 30 days
      const dt = 30n * 24n * 60n * 60n;
      await increaseTime(dt);

      // Total emission for period
      const totalEmission = REWARD_RATE * dt;

      // Bob's share = bobStake / totalStaked
      const bobEarned = await pmm.earned(bob.address);
      const carolEarned = await pmm.earned(carol.address);

      const expectedBobShare = totalEmission * bobStake / totalStaked;
      const expectedCarolShare = totalEmission * carolStake / totalStaked;

      expect(bobEarned).to.be.closeTo(expectedBobShare, expectedBobShare / 50n);
      expect(carolEarned).to.be.closeTo(expectedCarolShare, expectedCarolShare / 50n);
    });
  });

  describe("Stake updates and cost basis tracking", function () {
    it("Should update userTotalStake when buying votes", async function () {
      await tenbin.setMinter(await pmm.getAddress());

      const platformId = 333n;
      await pmm.connect(alice).applyForMarket(platformId);
      await pmm.connect(owner).approveMarket(platformId);

      // Initial stake is 0
      expect(await pmm.userTotalStake(bob.address)).to.equal(0);

      // Bob buys (0,0)->(3,4)
      await pmm.connect(bob).voteOnMarket(platformId, 3, 4);
      const stake1 = await pmm.userTotalStake(bob.address);
      expect(stake1).to.equal(ethers.parseUnits("5", 6));

      // Bob buys more: (3,4)->(6,8) -> new hypotenuse = 10
      await pmm.connect(bob).voteOnMarket(platformId, 6, 8);
      const stake2 = await pmm.userTotalStake(bob.address);
      expect(stake2).to.equal(ethers.parseUnits("10", 6));
    });

    it("Should reduce userTotalStake when selling votes", async function () {
      await tenbin.setMinter(await pmm.getAddress());

      const platformId = 444n;
      await pmm.connect(alice).applyForMarket(platformId);
      await pmm.connect(owner).approveMarket(platformId);

      // Bob buys (0,0)->(6,8) -> hypotenuse = 10
      await pmm.connect(bob).voteOnMarket(platformId, 6, 8);
      const stakeAfterBuy = await pmm.userTotalStake(bob.address);
      expect(stakeAfterBuy).to.equal(ethers.parseUnits("10", 6));

      // Bob sells back to (3,4) -> hypotenuse = 5
      await pmm.connect(bob).voteOnMarket(platformId, 3, 4);
      const stakeAfterSell = await pmm.userTotalStake(bob.address);
      // Pro-rata reduction: stake should be reduced proportionally
      expect(stakeAfterSell).to.be.lt(stakeAfterBuy);
    });

    it("Should not change stake on rebalance (same hypotenuse)", async function () {
      await tenbin.setMinter(await pmm.getAddress());

      const platformId = 555n;
      await pmm.connect(alice).applyForMarket(platformId);
      await pmm.connect(owner).approveMarket(platformId);

      // Bob buys (0,0)->(3,4)
      await pmm.connect(bob).voteOnMarket(platformId, 3, 4);
      const stakeBefore = await pmm.userTotalStake(bob.address);

      // Rebalance to (4,3) - same hypotenuse
      await pmm.connect(bob).voteOnMarket(platformId, 4, 3);
      const stakeAfter = await pmm.userTotalStake(bob.address);

      expect(stakeAfter).to.equal(stakeBefore);
    });
  });

  describe("Multi-platform staking", function () {
    it("Should aggregate stake across multiple platforms", async function () {
      await tenbin.setMinter(await pmm.getAddress());

      // Create two platforms
      await pmm.connect(alice).applyForMarket(1001n);
      await pmm.connect(owner).approveMarket(1001n);
      await pmm.connect(alice).applyForMarket(1002n);
      await pmm.connect(owner).approveMarket(1002n);

      // Bob stakes on platform 1: (0,0)->(3,4) = 5 tokens
      await pmm.connect(bob).voteOnMarket(1001n, 3, 4);
      expect(await pmm.userTotalStake(bob.address)).to.equal(ethers.parseUnits("5", 6));

      // Bob stakes on platform 2: (0,0)->(5,12) = 13 tokens
      await pmm.connect(bob).voteOnMarket(1002n, 5, 12);
      expect(await pmm.userTotalStake(bob.address)).to.equal(ethers.parseUnits("18", 6)); // 5 + 13
    });
  });

  describe("Claiming with no stake", function () {
    it("Should do nothing when user has no stake", async function () {
      await tenbin.setMinter(await pmm.getAddress());
      
      const platformId = 666n;
      await pmm.connect(alice).applyForMarket(platformId);
      await pmm.connect(owner).approveMarket(platformId);

      // Bob has not staked
      const before = await tenbin.balanceOf(bob.address);
      await pmm.connect(bob).claimRewards();
      const after = await tenbin.balanceOf(bob.address);
      expect(after).to.equal(before);
    });
  });

  describe("Backward compatibility", function () {
    it("claimYield(platformId) should work as alias for claimRewards()", async function () {
      await tenbin.setMinter(await pmm.getAddress());

      const platformId = 777n;
      await pmm.connect(alice).applyForMarket(platformId);
      await pmm.connect(owner).approveMarket(platformId);

      await pmm.connect(bob).voteOnMarket(platformId, 3, 4);

      await increaseTime(30n * 24n * 60n * 60n);

      const balBefore = await tenbin.balanceOf(bob.address);
      // Use deprecated claimYield function
      await pmm.connect(bob).claimYield(platformId);
      const balAfter = await tenbin.balanceOf(bob.address);
      expect(balAfter).to.be.gt(balBefore);
    });
  });

  describe("Emission cap enforcement", function () {
    it("Should report correct remaining emission", async function () {
      const maxEmission = await pmm.MAX_EMISSION();
      const remaining = await pmm.remainingEmission();
      expect(remaining).to.equal(maxEmission);
    });

    it("Should report emission active status", async function () {
      expect(await pmm.isEmissionActive()).to.equal(true);
    });
  });

  describe("View functions", function () {
    it("Should return correct emission rate", async function () {
      expect(await pmm.getEmissionRate()).to.equal(REWARD_RATE);
    });

    it("Should return correct rewardPerToken", async function () {
      await tenbin.setMinter(await pmm.getAddress());

      const platformId = 888n;
      await pmm.connect(alice).applyForMarket(platformId);
      await pmm.connect(owner).approveMarket(platformId);

      // Before any stake, rewardPerToken is 0
      expect(await pmm.rewardPerToken()).to.equal(0);

      // Bob stakes
      await pmm.connect(bob).voteOnMarket(platformId, 3, 4);

      // Immediately after staking, rewardPerToken is still 0 (no time elapsed)
      expect(await pmm.rewardPerToken()).to.equal(0);

      // Advance time
      await increaseTime(100);

      // Now rewardPerToken should be positive
      const rpt = await pmm.rewardPerToken();
      expect(rpt).to.be.gt(0);
    });

    it("Should return correct earned amount", async function () {
      await tenbin.setMinter(await pmm.getAddress());

      const platformId = 999n;
      await pmm.connect(alice).applyForMarket(platformId);
      await pmm.connect(owner).approveMarket(platformId);

      // Bob stakes 5 tokens
      await pmm.connect(bob).voteOnMarket(platformId, 3, 4);

      // Advance 1 day
      const dt = 24n * 60n * 60n;
      await increaseTime(dt);

      const earned = await pmm.earned(bob.address);
      const expectedEarned = REWARD_RATE * dt; // Bob is sole staker
      expect(earned).to.be.closeTo(expectedEarned, expectedEarned / 100n);
    });
  });
});
