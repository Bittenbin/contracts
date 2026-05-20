const { expect } = require("chai");

const { agentId, deployV2 } = require("./helpers/deployV2");

describe("PMM V2 - PMM", function () {
  it("creates agents with bytes32 identity and hypotenuse pricing", async function () {
    const { pmm, mockUSDC, alice } = await deployV2();
    const id = agentId("https://agent.example/alice");
    const balanceBefore = await mockUSDC.balanceOf(alice.address);

    // (3,4,5) should cost 5 USDC plus the 1% protocol fee.
    await expect(pmm.connect(alice).createAgent(id, 3, 4))
      .to.emit(pmm, "AgentCreated")
      .withArgs(id, alice.address, 3, 4, 5);

    const state = await pmm.getAgentState(id);
    expect(state.x).to.equal(3);
    expect(state.y).to.equal(4);
    expect(state.c).to.equal(5);
    expect(state.exists).to.equal(true);
    expect(await pmm.totalStakedValue()).to.equal(5);
    expect(balanceBefore - await mockUSDC.balanceOf(alice.address)).to.equal(5050000n);
  });

  it("relocates agents and updates participant exposure", async function () {
    const { pmm, alice } = await deployV2();
    const id = agentId("relocated-agent");

    await pmm.connect(alice).createAgent(id, 3, 4);
    // Moving from c=5 to c=13 increases exposure by the coordinate deltas.
    await pmm.connect(alice).relocateAgent(id, 3, 4, 5, 12);

    const state = await pmm.getAgentState(id);
    expect(state.x).to.equal(5);
    expect(state.y).to.equal(12);
    expect(state.c).to.equal(13);

    const exposure = await pmm.getExposure(id, alice.address);
    expect(exposure.xExposure).to.equal(5);
    expect(exposure.yExposure).to.equal(12);
    expect(exposure.exists).to.equal(true);
  });

  it("continues normal PMM transactions when proof conditions are not met", async function () {
    const { pmm, alice } = await deployV2();

    // c=13 is not a square delta, so it is a normal listing only.
    await expect(pmm.connect(alice).createAgent(agentId("not-square-delta"), 5, 12))
      .to.not.emit(pmm, "ProofOfProximitySolved");

    await pmm.connect(alice).createAgent(agentId("seed"), 3, 4);

    // deltaC is square here, but post-transaction TVL is not a square.
    await expect(pmm.connect(alice).createAgent(agentId("not-square-tvl"), 15, 20))
      .to.not.emit(pmm, "ProofOfProximitySolved");

    expect(await pmm.nMax()).to.equal(0);
    expect((await pmm.solverRewards(alice.address)).power).to.equal(0);
  });

  it("frees the old coordinate after relocation", async function () {
    const { pmm, alice, bob } = await deployV2();
    const first = agentId("coordinate-lifecycle-first");
    const second = agentId("coordinate-lifecycle-second");

    await pmm.connect(alice).createAgent(first, 3, 4);
    await pmm.connect(alice).relocateAgent(first, 3, 4, 5, 12);

    // (3,4) became available once the first agent moved away.
    await pmm.connect(bob).createAgent(second, 3, 4);

    expect((await pmm.getAgentState(first)).c).to.equal(13);
    expect((await pmm.getAgentState(second)).c).to.equal(5);
    expect(await pmm.totalStakedValue()).to.equal(18);
  });

  it("rejects relocation into an occupied coordinate", async function () {
    const { pmm, alice, bob } = await deployV2();
    const first = agentId("occupied-first");
    const second = agentId("occupied-second");

    await pmm.connect(alice).createAgent(first, 3, 4);
    await pmm.connect(bob).createAgent(second, 5, 12);

    await expect(pmm.connect(alice).relocateAgent(first, 3, 4, 5, 12))
      .to.be.revertedWithCustomError(pmm, "CoordinateOccupied");
  });

  it("rejects invalid and oversized coordinates", async function () {
    const { pmm, alice } = await deployV2();
    const id = agentId("invalid-coordinate-agent");

    await expect(pmm.connect(alice).createAgent(agentId("zero-axis"), 0, 4))
      .to.be.revertedWithCustomError(pmm, "InvalidPythagoreanCoordinate");

    await expect(pmm.connect(alice).createAgent(agentId("non-pythagorean"), 2, 3))
      .to.be.revertedWithCustomError(pmm, "InvalidPythagoreanCoordinate");

    await expect(pmm.connect(alice).createAgent(agentId("oversized"), 1000000001, 4))
      .to.be.revertedWithCustomError(pmm, "CoordinateTooLarge");

    await pmm.connect(alice).createAgent(id, 3, 4);

    await expect(pmm.connect(alice).relocateAgent(id, 3, 4, 2, 3))
      .to.be.revertedWithCustomError(pmm, "InvalidPythagoreanCoordinate");
  });

  it("rejects relocating an existing agent to the origin", async function () {
    const { pmm, alice } = await deployV2();
    const id = agentId("origin-relocation-agent");

    await pmm.connect(alice).createAgent(id, 3, 4);

    // Agents cannot be reduced to (0,0,$0); locations must remain positive triples.
    await expect(pmm.connect(alice).relocateAgent(id, 3, 4, 0, 0))
      .to.be.revertedWithCustomError(pmm, "InvalidPythagoreanCoordinate");

    const state = await pmm.getAgentState(id);
    expect(state.x).to.equal(3);
    expect(state.y).to.equal(4);
    expect(state.c).to.equal(5);
    expect(await pmm.totalStakedValue()).to.equal(5);
  });

  it("keeps totalStakedValue equal to the sum of current agent hypotenuses", async function () {
    const { pmm, alice, bob } = await deployV2();
    const a = agentId("tvl-a");
    const b = agentId("tvl-b");
    const c = agentId("tvl-c");

    const expectTVL = async (expected) => {
      expect(await pmm.totalStakedValue()).to.equal(expected);
    };

    await pmm.connect(alice).createAgent(a, 3, 4); // c = 5
    await expectTVL(5);

    await pmm.connect(bob).createAgent(b, 5, 12); // c = 13
    await expectTVL(18);

    await pmm.connect(alice).createAgent(c, 8, 15); // c = 17
    await expectTVL(35);

    await pmm.connect(alice).relocateAgent(a, 3, 4, 7, 24); // c = 25
    await expectTVL(55);

    await pmm.connect(bob).relocateAgent(b, 5, 12, 20, 21); // c = 29
    await expectTVL(71);

    await pmm.connect(alice).relocateAgent(c, 8, 15, 3, 4); // c = 5
    await expectTVL(59);
  });
});
