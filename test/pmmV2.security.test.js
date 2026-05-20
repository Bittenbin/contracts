const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

const { YEAR, agentId, deployV2 } = require("./helpers/deployV2");

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
    const { pmm, alice } = await deployV2();

    await expect(pmm.connect(alice).pause()).to.be.reverted;
    await expect(pmm.connect(alice).unpause()).to.be.reverted;
  });

  it("allows any TBN holder to redeem the fee vault", async function () {
    const { pmm, tbn, mockUSDC, alice, bob } = await deployV2();

    await pmm.connect(alice).createAgent(agentId("permissionless-fee-vault"), 15, 20);
    await time.increase(YEAR);
    await pmm.connect(alice).claimTBN();

    const vaultBalance = await pmm.accumulatedProtocolFees();
    const bobUsdcBefore = await mockUSDC.balanceOf(bob.address);

    await tbn.connect(alice).transfer(bob.address, ethers.parseEther("100"));
    await tbn.connect(bob).approve(await pmm.getAddress(), ethers.parseEther("100"));

    await pmm.connect(bob).redeemFeeVault();
    expect(await mockUSDC.balanceOf(bob.address)).to.equal(bobUsdcBefore + vaultBalance);
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
