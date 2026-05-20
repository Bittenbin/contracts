const { expect } = require("chai");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

const { agentId, deployV2 } = require("./helpers/deployV2");

describe("PMM V2 - Security", function () {
  it("reverts stale relocations before executing from an unexpected location", async function () {
    const { pmm, alice } = await deployV2();
    const id = agentId("stale-agent");

    await pmm.connect(alice).createAgent(id, 20, 21);
    await pmm.connect(alice).relocateAgent(id, 20, 21, 5, 12);

    // currentX/currentY protect users from executing against stale frontend state.
    await expect(pmm.connect(alice).relocateAgent(id, 20, 21, 16, 63))
      .to.be.revertedWithCustomError(pmm, "StaleLocation")
      .withArgs(5, 12);
  });

  it("prevents selling coordinate exposure the caller does not own", async function () {
    const { pmm, alice, bob } = await deployV2();
    const id = agentId("protected-exposure-agent");

    await pmm.connect(alice).createAgent(id, 5, 12);

    // Bob owns no x/y exposure, so he cannot reduce Alice's position.
    await expect(pmm.connect(bob).relocateAgent(id, 5, 12, 3, 4))
      .to.be.revertedWithCustomError(pmm, "InsufficientExposure");
  });

  it("restricts admin functions to the owner", async function () {
    const { pmm, alice, bob } = await deployV2();

    await expect(pmm.connect(alice).pause()).to.be.reverted;
    await expect(pmm.connect(alice).unpause()).to.be.reverted;
    await expect(pmm.connect(alice).updateFeeRecipient(alice.address)).to.be.reverted;
    await expect(pmm.connect(alice).distributeProtocolFees(0)).to.be.reverted;
  });

  it("pause blocks PMM mutations but still allows reward claims", async function () {
    const { pmm, alice } = await deployV2();
    const id = agentId("paused-claim-agent");

    await pmm.connect(alice).createAgent(id, 15, 20);
    await time.increase(24 * 60 * 60);
    await pmm.pause();

    await expect(pmm.connect(alice).createAgent(agentId("paused-create"), 3, 4)).to.be.reverted;
    await expect(pmm.connect(alice).relocateAgent(id, 15, 20, 3, 4)).to.be.reverted;

    // claimTBN intentionally remains available while PMM movement is paused.
    await expect(pmm.connect(alice).claimTBN()).to.not.be.reverted;
  });
});
