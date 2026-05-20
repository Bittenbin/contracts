const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

const { YEAR, agentId, deployV2 } = require("./helpers/deployV2");

describe("PMM V2 - Fees", function () {
  it("charges 1% USDC fee on positive deltaC transactions", async function () {
    const { pmm, mockUSDC, alice } = await deployV2();
    const id = agentId("fee-agent");
    const balanceBefore = await mockUSDC.balanceOf(alice.address);

    // c=5 listing charges 5 USDC plus 0.05 USDC protocol fee.
    await pmm.connect(alice).createAgent(id, 3, 4);

    expect(balanceBefore - await mockUSDC.balanceOf(alice.address)).to.equal(5050000n);
    expect(await pmm.accumulatedProtocolFees()).to.equal(50000n);
  });

  it("does not charge USDC fee on zero deltaC relocations", async function () {
    const { pmm, mockUSDC, alice } = await deployV2();
    const id = agentId("zero-delta-agent");

    await pmm.connect(alice).createAgent(id, 3, 4);
    const feeBefore = await pmm.accumulatedProtocolFees();
    const balanceBefore = await mockUSDC.balanceOf(alice.address);

    // Same hypotenuse c=5: no USDC payment/refund and no 1% fee.
    await pmm.connect(alice).relocateAgent(id, 3, 4, 4, 3);

    expect(await pmm.accumulatedProtocolFees()).to.equal(feeBefore);
    expect(await mockUSDC.balanceOf(alice.address)).to.equal(balanceBefore);
  });

  it("burns 1 TBN when relocating into a previously used puzzle destination", async function () {
    const { pmm, tbn, alice } = await deployV2();
    const mover = agentId("mover");
    const helper = agentId("helper");

    await pmm.connect(alice).createAgent(mover, 20, 21);
    await pmm.connect(alice).createAgent(helper, 21, 28);
    // This move marks (16,63,65) as a used proof destination.
    await pmm.connect(alice).relocateAgent(mover, 20, 21, 16, 63);

    await time.increase(YEAR);
    await pmm.connect(alice).claimTBN();
    const supplyAfterClaim = await tbn.totalSupply();

    await pmm.connect(alice).relocateAgent(mover, 16, 63, 20, 21);
    await tbn.connect(alice).approve(await pmm.getAddress(), ethers.parseEther("1"));

    // Moving into the previously used destination burns exactly 1 TBN.
    await expect(pmm.connect(alice).relocateAgent(mover, 20, 21, 16, 63))
      .to.emit(pmm, "TbnBurnedForUsedDestination");

    expect(await tbn.totalSupply()).to.equal(supplyAfterClaim - ethers.parseEther("1"));
  });

  it("distributes accumulated protocol fees to the fee recipient", async function () {
    const { pmm, mockUSDC, alice, treasury } = await deployV2();

    await pmm.connect(alice).createAgent(agentId("distribute-fees"), 3, 4);

    const treasuryBefore = await mockUSDC.balanceOf(treasury.address);

    await expect(pmm.distributeProtocolFees(0))
      .to.emit(pmm, "ProtocolFeesDistributed")
      .withArgs(treasury.address, 50000);

    expect(await mockUSDC.balanceOf(treasury.address)).to.equal(treasuryBefore + 50000n);
    expect(await pmm.accumulatedProtocolFees()).to.equal(0);
  });

  it("rejects invalid fee distribution amounts", async function () {
    const { pmm, alice } = await deployV2();

    await expect(pmm.distributeProtocolFees(0))
      .to.be.revertedWithCustomError(pmm, "InvalidFeeAmount");

    await pmm.connect(alice).createAgent(agentId("invalid-fee-amount"), 3, 4);

    await expect(pmm.distributeProtocolFees(50001))
      .to.be.revertedWithCustomError(pmm, "InvalidFeeAmount");
  });

  it("updates the fee recipient and rejects the zero address", async function () {
    const { pmm, bob } = await deployV2();

    await expect(pmm.updateFeeRecipient(bob.address))
      .to.emit(pmm, "FeeRecipientUpdated")
      .withArgs(bob.address);

    expect(await pmm.feeRecipient()).to.equal(bob.address);

    await expect(pmm.updateFeeRecipient(ethers.ZeroAddress))
      .to.be.revertedWithCustomError(pmm, "InvalidAddress");
  });
});
