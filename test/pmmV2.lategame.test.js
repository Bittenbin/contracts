const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

const { YEAR, agentId, deployV2 } = require("./helpers/deployV2");

describe("PMM V2 - Lategame", function () {
  it("follows the long-horizon TBN emission schedule across the year 20 boundary", async function () {
    const { pmm, tbn, alice } = await deployV2();

    // Alice is the only solver, so claimed balance should track cumulative schedule emissions.
    await pmm.connect(alice).createAgent(agentId("long-emission-solver"), 15, 20);
    await time.increase(20 * YEAR);
    await pmm.connect(alice).claimTBN();

    expect(await tbn.balanceOf(alice.address)).to.be.closeTo(
      ethers.parseEther("20000000"),
      ethers.parseEther("2")
    );

    await time.increase(YEAR);
    await pmm.connect(alice).claimTBN();

    // Year 21 emits 500k TBN after the first 20 years of 1M/year emissions.
    expect(await tbn.balanceOf(alice.address)).to.be.closeTo(
      ethers.parseEther("20500000"),
      ethers.parseEther("2")
    );

    await time.increase(YEAR);
    await pmm.connect(alice).claimTBN();

    // Year 22 halves to 250k TBN, and total emitted must remain below the cap.
    expect(await tbn.balanceOf(alice.address)).to.be.closeTo(
      ethers.parseEther("20750000"),
      ethers.parseEther("2")
    );
    expect(await pmm.totalTbnEmitted()).to.be.lte(ethers.parseEther("21000000"));
  });

  it("does not accrue new rewards while total solver power is zero", async function () {
    const { pmm, tbn, alice } = await deployV2();
    const mover = agentId("zero-power-gap-mover");
    const helper = agentId("zero-power-gap-helper");

    await pmm.connect(alice).createAgent(mover, 20, 21); // c = 29
    await pmm.connect(alice).createAgent(helper, 21, 28); // c = 35, TVL = 64
    await pmm.connect(alice).relocateAgent(mover, 20, 21, 16, 63); // power = 36
    await time.increase(YEAR);
    await pmm.connect(alice).claimTBN();
    const balanceAfterFirstClaim = await tbn.balanceOf(alice.address);

    // Removing all power should stop future reward allocation until new power appears.
    await pmm.connect(alice).relocateAgent(mover, 16, 63, 20, 21); // delta = -36, power -> 0

    expect((await pmm.solverRewards(alice.address)).power).to.equal(0);

    const pendingAfterPowerZero = await pmm.pendingTBN(alice.address);
    await time.increase(5 * YEAR);
    // The schedule clock advances, but pending rewards do not grow while totalPower is zero.
    expect(await pmm.pendingTBN(alice.address)).to.equal(pendingAfterPowerZero);
    expect(await tbn.balanceOf(alice.address)).to.equal(balanceAfterFirstClaim);
  });

  it("keeps used destinations persistent and nMax monotonic", async function () {
    const { pmm, tbn, alice } = await deployV2();
    const mover = agentId("persistent-mover");
    const helper = agentId("persistent-helper");

    await pmm.connect(alice).createAgent(mover, 20, 21); // c = 29
    await pmm.connect(alice).createAgent(helper, 21, 28); // c = 35, TVL = 64

    // nMax should increase to 6 on the first valid solution and never decrease.
    await pmm.connect(alice).relocateAgent(mover, 20, 21, 16, 63); // n = 6
    expect(await pmm.nMax()).to.equal(6);

    await time.increase(YEAR);
    await pmm.connect(alice).claimTBN();
    await pmm.connect(alice).relocateAgent(mover, 16, 63, 20, 21);
    expect(await pmm.nMax()).to.equal(6);

    await tbn.connect(alice).approve(await pmm.getAddress(), ethers.parseEther("1"));

    // Used destinations persist across time and occupancy changes.
    await expect(pmm.connect(alice).relocateAgent(mover, 20, 21, 16, 63))
      .to.emit(pmm, "TbnBurnedForUsedDestination")
      .and.to.not.emit(pmm, "ProofOfProximitySolved");

    expect(await pmm.nMax()).to.equal(6);
  });

  it("keeps total emitted and supply bounded near the 21M cap over long horizons", async function () {
    const { pmm, tbn, alice } = await deployV2();

    await pmm.connect(alice).createAgent(agentId("cap-solver"), 15, 20);
    await time.increase(300 * YEAR);
    await pmm.connect(alice).claimTBN();

    expect(await pmm.totalTbnEmitted()).to.be.lte(ethers.parseEther("21000000"));
    expect(await tbn.totalSupply()).to.be.lte(ethers.parseEther("21000000"));
    expect(await tbn.balanceOf(alice.address)).to.be.gt(ethers.parseEther("20999000"));
  });

  it("does not create post-cap rewards for a later solver after the tail has decayed", async function () {
    const { pmm, alice, bob } = await deployV2();

    await pmm.connect(alice).createAgent(agentId("cap-first-solver"), 15, 20);
    await time.increase(300 * YEAR);
    await pmm.connect(alice).claimTBN();

    await pmm.connect(bob).createAgent(agentId("cap-late-solver"), 135, 180);
    await time.increase(YEAR);

    await expect(pmm.connect(bob).claimTBN())
      .to.be.revertedWithCustomError(pmm, "NoRewardsToClaim");
  });

  it("uses the phase-two rate immediately after the year 20 boundary", async function () {
    const { pmm, tbn, alice } = await deployV2();

    await pmm.connect(alice).createAgent(agentId("phase-boundary-solver"), 15, 20);
    await time.increase(20 * YEAR);
    await pmm.connect(alice).claimTBN();
    const balanceAtBoundary = await tbn.balanceOf(alice.address);

    await time.increase(1);
    await pmm.connect(alice).claimTBN();
    const oneSecondReward = await tbn.balanceOf(alice.address) - balanceAtBoundary;
    const phaseTwoPerSecond = ethers.parseEther("500000") / BigInt(YEAR);

    // The second claim transaction can include one or two seconds of elapsed block time.
    expect(oneSecondReward).to.be.gt(0);
    expect(oneSecondReward).to.be.lte(phaseTwoPerSecond * 3n);
  });
});
