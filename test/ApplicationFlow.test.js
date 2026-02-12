const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { anyValue } = require("@nomicfoundation/hardhat-chai-matchers/withArgs");

describe("Application Workflow", function () {
  let pmm;
  let tenbin;
  let owner, alice, bob;

  beforeEach(async function () {
    [owner, alice, bob] = await ethers.getSigners();
    const TenbinToken = await ethers.getContractFactory("TenbinToken");
    tenbin = await TenbinToken.deploy(owner.address);
    await tenbin.waitForDeployment();

    const PythagoreanMarketMaker = await ethers.getContractFactory("PythagoreanMarketMaker");
    pmm = await upgrades.deployProxy(PythagoreanMarketMaker, [await tenbin.getAddress()], { initializer: 'initialize' });
    await pmm.waitForDeployment();

    // Give allowances
    for (const user of [alice, bob]) {
      await tenbin.mint(user.address, ethers.parseUnits("1000", 6));
      await tenbin.connect(user).approve(await pmm.getAddress(), ethers.parseUnits("1000", 6));
    }
  });

  it("Applicant pays 10 TENBIN fee; owner can approve; market starts at (0,0); first trade sets coordinate", async function () {
    const platformId = Math.floor(Math.random() * 1e12);
    const feeUnits = ethers.parseUnits("10", 6);

    const aliceBefore = await tenbin.balanceOf(alice.address);

    // Apply
    await expect(pmm.connect(alice).applyForMarket(platformId))
      .to.emit(pmm, "MarketApplicationSubmitted")
      .withArgs(platformId, alice.address, feeUnits, anyValue);

    // 10 tokens consumed
    const aliceAfterApply = await tenbin.balanceOf(alice.address);
    expect(aliceBefore - aliceAfterApply).to.equal(feeUnits);

    // Not live yet
    expect(await pmm.marketExistsFor(platformId)).to.equal(false);

    // Approve by owner
    await expect(pmm.connect(owner).approveMarket(platformId))
      .to.emit(pmm, "MarketApplicationApproved");

    // Live now, starting at (0,0)
    expect(await pmm.marketExistsFor(platformId)).to.equal(true);
    const state0 = await pmm.getMarketState(platformId);
    expect(state0.x).to.equal(0);
    expect(state0.y).to.equal(0);

    // First trade by Bob to (3,4) costs 5.05
    const bobBefore = await tenbin.balanceOf(bob.address);
    await pmm.connect(bob).voteOnMarket(platformId, 3, 4);
    const bobAfter = await tenbin.balanceOf(bob.address);
    expect(Number(bobBefore - bobAfter)).to.equal(ethers.parseUnits("5.05", 6));

    const state = await pmm.getMarketState(platformId);
    expect(state.x).to.equal(3);
    expect(state.y).to.equal(4);
  });

  it("Owner can deny; application fee remains consumed", async function () {
    const platformId = Math.floor(Math.random() * 1e12);
    const feeUnits = ethers.parseUnits("10", 6);

    const aliceBefore = await tenbin.balanceOf(alice.address);
    await pmm.connect(alice).applyForMarket(platformId);
    const afterApply = await tenbin.balanceOf(alice.address);
    expect(aliceBefore - afterApply).to.equal(feeUnits);

    await expect(pmm.connect(owner).denyMarket(platformId))
      .to.emit(pmm, "MarketApplicationDenied");

    // Cannot approve/deny again
    await expect(pmm.connect(owner).approveMarket(platformId)).to.be.revertedWithCustomError(pmm, "MarketApplicationNotFound");
    await expect(pmm.connect(owner).denyMarket(platformId)).to.be.revertedWithCustomError(pmm, "MarketApplicationNotFound");
  });

  it("Prevents duplicate applications and applying when market already exists", async function () {
    const platformId = Math.floor(Math.random() * 1e12);
    await pmm.connect(alice).applyForMarket(platformId);
    await expect(pmm.connect(bob).applyForMarket(platformId)).to.be.revertedWithCustomError(pmm, "MarketApplicationExists");

    await pmm.connect(owner).approveMarket(platformId);
    await expect(pmm.connect(alice).applyForMarket(platformId)).to.be.revertedWithCustomError(pmm, "MarketAlreadyExists");
  });
});


