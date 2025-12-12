const { ethers } = require("hardhat");
const fs = require("fs");
const path = require("path");

async function main() {
  const [signer] = await ethers.getSigners();
  console.log("Checking balances for:", signer.address);
  console.log("Network:", network.name);
  console.log("Chain ID:", (await ethers.provider.getNetwork()).chainId);
  
  // Get ETH balance
  const ethBalance = await ethers.provider.getBalance(signer.address);
  console.log(`\nETH Balance: ${ethers.formatEther(ethBalance)} ETH`);
  
  // Try to get TENBIN balance if deployment exists
  try {
    // Look for deployment files with new naming pattern
    const deploymentsDir = path.join(__dirname, "../deployments");
    const deploymentFiles = fs.readdirSync(deploymentsDir)
      .filter(f => f.startsWith(`deployment-${network.name}`) && f.endsWith('.json'))
      .sort((a, b) => b.localeCompare(a)); // Sort newest first
    
    if (deploymentFiles.length > 0) {
      const deploymentPath = path.join(deploymentsDir, deploymentFiles[0]);
      const deployment = JSON.parse(fs.readFileSync(deploymentPath, "utf8"));
      
      console.log(`\nUsing deployment from: ${deployment.timestamp}`);
      
      const paymentToken = deployment.contracts.PaymentToken;
      // Attempt to use TenbinToken, fallback to generic ERC20 interface name if ABI mismatch
      let tenbin;
      try {
        tenbin = await ethers.getContractAt("TenbinToken", paymentToken);
      } catch {
        tenbin = await ethers.getContractAt("IERC20", paymentToken);
      }
      
      const tenbinBalance = await tenbin.balanceOf(signer.address);
      console.log(`TENBIN Balance: ${ethers.formatUnits(tenbinBalance, 6)} TENBIN`);
      
      // Get PMM contract
      const pmm = await ethers.getContractAt("PythagoreanMarketMaker", deployment.contracts.PythagoreanMarketMaker);
      
      console.log("\n=== Platform Market Info ===");
      console.log("Protocol Fee:", await pmm.protocolFeeBasisPoints(), "basis points (max:", await pmm.MAX_PROTOCOL_FEE_BASIS_POINTS(), ")");
      console.log("Minimum Votes:", await pmm.MINIMUM_VOTES());
      
      // Get fee recipients
      const feeInfo = await pmm.getFeeDistributionInfo();
      console.log("Owner Fee Recipient:", feeInfo.ownerRecipient);
      console.log("Protocol Fee Recipient:", feeInfo.protocolRecipient);
      console.log("Accumulated Fees:", ethers.formatUnits(feeInfo.pendingFees, 6), "TENBIN");
      
      // Show total markets and yield rate
      try {
        const totalMarkets = await pmm.totalMarkets();
        console.log("Total Markets:", totalMarkets.toString());
        
        if (totalMarkets > 0) {
          const yieldRate = await pmm.currentAnnualYieldWad();
          console.log("Current Annual Yield Rate:", (Number(yieldRate) / 1e18 * 100).toFixed(2) + "%");
        }
      } catch (e) {
        // totalMarkets or yield functions may not exist in older versions
      }
      
      // Example: Check a few platform IDs
      console.log("\n=== Sample Market States ===");
      const samplePlatformIds = [1234567890, 9876543210, 1111111111];
      
      for (const platformId of samplePlatformIds) {
        const exists = await pmm.marketExistsFor(platformId);
        
        if (exists) {
          const state = await pmm.getMarketState(platformId);
          console.log(`\nPlatform ${platformId}:`);
          console.log(`  Position: (${state.x}, ${state.y})`);
          console.log(`  Score: ${(Number(state.score) / 1e18).toFixed(3)}`);
          console.log(`  Total Votes: ${state.totalVotes}`);
          console.log(`  Creator: ${await pmm.marketCreator(platformId)}`);
          console.log(`  Volume: ${await pmm.totalVoteVolume(platformId)}`);
        } else {
          console.log(`\nPlatform ${platformId}: No market exists`);
        }
      }
    } else {
      console.log("\nNo deployment found for this network");
    }
  } catch (error) {
    console.log("\nCould not check contract balances:", error.message);
  }
  
  // Get gas price
  const gasPrice = await ethers.provider.getFeeData();
  console.log(`\nCurrent gas price: ${ethers.formatUnits(gasPrice.gasPrice, "gwei")} gwei`);
  
  // Check if enough ETH for basic transactions
  const estimatedGasForTransfer = 21000n;
  const estimatedCost = gasPrice.gasPrice * estimatedGasForTransfer;
  const hasEnoughForBasicTx = ethBalance > estimatedCost;
  
  console.log(`\nCan afford basic transaction: ${hasEnoughForBasicTx ? '✓ Yes' : '✗ No'}`);
  if (!hasEnoughForBasicTx) {
    console.log(`Minimum ETH needed: ${ethers.formatEther(estimatedCost)}`);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });