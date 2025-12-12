const { ethers } = require("hardhat");
const fs = require("fs");
const path = require("path");

async function main() {
  const [signer] = await ethers.getSigners();
  console.log("Checking balances for:", signer.address);
  console.log("Network:", network.name);
  const chainId = (await ethers.provider.getNetwork()).chainId;
  console.log("Chain ID:", chainId);
  
  // Get ETH balance
  const ethBalance = await ethers.provider.getBalance(signer.address);
  console.log(`\nETH Balance: ${ethers.formatEther(ethBalance)} ETH`);
  
  // Try to get TBD balance if deployment exists
  try {
    const deploymentsDir = path.join(__dirname, "../deployments");

    if (!fs.existsSync(deploymentsDir)) {
      console.log("\nNo deployments directory found:", deploymentsDir);
      return;
    }

    const deploymentFiles = fs
      .readdirSync(deploymentsDir)
      .filter((f) => f.startsWith("deployment-") && f.endsWith(".json"));

    // Prefer deployments that match the current chainId (if present), otherwise match by network name.
    const candidates = [];
    for (const file of deploymentFiles) {
      const deploymentPath = path.join(deploymentsDir, file);
      try {
        const deployment = JSON.parse(fs.readFileSync(deploymentPath, "utf8"));
        const stat = fs.statSync(deploymentPath);
        const matchesChainId =
          deployment.chainId !== undefined && BigInt(deployment.chainId) === chainId;
        const matchesNetwork = deployment.network === network.name;
        if (matchesChainId || matchesNetwork) {
          candidates.push({
            file,
            deploymentPath,
            deployment,
            mtimeMs: stat.mtimeMs,
            matchesChainId,
            matchesNetwork,
          });
        }
      } catch {
        // Ignore unreadable/bad JSON
      }
    }
    
    if (candidates.length > 0) {
      candidates.sort((a, b) => b.mtimeMs - a.mtimeMs);
      // If any candidate matches chainId, prefer those over network-only matches.
      const chainMatches = candidates.filter((c) => c.matchesChainId);
      const chosen = (chainMatches.length > 0 ? chainMatches : candidates)[0];
      const deployment = chosen.deployment;

      console.log(`\nUsing deployment file: ${chosen.file}`);
      if (deployment.timestamp) {
        console.log(`Deployment timestamp: ${deployment.timestamp}`);
      }
      
      const paymentToken = deployment.contracts.PaymentToken;
      // Attempt to use TenbinToken, fallback to generic ERC20 interface name if ABI mismatch
      let tenbin;
      try {
        tenbin = await ethers.getContractAt("TenbinToken", paymentToken);
      } catch {
        tenbin = await ethers.getContractAt("IERC20", paymentToken);
      }

      // Token sanity checks (best-effort; some fields only exist on TenbinToken)
      console.log("\n=== Token Sanity Checks ===");
      try {
        const name = await tenbin.name();
        const symbol = await tenbin.symbol();
        const decimals = await tenbin.decimals();
        const totalSupply = await tenbin.totalSupply();
        console.log("Token:", `${name} (${symbol})`);
        console.log("Decimals:", decimals.toString());
        console.log("Total Supply:", ethers.formatUnits(totalSupply, decimals), symbol);
        // Expected initial supply for Tenbin Dollar is 11,110,000 (6 decimals)
        if (decimals === 6n && totalSupply !== 11110000n * 10n ** 6n) {
          console.log("⚠️  Unexpected totalSupply (expected 11,110,000.000000)");
        }
      } catch (e) {
        console.log("Could not read ERC20 metadata/totalSupply:", e.message);
      }
      
      const tenbinBalance = await tenbin.balanceOf(signer.address);
      console.log(`TBD Balance: ${ethers.formatUnits(tenbinBalance, 6)} TBD`);
      
      // Get PMM contract
      const pmm = await ethers.getContractAt("PythagoreanMarketMaker", deployment.contracts.PythagoreanMarketMaker);

      // Verify PMM is configured to use this token
      try {
        const pmmToken = await pmm.paymentToken();
        console.log("\nPMM.paymentToken():", pmmToken);
        console.log("Matches deployment token:", pmmToken.toLowerCase() === paymentToken.toLowerCase());
      } catch (e) {
        console.log("Could not read PMM.paymentToken():", e.message);
      }

      // Verify token minting rights are assigned to PMM (only works with TenbinToken ABI)
      try {
        const minter = await tenbin.minter();
        console.log("Token minter:", minter);
        console.log("PMM is token minter:", minter.toLowerCase() === (await pmm.getAddress()).toLowerCase());
      } catch (e) {
        // If IERC20 fallback is used, `minter()` won't exist.
      }
      
      console.log("\n=== Platform Market Info ===");
      console.log("Protocol Fee:", await pmm.protocolFeeBasisPoints(), "basis points (max:", await pmm.MAX_PROTOCOL_FEE_BASIS_POINTS(), ")");
      console.log("Minimum Votes:", await pmm.MINIMUM_VOTES());
      
      // Get fee recipients
      const feeInfo = await pmm.getFeeDistributionInfo();
      console.log("Owner Fee Recipient:", feeInfo.ownerRecipient);
      console.log("Protocol Fee Recipient:", feeInfo.protocolRecipient);
      console.log("Accumulated Fees:", ethers.formatUnits(feeInfo.pendingFees, 6), "TBD");
      
      // Show total markets and yield rate
      try {
        const totalMarkets = await pmm.totalMarkets();
        console.log("Total Markets:", totalMarkets.toString());
        
        if (totalMarkets > 0) {
          const yieldRate = await pmm.currentAnnualYieldWad();
          console.log("Current Annual Yield Rate:", (Number(yieldRate) / 1e18 * 100).toFixed(6) + "%");
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