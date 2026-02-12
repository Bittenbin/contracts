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
      // Attempt to use IERC20 for USDC balance
      let usdc;
      try {
        usdc = await ethers.getContractAt("IERC20", paymentToken);
      } catch {
        usdc = await ethers.getContractAt("IERC20", paymentToken);
      }
      
      const usdcBalance = await usdc.balanceOf(signer.address);
      console.log(`USDC Balance: ${ethers.formatUnits(usdcBalance, 6)} USDC`);
      
      // Get PMM contract
      const pmm = await ethers.getContractAt("PythagoreanMarketMaker", deployment.contracts.PythagoreanMarketMaker);
      
      console.log("\n=== Platform Market Info ===");
      console.log("Protocol Fee:", await pmm.PROTOCOL_FEE_BASIS_POINTS(), "basis points (1%)");
      
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
      const sampleUrls = [
        "https://apple.com",
        "https://example.com",
        "https://tenbin.finance"
      ];
      
      for (const url of sampleUrls) {
        const pageId = BigInt(ethers.keccak256(ethers.toUtf8Bytes(url)));
        const exists = await pmm.marketExistsFor(pageId);
        
        if (exists) {
          const state = await pmm.getMarketState(pageId);
          console.log(`\nPage ${url}:`);
          console.log(`  Position: (${state.x}, ${state.y})`);
          console.log(`  Page Score: ${(Number(state.pageScore) / 1e18).toFixed(3)}`);
          console.log(`  Total Votes: ${state.totalVotes}`);
          console.log(`  Creator: ${await pmm.marketCreator(pageId)}`);
          console.log(`  Volume: ${await pmm.totalVoteVolume(pageId)}`);
        } else {
          console.log(`\nPage ${url}: No market exists`);
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