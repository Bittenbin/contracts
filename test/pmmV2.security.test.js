const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

const { YEAR, agentId, deployV2 } = require("./helpers/deployV2");

describe("PMM V2 - Security", function () {
  it("reverts stale relocations before executing from an unexpected location", async function () {
    const { pmm, alice } = await deployV2();
    const primaryId = "stale-agent";
    const id = agentId(primaryId);

    await pmm.connect(alice).createAgent(primaryId, 20, 21);
    await pmm.connect(alice).relocateAgent(id, 20, 21, 5, 12);

    // currentX/currentY protect users from executing against stale frontend state.
    await expect(pmm.connect(alice).relocateAgent(id, 20, 21, 16, 63))
      .to.be.revertedWithCustomError(pmm, "StaleLocation")
      .withArgs(5, 12);
  });

  it("prevents selling coordinate exposure the caller does not own", async function () {
    const { pmm, alice, bob } = await deployV2();
    const primaryId = "protected-exposure-agent";
    const id = agentId(primaryId);

    await pmm.connect(alice).createAgent(primaryId, 5, 12);

    // Bob owns no x/y exposure, so he cannot reduce Alice's position.
    await expect(pmm.connect(bob).relocateAgent(id, 5, 12, 3, 4))
      .to.be.revertedWithCustomError(pmm, "InsufficientExposure");
  });

  it("restricts ownership actions to the owner", async function () {
    const { pmm, tbn, alice } = await deployV2();

    await expect(pmm.connect(alice).renounceOwnership())
      .to.be.revertedWithCustomError(pmm, "OwnableUnauthorizedAccount")
      .withArgs(alice.address);
    await expect(tbn.connect(alice).setMinter(alice.address))
      .to.be.revertedWithCustomError(tbn, "OwnableUnauthorizedAccount")
      .withArgs(alice.address);
    await expect(tbn.connect(alice).freezeMinter())
      .to.be.revertedWithCustomError(tbn, "OwnableUnauthorizedAccount")
      .withArgs(alice.address);
  });

  it("allows any TBN holder to redeem the fee vault", async function () {
    const { pmm, tbn, mockUSDC, alice, bob } = await deployV2();

    await pmm.connect(alice).createAgent("permissionless-fee-vault", 15, 20);
    await time.increase(YEAR);
    await pmm.connect(alice).claimTBN();

    const vaultBalance = await pmm.accumulatedProtocolFees();
    const bobUsdcBefore = await mockUSDC.balanceOf(bob.address);

    await tbn.connect(alice).transfer(bob.address, ethers.parseEther("100"));
    await tbn.connect(bob).approve(await pmm.getAddress(), ethers.parseEther("100"));

    await pmm.connect(bob).redeemFeeVault();
    expect(await mockUSDC.balanceOf(bob.address)).to.equal(bobUsdcBefore + vaultBalance);
  });

  it("supports trust-maximized ownership renounce after freezing the TBN minter", async function () {
    const { pmm, tbn, alice } = await deployV2();
    const pmmAddress = await pmm.getAddress();
    const primaryId = "renounced-ownership-agent";
    const id = agentId(primaryId);

    await tbn.freezeMinter();
    await pmm.renounceOwnership();
    await tbn.renounceOwnership();

    expect(await pmm.owner()).to.equal(ethers.ZeroAddress);
    expect(await tbn.owner()).to.equal(ethers.ZeroAddress);
    expect(await tbn.minter()).to.equal(pmmAddress);
    expect(await tbn.minterFrozen()).to.equal(true);

    await pmm.connect(alice).createAgent(primaryId, 15, 20);
    await time.increase(YEAR);
    await expect(pmm.connect(alice).claimTBN()).to.not.be.reverted;
  });
});
