const { ethers } = require("hardhat");

const YEAR = 365 * 24 * 60 * 60;

function agentId(name) {
  // Mirrors protocol identity convention: agent IDs are keccak256(primary ID).
  return ethers.id(name);
}

async function deployV2() {
  const [owner, alice, bob, treasury, protocol] = await ethers.getSigners();

  const MockUSDC = await ethers.getContractFactory("MockUSDC");
  const mockUSDC = await MockUSDC.deploy();
  await mockUSDC.waitForDeployment();

  const Tenbinium = await ethers.getContractFactory("Tenbinium");
  const tbn = await Tenbinium.deploy(owner.address);
  await tbn.waitForDeployment();

  const PythagoreanMarketMakerV2 = await ethers.getContractFactory("PythagoreanMarketMakerV2");
  const pmm = await PythagoreanMarketMakerV2.deploy(
    await mockUSDC.getAddress(),
    await tbn.getAddress(),
    treasury.address,
    protocol.address,
    owner.address
  );
  await pmm.waitForDeployment();

  // PMM v2 is the sole TBN minter; claims mint accrued rewards lazily.
  await tbn.setMinter(await pmm.getAddress());

  // Tests run against a fresh local chain, so every test gets funded wallets and approvals.
  for (const user of [alice, bob]) {
    await mockUSDC.mint(user.address, ethers.parseUnits("1000000", 6));
    await mockUSDC.connect(user).approve(await pmm.getAddress(), ethers.MaxUint256);
  }

  return {
    pmm,
    tbn,
    mockUSDC,
    owner,
    alice,
    bob,
    treasury,
    protocol,
  };
}

module.exports = {
  YEAR,
  agentId,
  deployV2,
};
