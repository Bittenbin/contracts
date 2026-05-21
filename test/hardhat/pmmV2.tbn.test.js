const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

const { YEAR, agentId, deployV2 } = require("./helpers/deployV2");

describe("PMM V2 - TBN Rewards", function () {
  it("accrues and claims TBN rewards pro rata by solver power", async function () {
    const { pmm, tbn, alice } = await deployV2();

    // First valid proof starts emissions and gives Alice all solver power.
    await pmm.connect(alice).createAgent("solver-agent", 15, 20);
    await time.increase(YEAR);

    await expect(pmm.connect(alice).claimTBN())
      .to.emit(pmm, "TbnClaimed");

    const balance = await tbn.balanceOf(alice.address);
    // With 100% of power for one year, Alice receives roughly the full annual emission.
    expect(balance).to.be.closeTo(ethers.parseEther("1000000"), ethers.parseEther("1"));
    expect(await tbn.totalSupply()).to.equal(balance);
  });

  it("reduces solver power after negative delta relocations", async function () {
    const { pmm, alice } = await deployV2();
    const primaryId = "solver-agent";
    const id = agentId(primaryId);

    await pmm.connect(alice).createAgent(primaryId, 15, 20); // power = 25
    // Negative deltaC reduces the caller's solver power by abs(deltaC), bounded at zero.
    await pmm.connect(alice).relocateAgent(id, 15, 20, 3, 4); // deltaC = -20

    expect((await pmm.solverRewards(alice.address)).power).to.equal(5);
    expect(await pmm.totalPower()).to.equal(5);
  });

  it("freezes the TBN minter without blocking PMM reward claims", async function () {
    const { pmm, tbn, owner, alice, bob } = await deployV2();

    await expect(tbn.connect(owner).freezeMinter())
      .to.emit(tbn, "MinterFrozenPermanently")
      .withArgs(await pmm.getAddress());

    expect(await tbn.minterFrozen()).to.equal(true);

    await expect(tbn.connect(owner).setMinter(bob.address))
      .to.be.revertedWithCustomError(tbn, "MinterFrozen");

    // Freezing only locks the minter address; PMM can still mint earned rewards.
    await pmm.connect(alice).createAgent("frozen-minter-solver", 15, 20);
    await time.increase(YEAR);
    await expect(pmm.connect(alice).claimTBN()).to.emit(pmm, "TbnClaimed");
  });

  it("does not accrue rewards before the first solver power exists", async function () {
    const { pmm, alice } = await deployV2();

    await time.increase(30 * 24 * 60 * 60);
    await pmm.connect(alice).createAgent("first-power-after-delay", 15, 20);

    expect(await pmm.pendingTBN(alice.address)).to.equal(0);

    await time.increase(24 * 60 * 60);
    expect(await pmm.pendingTBN(alice.address)).to.be.gt(0);
  });

  it("splits rewards by time-weighted solver power across multiple solvers", async function () {
    const { pmm, tbn, alice, bob } = await deployV2();

    await pmm.connect(alice).createAgent("alice-solver", 15, 20); // power = 25
    await pmm.connect(alice).createAgent("tvl-helper", 15, 36); // c = 39, TVL = 64
    await time.increase(10 * 24 * 60 * 60);

    // Bob's c=225 listing makes TVL 289=17^2, so his deltaC=225=15^2 earns power.
    await pmm.connect(bob).createAgent("bob-solver", 135, 180); // power = 225
    await time.increase(20 * 24 * 60 * 60);

    await pmm.connect(alice).claimTBN();
    await pmm.connect(bob).claimTBN();

    const firstWindow = (10n * 24n * 60n * 60n * ethers.parseEther("1000000")) / BigInt(YEAR);
    const secondWindow = (20n * 24n * 60n * 60n * ethers.parseEther("1000000")) / BigInt(YEAR);
    const expectedAlice = firstWindow + ((secondWindow * 25n) / 250n);
    const expectedBob = (secondWindow * 225n) / 250n;

    expect(await tbn.balanceOf(alice.address)).to.be.closeTo(expectedAlice, ethers.parseEther("1"));
    expect(await tbn.balanceOf(bob.address)).to.be.closeTo(expectedBob, ethers.parseEther("1"));
  });

  it("has no pending rewards immediately after claim settlement", async function () {
    const { pmm, tbn, alice } = await deployV2();

    await pmm.connect(alice).createAgent("second-claim", 15, 20);
    await time.increase(YEAR);
    await pmm.connect(alice).claimTBN();

    const balanceAfterFirstClaim = await tbn.balanceOf(alice.address);
    expect(await pmm.pendingTBN(alice.address)).to.equal(0);

    await pmm.connect(alice).claimTBN();

    // A second transaction can mine at a later timestamp and claim only a tiny per-second amount.
    expect(await tbn.balanceOf(alice.address) - balanceAfterFirstClaim).to.be.lt(ethers.parseEther("0.1"));
  });
});
