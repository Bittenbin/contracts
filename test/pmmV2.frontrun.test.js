const { expect } = require("chai");

const { agentId, deployV2 } = require("./helpers/deployV2");

describe("PMM V2 - Frontrunning", function () {
  it("gives solver power to the same-destination listing frontrunner and reverts the victim", async function () {
    const { pmm, mockUSDC, alice, bob } = await deployV2();

    await pmm.connect(alice).createAgent(agentId("bob"), 6, 8);
    await pmm.connect(alice).createAgent(agentId("charlie"), 18, 24);
    await pmm.connect(alice).createAgent(agentId("david"), 21, 28);

    // Alice's balance/power should be unchanged if her copied listing loses the race.
    const aliceUsdcBefore = await mockUSDC.balanceOf(alice.address);
    const aliceTbnPowerBefore = (await pmm.solverRewards(alice.address)).power;
    const bobAgent = agentId("bob-frontrun-agent");
    const aliceAgent = agentId("alice-victim-agent");

    // Bob lands the exact valid solution first and receives the solver power.
    await expect(pmm.connect(bob).createAgent(bobAgent, 15, 20))
      .to.emit(pmm, "ProofOfProximitySolved")
      .withArgs(bob.address, bobAgent, 15, 20, 25, 5, 100, 5);

    // Alice's same-destination transaction reverts before any USDC/TBN side effects.
    await expect(pmm.connect(alice).createAgent(aliceAgent, 15, 20))
      .to.be.revertedWithCustomError(pmm, "CoordinateOccupied");

    expect((await pmm.solverRewards(bob.address)).power).to.equal(25);
    expect((await pmm.solverRewards(alice.address)).power).to.equal(aliceTbnPowerBefore);
    expect(await mockUSDC.balanceOf(alice.address)).to.equal(aliceUsdcBefore);
  });
});
