const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

const { YEAR, agentId, deployV2 } = require("./helpers/deployV2");

describe("PMM V2 - Proof Of Proximity", function () {
  it("automatically solves listing proofs and updates nMax", async function () {
    const { pmm, alice } = await deployV2();

    // Whitepaper listing example: existing TVL is 10 + 30 + 35 = 75.
    await pmm.connect(alice).createAgent("bob", 6, 8);
    await pmm.connect(alice).createAgent("charlie", 18, 24);
    await pmm.connect(alice).createAgent("david", 21, 28);

    const eric = agentId("eric");
    // Eric at c=25 gives deltaC=25=5^2 and new TVL=100=10^2.
    await expect(pmm.connect(alice).createAgent("eric", 15, 20))
      .to.emit(pmm, "ProofOfProximitySolved")
      .withArgs(alice.address, eric, 15, 20, 25, 5, 100, 5);

    expect(await pmm.totalStakedValue()).to.equal(100);
    expect(await pmm.nMax()).to.equal(5);
    expect((await pmm.solverRewards(alice.address)).power).to.equal(25);
  });

  it("uses nMax to determine pairwise connections", async function () {
    const { pmm, alice } = await deployV2();

    await pmm.connect(alice).createAgent("bob", 6, 8);
    await pmm.connect(alice).createAgent("charlie", 18, 24);
    await pmm.connect(alice).createAgent("david", 21, 28);
    await pmm.connect(alice).createAgent("eric", 15, 20);

    // nMax=5 connects Charlie-David and Charlie-Eric, but Bob remains too far away.
    expect(await pmm.areConnected(agentId("charlie"), agentId("david"))).to.equal(true);
    expect(await pmm.areConnected(agentId("bob"), agentId("eric"))).to.equal(false);
  });

  it("automatically solves relocation proofs and does not solve reused destinations again", async function () {
    const { pmm, tbn, alice } = await deployV2();
    const moverPrimaryId = "mover";
    const helperPrimaryId = "helper";
    const mover = agentId(moverPrimaryId);
    const helper = agentId(helperPrimaryId);

    await pmm.connect(alice).createAgent(moverPrimaryId, 20, 21); // c = 29
    await pmm.connect(alice).createAgent(helperPrimaryId, 21, 28); // c = 35, TVL = 64

    // Relocation makes deltaC=36=6^2 and post-transaction TVL=100=10^2.
    await expect(pmm.connect(alice).relocateAgent(mover, 20, 21, 16, 63)) // c = 65, delta = 36, TVL = 100
      .to.emit(pmm, "ProofOfProximitySolved")
      .withArgs(alice.address, mover, 16, 63, 36, 6, 100, 6);

    expect(await pmm.nMax()).to.equal(6);
    expect((await pmm.solverRewards(alice.address)).power).to.equal(36);

    await time.increase(YEAR);
    await pmm.connect(alice).claimTBN();

    await pmm.connect(alice).relocateAgent(mover, 16, 63, 20, 21);
    await tbn.connect(alice).approve(await pmm.getAddress(), ethers.parseEther("1"));

    // Re-entering an already-used proof destination burns TBN and cannot solve again.
    await expect(pmm.connect(alice).relocateAgent(mover, 20, 21, 16, 63))
      .to.emit(pmm, "TbnBurnedForUsedDestination")
      .and.to.not.emit(pmm, "ProofOfProximitySolved");
  });

  it("records used puzzle destinations directly", async function () {
    const { pmm, alice } = await deployV2();
    const primaryId = "used-destination-direct";
    const id = agentId(primaryId);

    const destHash = await pmm.destinationHash(15, 20, 25);
    expect(await pmm.usedPuzzleDestinations(destHash)).to.equal(false);

    await pmm.connect(alice).createAgent(primaryId, 15, 20);

    expect(await pmm.usedPuzzleDestinations(destHash)).to.equal(true);
  });

  it("keeps nMax monotonic across smaller and larger later solutions", async function () {
    const { pmm, tbn, alice } = await deployV2();
    const moverPrimaryId = "monotonic-mover";
    const helperPrimaryId = "monotonic-helper";
    const mover = agentId(moverPrimaryId);
    const helper = agentId(helperPrimaryId);

    await pmm.connect(alice).createAgent(moverPrimaryId, 20, 21); // c = 29
    await pmm.connect(alice).createAgent(helperPrimaryId, 21, 28); // c = 35, TVL = 64
    await pmm.connect(alice).relocateAgent(mover, 20, 21, 16, 63); // n = 6, TVL = 100
    expect(await pmm.nMax()).to.equal(6);

    await time.increase(YEAR);
    await pmm.connect(alice).claimTBN();
    await tbn.connect(alice).approve(await pmm.getAddress(), ethers.parseEther("1"));

    // Reduce TVL to 75, then solve a smaller n=5 listing. nMax should stay at 6.
    await pmm.connect(alice).relocateAgent(helper, 21, 28, 6, 8); // TVL = 75
    await pmm.connect(alice).createAgent("smaller-solution", 15, 20); // n = 5
    expect(await pmm.nMax()).to.equal(6);

    // Add c=5 to set TVL=105, then move c=10 -> c=74 for n=8 and TVL=169.
    await pmm.connect(alice).createAgent("tvl-adjuster", 3, 4);
    await pmm.connect(alice).relocateAgent(helper, 6, 8, 24, 70); // n = 8
    expect(await pmm.nMax()).to.equal(8);
  });
});
