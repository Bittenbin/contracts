const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

const { YEAR, agentId, deployV2 } = require("./helpers/deployV2");

describe("PMM V2 - Integration", function () {
  it("runs an end-to-end solver lifecycle", async function () {
    const { pmm, tbn, alice } = await deployV2();
    const mover = agentId("lifecycle-mover");
    const helper = agentId("lifecycle-helper");

    // Build TVL=64 so moving c=29 -> c=65 creates a valid proof solution.
    await pmm.connect(alice).createAgent(mover, 20, 21);
    await pmm.connect(alice).createAgent(helper, 21, 28);

    await expect(pmm.connect(alice).relocateAgent(mover, 20, 21, 16, 63))
      .to.emit(pmm, "ProofOfProximitySolved")
      .withArgs(alice.address, mover, 16, 63, 36, 6, 100, 6);

    await time.increase(YEAR);
    await pmm.connect(alice).claimTBN();
    // Alice held all solver power for a year, so she should receive almost 1M TBN.
    expect(await tbn.balanceOf(alice.address)).to.be.gt(ethers.parseEther("999999"));

    // Moving back by deltaC=-36 should fully remove Alice's 36 solver power.
    await pmm.connect(alice).relocateAgent(mover, 16, 63, 20, 21);
    expect((await pmm.solverRewards(alice.address)).power).to.equal(0);

    await tbn.connect(alice).approve(await pmm.getAddress(), ethers.parseEther("1"));
    // The previously used proof destination remains permanently marked.
    await expect(pmm.connect(alice).relocateAgent(mover, 20, 21, 16, 63))
      .to.emit(pmm, "TbnBurnedForUsedDestination");
  });

  it("maintains TVL and coordinate lifecycle invariants through a mixed sequence", async function () {
    const { pmm, alice, bob } = await deployV2();
    const a = agentId("stress-a");
    const b = agentId("stress-b");
    const c = agentId("stress-c");

    await pmm.connect(alice).createAgent(a, 3, 4); // c = 5
    await pmm.connect(bob).createAgent(b, 5, 12); // c = 13
    await pmm.connect(alice).createAgent(c, 8, 15); // c = 17
    expect(await pmm.totalStakedValue()).to.equal(35);

    await pmm.connect(alice).relocateAgent(a, 3, 4, 7, 24); // c = 25
    expect(await pmm.totalStakedValue()).to.equal(55);

    await pmm.connect(bob).relocateAgent(b, 5, 12, 20, 21); // c = 29
    expect(await pmm.totalStakedValue()).to.equal(71);

    await pmm.connect(alice).relocateAgent(c, 8, 15, 4, 3); // c = 5
    expect(await pmm.totalStakedValue()).to.equal(59);

    // Coordinate (8,15) was freed by c's move, so it can host another agent.
    await pmm.connect(bob).createAgent(agentId("stress-freed-coordinate"), 8, 15);
    expect(await pmm.totalStakedValue()).to.equal(76);
  });
});
