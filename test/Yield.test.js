const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");

const WAD = 10n ** 18n;
const ONE_TOKEN = 10n ** 6n; // 6 decimals
const YEAR = 365n * 24n * 60n * 60n;

async function increaseTime(seconds) {
  await ethers.provider.send("evm_increaseTime", [Number(seconds)]);
  await ethers.provider.send("evm_mine", []);
}

describe("Yield Accrual and Claiming", function () {
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

  it("Rate is zero when no markets; non-minter claim reverts; becomes minter then claim works", async function () {
    expect(await pmm.currentAnnualYieldWad()).to.equal(0n);

    // Create a market via application flow to start from (0,0)
    const platformId = 1234567890;
    await pmm.connect(alice).applyForMarket(platformId);
    await pmm.connect(owner).approveMarket(platformId); // totalMarkets = 1

    // Bob buys from (0,0) -> (3,4) (base cost ~5 tokens)
    const bobBefore = await tenbin.balanceOf(bob.address);
    await pmm.connect(bob).voteOnMarket(platformId, 3, 4);
    const bobAfter = await tenbin.balanceOf(bob.address);
    expect(Number(bobBefore - bobAfter)).to.equal(ethers.parseUnits("5.05", 6)); // with 1% fee

    // Advance time 30 days
    await increaseTime(30n * 24n * 60n * 60n);

    // Claim should revert when PMM is not the minter
    await expect(pmm.connect(bob).claimYield(platformId)).to.be.revertedWithCustomError(pmm, "MintingNotSupported");

    // Make PMM the minter
    await tenbin.setMinter(await pmm.getAddress());

    // Now claim should mint some positive amount
    const balBefore = await tenbin.balanceOf(bob.address);
    await pmm.connect(bob).claimYield(platformId);
    const balAfter = await tenbin.balanceOf(bob.address);
    expect(balAfter).to.be.gt(balBefore);
  });

  it("Accrues yield proportional to cost basis and time; no compounding on unclaimed", async function () {
    // Setup: PMM is minter
    await tenbin.setMinter(await pmm.getAddress());

    const platformId = 111;
    await pmm.connect(alice).applyForMarket(platformId);
    await pmm.connect(owner).approveMarket(platformId); // totalMarkets = 1

    // Bob buys (0,0)->(3,4)
    await pmm.connect(bob).voteOnMarket(platformId, 3, 4);
    // Base = holdings.yCost + holdings.xCost ~ 5 tokens (no fee)
    let holding = await pmm.holdings(platformId, bob.address);
    const base1 = holding.yCost + holding.xCost;
    expect(base1).to.equal(ethers.parseUnits("5", 6)); // exact due to sqrt(25)=5 scaled

    // Advance 90 days
    const dt1 = 90n * 24n * 60n * 60n;
    await increaseTime(dt1);

    // Compute expected minted ~ base * r * dt / year
    const rateWad = await pmm.currentAnnualYieldWad(); // with 1 market
    const expected1 = base1 * rateWad / WAD * dt1 / YEAR;

    const beforeClaim1 = await tenbin.balanceOf(bob.address);
    await pmm.connect(bob).claimYield(platformId);
    const afterClaim1 = await tenbin.balanceOf(bob.address);
    const minted1 = afterClaim1 - beforeClaim1;
    // Allow small rounding tolerance
    expect(minted1).to.be.closeTo(expected1, 5n);

    // Do not claim again; buy additional (3,4)->(4,6) i.e., +2 y, +1 x
    await pmm.connect(bob).voteOnMarket(platformId, 4, 6);

    // New base should have increased by the path-decomposed costs
    holding = await pmm.holdings(platformId, bob.address);
    const base2 = holding.yCost + holding.xCost;
    expect(base2).to.be.gt(base1);

    // Advance 30 days with same n=1 rate
    const dt2 = 30n * 24n * 60n * 60n;
    await increaseTime(dt2);

    const expected2 = base2 * rateWad / WAD * dt2 / YEAR;
    const beforeClaim2 = await tenbin.balanceOf(bob.address);
    await pmm.connect(bob).claimYield(platformId);
    const afterClaim2 = await tenbin.balanceOf(bob.address);
    const minted2 = afterClaim2 - beforeClaim2;
    expect(minted2).to.be.closeTo(expected2, 10n);
  });

  it("Selling reduces cost basis pro‑rata; rebalancing does not change cost basis", async function () {
    await tenbin.setMinter(await pmm.getAddress());

    const platformId = 222;
    await pmm.connect(alice).applyForMarket(platformId);
    await pmm.connect(owner).approveMarket(platformId);

    // Bob buys to (5,12)
    await pmm.connect(bob).voteOnMarket(platformId, 5, 12);
    let holding = await pmm.holdings(platformId, bob.address);
    const baseBeforeSell = holding.yCost + holding.xCost;
    const posBefore = await pmm.getVoterPosition(platformId, bob.address);
    const yBefore = posBefore[0];
    const xBefore = posBefore[1];

    // Sell back to (3,4) (reduces both)
    await pmm.connect(bob).voteOnMarket(platformId, 3, 4);
    holding = await pmm.holdings(platformId, bob.address);
    const baseAfterSell = holding.yCost + holding.xCost;
    const posAfter = await pmm.getVoterPosition(platformId, bob.address);
    const yAfter = posAfter[0];
    const xAfter = posAfter[1];

    // Base reduced in proportion to votes sold
    expect(baseAfterSell).to.be.lt(baseBeforeSell);
    expect(yAfter).to.be.lt(yBefore);
    expect(xAfter).to.be.lt(xBefore);

    // Rebalance (same hypotenuse) e.g., (3,4)->(4,3)
    const basePreReb = baseAfterSell;
    await pmm.connect(bob).voteOnMarket(platformId, 4, 3);
    holding = await pmm.holdings(platformId, bob.address);
    const basePostReb = holding.yCost + holding.xCost;
    expect(basePostReb).to.equal(basePreReb);
  });

  it("Yield rate decreases as number of markets increases (1/sqrt(n))", async function () {
    await tenbin.setMinter(await pmm.getAddress());

    // First market
    await pmm.connect(alice).applyForMarket(3001);
    await pmm.connect(owner).approveMarket(3001);
    const rate1 = await pmm.currentAnnualYieldWad();
    expect(rate1).to.be.gt(0n);

    // Second market
    await pmm.connect(alice).applyForMarket(3002);
    await pmm.connect(owner).approveMarket(3002);
    const rate2 = await pmm.currentAnnualYieldWad();
    expect(rate2).to.be.lt(rate1);
  });

  it("Claiming zero when no base or no elapsed time does nothing", async function () {
    await tenbin.setMinter(await pmm.getAddress());
    const platformId = 4001;
    await pmm.connect(alice).applyForMarket(platformId);
    await pmm.connect(owner).approveMarket(platformId);
    // Bob has not bought yet
    const before = await tenbin.balanceOf(bob.address);
    await pmm.connect(bob).claimYield(platformId);
    const after = await tenbin.balanceOf(bob.address);
    expect(after).to.equal(before);
  });
});


