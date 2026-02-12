const { ethers } = require("hardhat");

const TENBIN_ADDRESS = process.env.REWARD_TOKEN_TENBIN;
const PMM_PROXY_ADDRESS = process.env.PMM_PROXY_ADDRESS;

async function main() {
  console.log("=================================");
  console.log("SET PMM AS TENBIN MINTER");
  console.log("=================================\n");

  const [deployer] = await ethers.getSigners();
  console.log("Caller:", deployer.address);

  if (!TENBIN_ADDRESS || !PMM_PROXY_ADDRESS) {
    console.error("❌ ERROR: REWARD_TOKEN_TENBIN and PMM_PROXY_ADDRESS are required");
    process.exit(1);
  }

  // Get TENBIN contract
  const TenbinToken = await ethers.getContractFactory("TenbinToken");
  const tenbin = TenbinToken.attach(TENBIN_ADDRESS);

  // Check current minter
  const currentMinter = await tenbin.minter();
  console.log("Current minter:", currentMinter);
  console.log("Target minter (PMM):", PMM_PROXY_ADDRESS);

  if (currentMinter.toLowerCase() === PMM_PROXY_ADDRESS.toLowerCase()) {
    console.log("\n✅ PMM is already the minter!");
    return;
  }

  // Set new minter
  console.log("\n📦 Setting PMM as minter...");
  const tx = await tenbin.setMinter(PMM_PROXY_ADDRESS, {
    gasLimit: 100000
  });
  console.log("TX Hash:", tx.hash);
  await tx.wait();

  // Verify
  const newMinter = await tenbin.minter();
  console.log("\n✅ New minter:", newMinter);
  console.log("Success:", newMinter.toLowerCase() === PMM_PROXY_ADDRESS.toLowerCase());
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Error:", error);
    process.exit(1);
  });

