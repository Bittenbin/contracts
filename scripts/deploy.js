const { ethers, upgrades } = require("hardhat");

async function main() {
  console.log("Deploying Enhanced Pythagorean Market Maker with Vote Tracking...");

  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with account:", deployer.address);

  // Check if we should deploy MockUSDC or use existing
  const deployMockUSDC = process.env.DEPLOY_MOCK_USDC === "true";
  let paymentTokenAddress;

  if (deployMockUSDC) {
    console.log("Deploying MockUSDC...");
    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    const mockUSDC = await MockUSDC.deploy();
    await mockUSDC.waitForDeployment();
    paymentTokenAddress = await mockUSDC.getAddress();
    console.log("MockUSDC deployed to:", paymentTokenAddress);

    // Mint some USDC to deployer for testing
    console.log("Minting 10,000 USDC to deployer...");
    await mockUSDC.mint(deployer.address, ethers.parseUnits("10000", 6));
  } else {
    paymentTokenAddress = process.env.PAYMENT_TOKEN;
    console.log("Using existing payment token:", paymentTokenAddress);
  }

  // Deploy PythagoreanMarketMaker as upgradeable proxy
  console.log("Deploying PythagoreanMarketMaker...");
  const PythagoreanMarketMaker = await ethers.getContractFactory("PythagoreanMarketMaker");
  const pmm = await upgrades.deployProxy(
    PythagoreanMarketMaker,
    [paymentTokenAddress],
    { initializer: 'initialize' }
  );
  await pmm.waitForDeployment();
  console.log("PythagoreanMarketMaker deployed to:", await pmm.getAddress());

  // Verify the deployment
  console.log("\nVerifying deployment...");
  console.log("Payment token:", await pmm.paymentToken());
  console.log("Protocol fee:", await pmm.PROTOCOL_FEE_BASIS_POINTS(), "basis points (1%)");
  console.log("Minimum votes:", await pmm.MINIMUM_VOTES());
  
  // Show fee distribution addresses
  console.log("\n💰 Fee Distribution Configuration:");
  console.log("Owner fee recipient (50%):", await pmm.ownerFeeRecipient());
  console.log("Protocol fee recipient (50%):", await pmm.protocolFeeRecipient());
  console.log("Contract holds funds until distributed");
  
  // Show safety limits
  console.log("\n🛡️ Safety Features:");
  console.log("Max coordinate value:", ethers.formatUnits(await pmm.MAX_COORDINATE_VALUE(), 0));
  console.log("Max hypotenuse:", ethers.formatUnits(await pmm.MAX_HYPOTENUSE(), 0));
  console.log("Pausable: Yes (owner only)");
  console.log("Overflow protection: Enabled");

  // Test coordinate validation
  console.log("\nTesting Pythagorean coordinate validation:");
  console.log("Is (3,4) valid?", await pmm.isValidCoordinate(3, 4)); // Should be true
  console.log("Is (5,12) valid?", await pmm.isValidCoordinate(5, 12)); // Should be true
  console.log("Is (2,3) valid?", await pmm.isValidCoordinate(2, 3)); // Should be false
  console.log("Is (5,5) valid?", await pmm.isValidCoordinate(5, 5)); // Should be true (but not allowed for creation)

  // Show suggested coordinates for different trust levels
  console.log("\nSuggested initial coordinates:");
  const trustLevels = [0.3, 0.5, 0.7, 0.85];
  for (const level of trustLevels) {
    const suggested = await pmm.suggestInitialCoordinates(ethers.parseEther(level.toString()));
    console.log(`For trust score ~${level}: (${suggested.x}, ${suggested.y})`);
  }

  console.log("\n=== Deployment Summary ===");
  console.log("Network:", network.name);
  console.log("Payment Token:", paymentTokenAddress);
  console.log("PythagoreanMarketMaker:", await pmm.getAddress());
  console.log("Deployer:", deployer.address);
  console.log("========================\n");

  // Save deployment addresses
  const fs = require("fs");
  const deploymentInfo = {
    network: network.name,
    contracts: {
      PythagoreanMarketMaker: await pmm.getAddress(),
      PaymentToken: paymentTokenAddress,
    },
    deployer: deployer.address,
    timestamp: new Date().toISOString(),
    notes: "Enhanced PMM with individual vote tracking and hypotenuse-based pricing"
  };

  const deploymentPath = `deployments/deployment-${network.name}-${Date.now()}.json`;
  fs.writeFileSync(deploymentPath, JSON.stringify(deploymentInfo, null, 2));
  console.log("Deployment info saved to:", deploymentPath);

  // If on local network, provide example usage
  if (network.name === "localhost" || network.name === "hardhat") {
    console.log("\n📝 Example Usage with Vote Tracking:");
    console.log("------------------");
    console.log("1. Create a market for platform ID 1234567890:");
    console.log(`   await pmm.createMarket(1234567890, 3, 4)`);
    console.log("   Cost: sqrt(3² + 4²) = 5 USDC + 0.05 fee = 5.05 USDC");
    console.log("   You own: 3 distrust, 4 trust votes\n");
    
    console.log("2. Vote to increase trust:");
    console.log(`   await pmm.voteOnMarket(1234567890, 5, 12)`);
    console.log("   Cost: sqrt(5² + 12²) - sqrt(3² + 4²) = 13 - 5 = 8 USDC + fee");
    console.log("   You gain: 2 distrust, 8 trust votes\n");
    
    console.log("3. Check your position:");
    console.log(`   await pmm.getVoterPosition(1234567890, yourAddress)`);
    console.log("   Returns: trustVotes, distrustVotes, exists\n");
    
    console.log("4. Sell some votes:");
    console.log(`   await pmm.voteOnMarket(1234567890, 3, 4)`);
    console.log("   Refund: 8 USDC - 0.08 fee = 7.92 USDC");
    console.log("   ⚠️  You can only sell votes you own!\n");
    
    console.log("Key Changes:");
    console.log("- Cost based on hypotenuse: sqrt(x² + y²)");
    console.log("- Each voter's contributions tracked individually");
    console.log("- Prevents overselling - can only sell what you own");
    console.log("- Same function names for seamless integration");
    
    console.log("\n💰 Fee Distribution (Owner Only):");
    console.log("------------------");
    console.log("1. Check accumulated fees:");
    console.log(`   await pmm.accumulatedProtocolFees()`);
    console.log(`   await pmm.getFeeDistributionInfo()\n`);
    
    console.log("2. Distribute all fees 50/50:");
    console.log(`   await pmm.distributeProtocolFees()`);
    console.log("   Splits between owner & protocol recipients\n");
    
    console.log("3. Distribute specific amount:");
    console.log(`   await pmm.distributeProtocolFees(ethers.parseUnits("10", 6))`);
    console.log("   Distributes 10 USDC (5 to each recipient)\n");
    
    console.log("4. Individual withdrawals:");
    console.log(`   await pmm.withdrawToOwner(amount)`);
    console.log(`   await pmm.withdrawToProtocol(amount)\n`);
    
    console.log("5. Update fee recipients:");
    console.log(`   await pmm.updateFeeRecipients(newOwner, newProtocol)`);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });