const { expect } = require("chai");

const { agentId, deployV2 } = require("./helpers/deployV2");

describe("PMM V2 - Identity", function () {
  it("derives the canonical bytes32 agent ID from the primary ID and emits both", async function () {
    const { pmm, alice } = await deployV2();
    const primaryId = "bittenbin-alice";
    const id = agentId(primaryId);

    await expect(pmm.connect(alice).createAgent(primaryId, 5, 12))
      .to.emit(pmm, "AgentCreated")
      .withArgs(id, primaryId, alice.address, 5, 12, 13);

    const state = await pmm.getAgentState(id);
    expect(state.x).to.equal(5);
    expect(state.y).to.equal(12);
    expect(state.c).to.equal(13);
    expect(state.exists).to.equal(true);
  });

  it("rejects duplicate primary IDs and empty primary IDs", async function () {
    const { pmm, alice } = await deployV2();
    const primaryId = "bittenbin-bob";

    await pmm.connect(alice).createAgent(primaryId, 10, 24);

    await expect(pmm.connect(alice).createAgent(primaryId, 15, 20))
      .to.be.revertedWithCustomError(pmm, "AgentAlreadyExists");

    await expect(pmm.connect(alice).createAgent("", 15, 20))
      .to.be.revertedWithCustomError(pmm, "InvalidPrimaryId");
  });
});
