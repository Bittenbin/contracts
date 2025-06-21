const { ethers, upgrades } = require("hardhat");
const readline = require("readline");

// Base Mainnet USDC address
const BASE_MAINNET_USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";

// Create readline interface for user confirmation
const rl = readline.createInterface({
  input: process.stdin,
  output: process.stdout
});

const question = (query) => new Promise((resolve) => rl.question(query, resolve));

async function main() {
  console.log("=================================");
  console.log("BASE MAINNET DEPLOYMENT");
  console.log("=================================\n");

  // Verify we're on Base mainnet
  const chainId = (await ethers.provider.getNetwork()).chainId;
  if (chainId !== 8453n) {
    console.error("❌ ERROR: Not connected to Base Mainnet!");
    console.error(`Current chain ID: ${chainId}, expected: 8453`);
    process.exit(1);
  }

  const [deployer] = await ethers.getSigners();
  const balance = await ethers.provider.getBalance(deployer.address);
  
  console.log("📋 Deployment Configuration:");
  console.log("----------------------------");
  console.log("Network: Base Mainnet");
  console.log("Deployer:", deployer.address);
  console.log("Balance:", ethers.formatEther(balance), "ETH");
  console.log("USDC Address:", BASE_MAINNET_USDC);
  console.log("\n⚠️  IMPORTANT: This is a MAINNET deployment with REAL funds!");
  
  // Check if deployer has enough ETH
  if (balance < ethers.parseEther("0.01")) {
    console.error("\n❌ ERROR: Insufficient ETH balance!");
    console.error("Recommended minimum: 0.01 ETH");
    process.exit(1);
  }

  // Verify USDC contract exists
  const usdcCode = await ethers.provider.getCode(BASE_MAINNET_USDC);
  if (usdcCode === "0x") {
    console.error("\n❌ ERROR: USDC contract not found at expected address!");
    process.exit(1);
  }

  // Get user confirmation
  const answer = await question("\n🚀 Do you want to proceed with deployment? (yes/no): ");
  if (answer.toLowerCase() !== "yes") {
    console.log("\n❌ Deployment cancelled");
    rl.close();
    process.exit(0);
  }

  console.log("\n🔄 Starting deployment...\n");

  try {
    // Deploy PythagoreanMarketMaker as upgradeable proxy
    console.log("📦 Deploying PythagoreanMarketMaker...");
    const PythagoreanMarketMaker = await ethers.getContractFactory("PythagoreanMarketMaker");
    
    const pmm = await upgrades.deployProxy(
      PythagoreanMarketMaker,
      [BASE_MAINNET_USDC],
      { 
        initializer: 'initialize',
        timeout: 0 // No timeout for mainnet
      }
    );
    
    await pmm.waitForDeployment();
    const proxyAddress = await pmm.getAddress();
    
    console.log("✅ PythagoreanMarketMaker deployed to:", proxyAddress);
    
    // Get implementation address
    const implementationAddress = await upgrades.erc1967.getImplementationAddress(proxyAddress);
    console.log("📄 Implementation address:", implementationAddress);
    
    // Verify deployment
    console.log("\n🔍 Verifying deployment...");
    const paymentToken = await pmm.paymentToken();
    const protocolFee = await pmm.PROTOCOL_FEE_BASIS_POINTS();
    const minVotes = await pmm.MINIMUM_VOTES();
    const owner = await pmm.owner();
    
    console.log("Payment token:", paymentToken);
    console.log("Protocol fee:", protocolFee.toString(), "basis points");
    console.log("Minimum votes:", minVotes.toString());
    console.log("Contract owner:", owner);
    
    // Fee recipients
    console.log("\n💰 Fee Recipients:");
    console.log("Owner recipient:", await pmm.ownerFeeRecipient());
    console.log("Protocol recipient:", await pmm.protocolFeeRecipient());
    
    // Save deployment info
    const fs = require("fs");
    const deploymentInfo = {
      network: "base",
      chainId: 8453,
      contracts: {
        PythagoreanMarketMaker: proxyAddress,
        Implementation: implementationAddress,
        PaymentToken: BASE_MAINNET_USDC
      },
      deployer: deployer.address,
      deploymentBlock: await ethers.provider.getBlockNumber(),
      timestamp: new Date().toISOString(),
      gasPrice: (await ethers.provider.getFeeData()).gasPrice?.toString(),
      notes: "Base Mainnet deployment with real USDC"
    };
    
    // Ensure deployments directory exists
    if (!fs.existsSync("deployments")) {
      fs.mkdirSync("deployments");
    }
    
    const deploymentPath = `deployments/deployment-base-mainnet-${Date.now()}.json`;
    fs.writeFileSync(deploymentPath, JSON.stringify(deploymentInfo, null, 2));
    
    console.log("\n✅ Deployment info saved to:", deploymentPath);
    
    console.log("\n=================================");
    console.log("🎉 DEPLOYMENT SUCCESSFUL!");
    console.log("=================================");
    console.log("\n📝 Next Steps:");
    console.log("1. Verify the proxy contract on Basescan:");
    console.log(`   npx hardhat verify --network base ${proxyAddress} ${BASE_MAINNET_USDC}`);
    console.log("\n2. Verify the implementation contract:");
    console.log(`   npx hardhat verify --network base ${implementationAddress}`);
    console.log("\n3. Test with a small market creation");
    console.log("\n4. Transfer ownership to multisig if applicable");
    
    console.log("\n🔗 View on Basescan:");
    console.log(`   https://basescan.org/address/${proxyAddress}`);
    
  } catch (error) {
    console.error("\n❌ Deployment failed:", error);
    process.exit(1);
  } finally {
    rl.close();
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  }); 