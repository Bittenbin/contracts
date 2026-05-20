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

  it("accumulates USDC fees from positive and negative deltaC transactions", async function () {
    const { pmm, alice } = await deployV2();
    const id = agentId("positive-and-negative-fees");

    await pmm.connect(alice).createAgent(id, 20, 21); // c=29, fee=0.29 USDC.
    expect(await pmm.accumulatedProtocolFees()).to.equal(290000n);

    // The refund leg charges 1% against the 24 USDC decrease.
    await pmm.connect(alice).relocateAgent(id, 20, 21, 3, 4);
    expect(await pmm.accumulatedProtocolFees()).to.equal(530000n);
  });

  it("burns 100 TBN to redeem the full USDC fee vault", async function () {
    const { pmm, tbn, mockUSDC, alice, bob } = await deployV2();

    await pmm.connect(alice).createAgent(agentId("fee-vault-solver"), 15, 20);
    await time.increase(YEAR);
    await pmm.connect(alice).claimTBN();

    const vaultBalance = await pmm.accumulatedProtocolFees();
    const bobUsdcBefore = await mockUSDC.balanceOf(bob.address);
    const supplyBefore = await tbn.totalSupply();

    // Redemption is permissionless: Bob can redeem if he holds and approves 100 TBN.
    await tbn.connect(alice).transfer(bob.address, ethers.parseEther("100"));
    await tbn.connect(bob).approve(await pmm.getAddress(), ethers.parseEther("100"));

    await expect(pmm.connect(bob).redeemFeeVault())
      .to.emit(pmm, "FeeVaultRedeemed")
      .withArgs(bob.address, ethers.parseEther("100"), vaultBalance);

    expect(await mockUSDC.balanceOf(bob.address)).to.equal(bobUsdcBefore + vaultBalance);
    expect(await pmm.accumulatedProtocolFees()).to.equal(0);
    expect(await tbn.totalSupply()).to.equal(supplyBefore - ethers.parseEther("100"));
  });

  it("rejects fee vault redemption with zero or insufficient TBN approval", async function () {
    const { pmm, tbn, alice, bob } = await deployV2();

    await pmm.connect(alice).createAgent(agentId("insufficient-approval-redemption"), 15, 20);
    await time.increase(YEAR);
    await pmm.connect(alice).claimTBN();
    await tbn.connect(alice).transfer(bob.address, ethers.parseEther("100"));

    // Holding enough TBN is not enough; PMM must be approved to burn the fixed 100 TBN.
    await tbn.connect(bob).approve(await pmm.getAddress(), 0);
    await expect(pmm.connect(bob).redeemFeeVault()).to.be.reverted;

    await tbn.connect(bob).approve(await pmm.getAddress(), ethers.parseEther("99"));
    await expect(pmm.connect(bob).redeemFeeVault()).to.be.reverted;
  });

  it("burns exactly 100 TBN even when the redeemer approves more", async function () {
    const { pmm, tbn, mockUSDC, alice, bob } = await deployV2();

    await pmm.connect(alice).createAgent(agentId("over-approval-redemption"), 15, 20);
    await time.increase(YEAR);
    await pmm.connect(alice).claimTBN();

    const vaultBalance = await pmm.accumulatedProtocolFees();
    await tbn.connect(alice).transfer(bob.address, ethers.parseEther("101"));
    await tbn.connect(bob).approve(await pmm.getAddress(), ethers.parseEther("101"));

    const bobTbnBefore = await tbn.balanceOf(bob.address);
    const bobUsdcBefore = await mockUSDC.balanceOf(bob.address);

    await pmm.connect(bob).redeemFeeVault();

    expect(bobTbnBefore - await tbn.balanceOf(bob.address)).to.equal(ethers.parseEther("100"));
    expect(await tbn.allowance(bob.address, await pmm.getAddress())).to.equal(ethers.parseEther("1"));
    expect(await mockUSDC.balanceOf(bob.address)).to.equal(bobUsdcBefore + vaultBalance);
    expect(await pmm.accumulatedProtocolFees()).to.equal(0);
  });

  it("rejects empty or unfunded fee vault redemptions", async function () {
    const { pmm, tbn, alice, bob } = await deployV2();

    await expect(pmm.connect(alice).redeemFeeVault())
      .to.be.revertedWithCustomError(pmm, "InvalidFeeAmount");

    await pmm.connect(alice).createAgent(agentId("unfunded-redemption"), 15, 20);

    await expect(pmm.connect(bob).redeemFeeVault()).to.be.reverted;

    await time.increase(YEAR);
    await pmm.connect(alice).claimTBN();
    await tbn.connect(alice).approve(await pmm.getAddress(), ethers.parseEther("100"));
    await pmm.connect(alice).redeemFeeVault();

    await expect(pmm.connect(alice).redeemFeeVault())
      .to.be.revertedWithCustomError(pmm, "InvalidFeeAmount");
  });
});
