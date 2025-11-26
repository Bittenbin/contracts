const { ethers } = require("hardhat");
const readline = require("readline");

const TENBIN_ADDRESS = process.env.PAYMENT_TOKEN || "0x420331D6396B7290B57Ac4633983FC9a95F9913C";

const rl = readline.createInterface({
  input: process.stdin,
  output: process.stdout
});

const question = (query) => new Promise((resolve) => rl.question(query, resolve));

async function main() {
  console.log("=================================");
  console.log("BASE MAINNET SIMPLE DEPLOYMENT");
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
  console.log("TENBIN Address:", TENBIN_ADDRESS);
  console.log("\n⚠️  IMPORTANT: This is a MAINNET deployment!");
  console.log("⚠️  This deploys PMM as NON-UPGRADEABLE for simplicity.");
  
  // Check if deployer has enough ETH
  if (balance < ethers.parseEther("0.005")) {
    console.error("\n❌ ERROR: Insufficient ETH balance!");
    process.exit(1);
  }

  // Verify TENBIN contract exists
  const tenbinCode = await ethers.provider.getCode(TENBIN_ADDRESS);
  if (tenbinCode === "0x") {
    console.error("\n❌ ERROR: TENBIN contract not found at provided address!");
    process.exit(1);
  }
  console.log("✅ TENBIN contract verified at", TENBIN_ADDRESS);

  // Get user confirmation
  const answer = await question("\n🚀 Do you want to proceed? (yes/no): ");
  if (answer.toLowerCase() !== "yes") {
    console.log("\n❌ Deployment cancelled");
    rl.close();
    process.exit(0);
  }

  console.log("\n🔄 Starting deployment...\n");

  try {
    // Deploy PMM Implementation
    console.log("📦 Deploying PythagoreanMarketMaker...");
    const PythagoreanMarketMaker = await ethers.getContractFactory("PythagoreanMarketMaker");
    
    // Deploy with explicit gas settings
    const pmm = await PythagoreanMarketMaker.deploy({
      gasLimit: 8000000
    });
    
    console.log("⏳ Waiting for deployment transaction...");
    console.log("TX Hash:", pmm.deploymentTransaction().hash);
    
    await pmm.waitForDeployment();
    const pmmAddress = await pmm.getAddress();
    console.log("✅ PMM deployed to:", pmmAddress);

    // Initialize the contract
    console.log("\n📦 Initializing PMM...");
    const initTx = await pmm.initialize(TENBIN_ADDRESS, {
      gasLimit: 500000
    });
    console.log("TX Hash:", initTx.hash);
    await initTx.wait();
    console.log("✅ PMM initialized with TENBIN:", TENBIN_ADDRESS);

    // Verify deployment
    console.log("\n🔍 Verifying deployment...");
    const paymentToken = await pmm.paymentToken();
    const protocolFee = await pmm.PROTOCOL_FEE_BASIS_POINTS();
    const minVotes = await pmm.MINIMUM_VOTES();
    const owner = await pmm.owner();
    
    console.log("Payment token:", paymentToken);
    console.log("Protocol fee:", protocolFee.toString(), "basis points (1%)");
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
        PythagoreanMarketMaker: pmmAddress,
        PaymentToken: TENBIN_ADDRESS
      },
      deployer: deployer.address,
      deploymentBlock: await ethers.provider.getBlockNumber(),
      timestamp: new Date().toISOString(),
      notes: "Base Mainnet - Simple deployment (non-proxy)"
    };
    
    if (!fs.existsSync("deployments")) {
      fs.mkdirSync("deployments");
    }
    
    const deploymentPath = `deployments/deployment-base-mainnet-${Date.now()}.json`;
    fs.writeFileSync(deploymentPath, JSON.stringify(deploymentInfo, null, 2));
    
    console.log("\n✅ Deployment info saved to:", deploymentPath);
    
    console.log("\n=================================");
    console.log("🎉 DEPLOYMENT SUCCESSFUL!");
    console.log("=================================");
    
    console.log("\n📋 Contract Addresses:");
    console.log("TENBIN:", TENBIN_ADDRESS);
    console.log("PMM:", pmmAddress);
    
    console.log("\n⚠️  IMPORTANT: Set PMM as TENBIN minter!");
    console.log("Run this command with a script or on Basescan:");
    console.log(`   TenbinToken.setMinter("${pmmAddress}")`);
    
    console.log("\n🔗 View on Basescan:");
    console.log(`   https://basescan.org/address/${pmmAddress}`);
    console.log(`   https://basescan.org/address/${TENBIN_ADDRESS}`);
    
  } catch (error) {
    console.error("\n❌ Deployment failed:", error.message);
    if (error.transaction) {
      console.error("TX Hash:", error.transaction.hash);
    }
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

