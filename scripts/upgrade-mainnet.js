const { ethers, upgrades } = require("hardhat");
const fs = require("fs");

const PROXY_ADDRESS = process.env.PMM_PROXY_ADDRESS;

async function main() {
  console.log("=================================");
  console.log("BASE MAINNET PROXY UPGRADE");
  console.log("=================================\n");

  const chainId = (await ethers.provider.getNetwork()).chainId;
  if (chainId !== 8453n) {
    console.error("❌ ERROR: Not connected to Base Mainnet!");
    console.error(`Current chain ID: ${chainId}, expected: 8453`);
    process.exit(1);
  }

  if (!PROXY_ADDRESS) {
    console.error("❌ ERROR: PMM_PROXY_ADDRESS is required");
    process.exit(1);
  }

  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", deployer.address);
  console.log("Proxy:", PROXY_ADDRESS);

  const PythagoreanMarketMaker = await ethers.getContractFactory("PythagoreanMarketMaker");
  const previousImplementation = await upgrades.erc1967.getImplementationAddress(PROXY_ADDRESS);

  console.log("\n🚀 Upgrading proxy...");
  const upgraded = await upgrades.upgradeProxy(PROXY_ADDRESS, PythagoreanMarketMaker, {
    timeout: 0,
    unsafeAllowRenames: true
  });

  await upgraded.waitForDeployment();
  const implementation = await upgrades.erc1967.getImplementationAddress(PROXY_ADDRESS);
  const upgradeBlock = await ethers.provider.getBlockNumber();

  console.log("✅ Upgrade complete");
  console.log("Previous implementation:", previousImplementation);
  console.log("New implementation:", implementation);

  console.log("\n🔍 Verifying core reads:");
  console.log("Payment token:", await upgraded.paymentToken());
  console.log("Reward token:", await upgraded.rewardToken());
  console.log("Owner:", await upgraded.owner());

  const deploymentInfo = {
    network: "base",
    chainId: 8453,
    proxy: PROXY_ADDRESS,
    previousImplementation,
    newImplementation: implementation,
    deployer: deployer.address,
    upgradeBlock,
    timestamp: new Date().toISOString(),
    notes: "Base Mainnet proxy upgrade"
  };

  if (!fs.existsSync("deployments")) {
    fs.mkdirSync("deployments");
  }

  const deploymentPath = `deployments/upgrade-base-mainnet-${Date.now()}.json`;
  fs.writeFileSync(deploymentPath, JSON.stringify(deploymentInfo, null, 2));
  console.log("\n✅ Upgrade info saved to:", deploymentPath);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
