const { ethers, upgrades } = require("hardhat");

// Payment token (USDC) and reward token (TENBINIUM)
const PAYMENT_TOKEN_ADDRESS = process.env.PAYMENT_TOKEN_USDC || "";
const REWARD_TOKEN_ADDRESS = process.env.REWARD_TOKEN_TENBIN || "";

async function main() {
  console.log("=================================");
  console.log("ETHEREUM MAINNET DEPLOYMENT");
  console.log("=================================\n");

  // Verify we're on Ethereum mainnet
  const chainId = (await ethers.provider.getNetwork()).chainId;
  if (chainId !== 1n) {
    console.error("❌ ERROR: Not connected to Ethereum Mainnet!");
    console.error(`Current chain ID: ${chainId}, expected: 1`);
    process.exit(1);
  }

  const [deployer] = await ethers.getSigners();
  const balance = await ethers.provider.getBalance(deployer.address);
  
  console.log("📋 Deployment Configuration:");
  console.log("----------------------------");
  console.log("Network: Ethereum Mainnet");
  console.log("Deployer:", deployer.address);
  console.log("Balance:", ethers.formatEther(balance), "ETH");
  console.log("USDC Address:", PAYMENT_TOKEN_ADDRESS || "(required)");
  console.log("TENBINIUM Address (if provided):", REWARD_TOKEN_ADDRESS || "(will deploy)");
  console.log("\n⚠️  IMPORTANT: This is a MAINNET deployment with REAL funds!");
  
  // Check if deployer has enough ETH
  if (balance < ethers.parseEther("0.01")) {
    console.error("\n❌ ERROR: Insufficient ETH balance!");
    console.error("Recommended minimum: 0.01 ETH");
    process.exit(1);
  }

  let paymentTokenAddress = PAYMENT_TOKEN_ADDRESS;
  let rewardTokenAddress;
  let tenbiniumInstance = null;

  if (!paymentTokenAddress) {
    console.error("\n❌ ERROR: PAYMENT_TOKEN_USDC is required!");
    process.exit(1);
  }

  if (process.env.DEPLOY_TENBIN === "true" || !REWARD_TOKEN_ADDRESS) {
    console.log("\nDeploying TENBINIUM token on Ethereum mainnet...");
    const TenbinToken = await ethers.getContractFactory("TenbinToken");
    tenbiniumInstance = await TenbinToken.deploy(deployer.address);
    await tenbiniumInstance.waitForDeployment();
    rewardTokenAddress = await tenbiniumInstance.getAddress();
    console.log("TENBINIUM deployed to:", rewardTokenAddress);
  } else {
    // Verify TENBINIUM contract exists
    const tenbiniumCode = await ethers.provider.getCode(REWARD_TOKEN_ADDRESS);
    if (tenbiniumCode === "0x") {
      console.error("\n❌ ERROR: TENBINIUM contract not found at provided address!");
      process.exit(1);
    }
    rewardTokenAddress = REWARD_TOKEN_ADDRESS;
  }

  console.log("\n🔄 Starting deployment...\n");

  try {
    // Deploy PythagoreanMarketMaker as upgradeable proxy
    console.log("📦 Deploying PythagoreanMarketMaker...");
    const PythagoreanMarketMaker = await ethers.getContractFactory("PythagoreanMarketMaker");
    
    const pmm = await upgrades.deployProxy(
      PythagoreanMarketMaker,
      [paymentTokenAddress, rewardTokenAddress],
      { 
        initializer: 'initialize',
        timeout: 0, // No timeout for mainnet
        txOverrides: {
          gasLimit: 5000000
        }
      }
    );
    
    await pmm.waitForDeployment();
    const proxyAddress = await pmm.getAddress();
    
    console.log("✅ PythagoreanMarketMaker deployed to:", proxyAddress);
    
    // Transfer TENBINIUM minting power to PMM if TENBINIUM was deployed here
    if (tenbiniumInstance) {
      await (await tenbiniumInstance.setMinter(proxyAddress)).wait();
      console.log("TENBINIUM minter set to PMM:", proxyAddress);
    } else {
      console.log("Note: Using existing TENBINIUM; ensure PMM has minting rights if required.");
    }
    
    // Get implementation address
    const implementationAddress = await upgrades.erc1967.getImplementationAddress(proxyAddress);
    console.log("📄 Implementation address:", implementationAddress);
    
    // Verify deployment
    console.log("\n🔍 Verifying deployment...");
    const paymentToken = await pmm.paymentToken();
    const protocolFee = await pmm.PROTOCOL_FEE_BASIS_POINTS();
    const owner = await pmm.owner();
    
    console.log("Payment token:", paymentToken);
    console.log("Protocol fee:", protocolFee.toString(), "basis points");
    console.log("Contract owner:", owner);
    
    // Fee recipients
    console.log("\n💰 Fee Recipients:");
    console.log("Owner recipient:", await pmm.ownerFeeRecipient());
    console.log("Protocol recipient:", await pmm.protocolFeeRecipient());
    
    // Save deployment info
    const fs = require("fs");
    const deploymentInfo = {
      network: "mainnet",
      chainId: 1,
      contracts: {
        PythagoreanMarketMaker: proxyAddress,
        Implementation: implementationAddress,
        PaymentToken: paymentTokenAddress,
        RewardToken: rewardTokenAddress
      },
      deployer: deployer.address,
      deploymentBlock: await ethers.provider.getBlockNumber(),
      timestamp: new Date().toISOString(),
      gasPrice: (await ethers.provider.getFeeData()).gasPrice?.toString(),
      notes: "Ethereum Mainnet deployment with USDC payments and TENBINIUM rewards"
    };
    
    // Ensure deployments directory exists
    if (!fs.existsSync("deployments")) {
      fs.mkdirSync("deployments");
    }
    
    const deploymentPath = `deployments/deployment-eth-mainnet-${Date.now()}.json`;
    fs.writeFileSync(deploymentPath, JSON.stringify(deploymentInfo, null, 2));
    
    console.log("\n✅ Deployment info saved to:", deploymentPath);
    
    console.log("\n=================================");
    console.log("🎉 DEPLOYMENT SUCCESSFUL!");
    console.log("=================================");
    console.log("\n📝 Next Steps:");
    console.log("1. Verify the proxy contract on Etherscan:");
    console.log(`   npx hardhat verify --network mainnet ${proxyAddress} ${paymentTokenAddress} ${rewardTokenAddress}`);
    console.log("\n2. Verify the implementation contract:");
    console.log(`   npx hardhat verify --network mainnet ${implementationAddress}`);
    console.log("\n3. Test with a small market creation");
    console.log("\n4. Transfer ownership to multisig if applicable");
    
    console.log("\n🔗 View on Etherscan:");
    console.log(`   https://etherscan.io/address/${proxyAddress}`);
    
  } catch (error) {
    console.error("\n❌ Deployment failed:", error);
    process.exit(1);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  }); 