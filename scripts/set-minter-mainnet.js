const { ethers } = require("hardhat");

const TOKEN_ADDRESS = "0x420331D6396B7290B57Ac4633983FC9a95F9913C";
const PMM_PROXY_ADDRESS = "0x92AcC35FE215a065146F93132cF27D5C3E39D826";

async function main() {
  console.log("=================================");
  console.log("SET PMM AS TOKEN MINTER");
  console.log("=================================\n");

  const [deployer] = await ethers.getSigners();
  console.log("Caller:", deployer.address);

  // Get token contract
  const TenbinToken = await ethers.getContractFactory("TenbinToken");
  const tenbin = TenbinToken.attach(TOKEN_ADDRESS);

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

