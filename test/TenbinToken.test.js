const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Tenbin Dollar (TBD) Token", function () {
  let owner, alice, bob, carol;
  let tenbin;

  beforeEach(async function () {
    [owner, alice, bob, carol] = await ethers.getSigners();
    const TenbinToken = await ethers.getContractFactory("TenbinToken");
    tenbin = await TenbinToken.deploy(owner.address);
    await tenbin.waitForDeployment();
  });

  it("Should set decimals to 6", async function () {
    expect(await tenbin.decimals()).to.equal(6);
  });

  it("Should mint 1,000,000 TBD to owner at deployment", async function () {
    const initialSupply = ethers.parseUnits("1000000", 6);
    expect(await tenbin.totalSupply()).to.equal(initialSupply);
    expect(await tenbin.balanceOf(owner.address)).to.equal(initialSupply);
  });

  it("Should set name and symbol correctly", async function () {
    expect(await tenbin.name()).to.equal("Tenbin Dollar");
    expect(await tenbin.symbol()).to.equal("TBD");
  });

  it("Owner is default minter and burner", async function () {
    expect(await tenbin.minter()).to.equal(owner.address);
    expect(await tenbin.burner()).to.equal(owner.address);
  });

  it("Only minter can mint; minter role can be reassigned (e.g., to PMM)", async function () {
    // Owner (default minter) mints to Alice
    await expect(tenbin.mint(alice.address, ethers.parseUnits("100", 6)))
      .to.emit(tenbin, "Transfer");
    expect(await tenbin.balanceOf(alice.address)).to.equal(ethers.parseUnits("100", 6));

    // Non-minter cannot mint
    await expect(tenbin.connect(alice).mint(bob.address, 1)).to.be.revertedWithCustomError(tenbin, "NotMinter");

    // Transfer minter to Bob (simulating PMM)
    await expect(tenbin.setMinter(bob.address))
      .to.emit(tenbin, "MinterUpdated")
      .withArgs(owner.address, bob.address);
    expect(await tenbin.minter()).to.equal(bob.address);

    // Old minter can no longer mint
    await expect(tenbin.mint(alice.address, 1)).to.be.revertedWithCustomError(tenbin, "NotMinter");

    // New minter can mint
    await expect(tenbin.connect(bob).mint(alice.address, ethers.parseUnits("50", 6)))
      .to.emit(tenbin, "Transfer");
    expect(await tenbin.balanceOf(alice.address)).to.equal(ethers.parseUnits("150", 6));
  });

  it("Only burner can burn; burner role can be reassigned", async function () {
    // Prepare funds in Alice
    await tenbin.mint(alice.address, ethers.parseUnits("100", 6));
    expect(await tenbin.balanceOf(alice.address)).to.equal(ethers.parseUnits("100", 6));

    // Non-burner cannot burn
    await expect(tenbin.connect(bob).burn(alice.address, 1)).to.be.revertedWithCustomError(tenbin, "NotBurner");

    // Default burner (owner) can burn from any account
    await expect(tenbin.burn(alice.address, ethers.parseUnits("40", 6)))
      .to.emit(tenbin, "Transfer");
    expect(await tenbin.balanceOf(alice.address)).to.equal(ethers.parseUnits("60", 6));

    // Reassign burner to Carol
    await expect(tenbin.setBurner(carol.address))
      .to.emit(tenbin, "BurnerUpdated")
      .withArgs(owner.address, carol.address);
    expect(await tenbin.burner()).to.equal(carol.address);

    // Owner can no longer burn
    await expect(tenbin.burn(alice.address, 1)).to.be.revertedWithCustomError(tenbin, "NotBurner");

    // New burner can burn
    await expect(tenbin.connect(carol).burn(alice.address, ethers.parseUnits("10", 6)))
      .to.emit(tenbin, "Transfer");
    expect(await tenbin.balanceOf(alice.address)).to.equal(ethers.parseUnits("50", 6));
  });

  it("Allows unlimited minting by the current minter (no cap)", async function () {
    const beforeSupply = await tenbin.totalSupply();
    const mintAmount1 = ethers.parseUnits("1000000", 6); // +1,000,000
    const mintAmount2 = ethers.parseUnits("2500000", 6); // +2,500,000

    await tenbin.mint(bob.address, mintAmount1);
    await tenbin.mint(bob.address, mintAmount2);

    const afterSupply = await tenbin.totalSupply();
    expect(afterSupply - beforeSupply).to.equal(mintAmount1 + mintAmount2);
    expect(await tenbin.balanceOf(bob.address)).to.equal(mintAmount1 + mintAmount2);
  });

  it("Ownership transfer does not change minter/burner; new owner can reassign roles", async function () {
    // Transfer ownership to Alice
    await tenbin.transferOwnership(alice.address);
    expect(await tenbin.owner()).to.equal(alice.address);

    // Old owner can no longer call owner-only functions
    await expect(tenbin.setMinter(bob.address))
      .to.be.revertedWithCustomError(tenbin, "OwnableUnauthorizedAccount")
      .withArgs(owner.address);
    await expect(tenbin.setBurner(bob.address))
      .to.be.revertedWithCustomError(tenbin, "OwnableUnauthorizedAccount")
      .withArgs(owner.address);

    // Roles remain unchanged until new owner updates them
    expect(await tenbin.minter()).to.equal(owner.address);
    expect(await tenbin.burner()).to.equal(owner.address);

    // New owner reassigns roles
    await expect(tenbin.connect(alice).setMinter(bob.address))
      .to.emit(tenbin, "MinterUpdated")
      .withArgs(owner.address, bob.address);
    await expect(tenbin.connect(alice).setBurner(carol.address))
      .to.emit(tenbin, "BurnerUpdated")
      .withArgs(owner.address, carol.address);

    expect(await tenbin.minter()).to.equal(bob.address);
    expect(await tenbin.burner()).to.equal(carol.address);
  });

  it("Minting after ownership transfer honors current minter (not owner)", async function () {
    // Transfer ownership to Alice (minter remains old owner at this point)
    await tenbin.transferOwnership(alice.address);

    // Old owner can still mint (still the minter)
    await expect(tenbin.mint(bob.address, ethers.parseUnits("10", 6)))
      .to.emit(tenbin, "Transfer");
    expect(await tenbin.balanceOf(bob.address)).to.equal(ethers.parseUnits("10", 6));

    // New owner cannot mint unless assigned as minter
    await expect(tenbin.connect(alice).mint(bob.address, 1))
      .to.be.revertedWithCustomError(tenbin, "NotMinter");

    // New owner assigns minter to herself
    await tenbin.connect(alice).setMinter(alice.address);
    await expect(tenbin.connect(alice).mint(bob.address, ethers.parseUnits("5", 6)))
      .to.emit(tenbin, "Transfer");
    expect(await tenbin.balanceOf(bob.address)).to.equal(ethers.parseUnits("15", 6));
  });
});


