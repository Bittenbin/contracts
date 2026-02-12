const { ethers } = require("hardhat");

// Already deployed contracts
const PMM_IMPLEMENTATION = "0x98a05820ca7e18B70F0ad8A2D8B225aB76bd4D75";
const TENBIN_ADDRESS = "0x420331D6396B7290B57Ac4633983FC9a95F9913C";

async function main() {
  console.log("=================================");
  console.log("DEPLOY PROXY FOR PMM");
  console.log("=================================\n");

  const chainId = (await ethers.provider.getNetwork()).chainId;
  console.log("Chain ID:", chainId.toString());
  
  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", deployer.address);
  console.log("Balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "ETH");
  
  console.log("\nPMM Implementation:", PMM_IMPLEMENTATION);
  console.log("TENBIN Address:", TENBIN_ADDRESS);

  // Get the PMM interface to encode the initialize call
  const PythagoreanMarketMaker = await ethers.getContractFactory("PythagoreanMarketMaker");
  const initData = PythagoreanMarketMaker.interface.encodeFunctionData("initialize", [TENBIN_ADDRESS]);
  console.log("\nInit data:", initData);

  // Deploy ERC1967Proxy
  console.log("\n📦 Deploying ERC1967Proxy...");
  
  // Get the proxy contract factory (compiled via src/helpers/ProxyHelper.sol)
  const ERC1967Proxy = await ethers.getContractFactory("ERC1967Proxy");
  
  const proxy = await ERC1967Proxy.deploy(PMM_IMPLEMENTATION, initData, {
    gasLimit: 500000
  });
  
  console.log("TX Hash:", proxy.deploymentTransaction().hash);
  await proxy.waitForDeployment();
  
  const proxyAddress = await proxy.getAddress();
  console.log("✅ Proxy deployed to:", proxyAddress);

  // Verify it works
  console.log("\n🔍 Verifying deployment...");
  const pmm = PythagoreanMarketMaker.attach(proxyAddress);
  
  const paymentToken = await pmm.paymentToken();
  const owner = await pmm.owner();
  const protocolFee = await pmm.PROTOCOL_FEE_BASIS_POINTS();
  
  console.log("Payment token:", paymentToken);
  console.log("Contract owner:", owner);
  console.log("Protocol fee:", protocolFee.toString(), "basis points");
  console.log("Owner fee recipient:", await pmm.ownerFeeRecipient());
  console.log("Protocol fee recipient:", await pmm.protocolFeeRecipient());

  // Save deployment info
  const fs = require("fs");
  const deploymentInfo = {
    network: chainId === 8453n ? "base" : "base-sepolia",
    chainId: Number(chainId),
    contracts: {
      PythagoreanMarketMaker: proxyAddress,
      Implementation: PMM_IMPLEMENTATION,
      PaymentToken: TENBIN_ADDRESS
    },
    deployer: deployer.address,
    timestamp: new Date().toISOString()
  };
  
  if (!fs.existsSync("deployments")) {
    fs.mkdirSync("deployments");
  }
  
  const deploymentPath = `deployments/deployment-base-mainnet-${Date.now()}.json`;
  fs.writeFileSync(deploymentPath, JSON.stringify(deploymentInfo, null, 2));
  console.log("\n✅ Saved to:", deploymentPath);

  console.log("\n=================================");
  console.log("🎉 DEPLOYMENT SUCCESSFUL!");
  console.log("=================================");
  console.log("\n📋 Contract Addresses:");
  console.log("TENBIN:", TENBIN_ADDRESS);
  console.log("PMM (Proxy):", proxyAddress);
  console.log("PMM (Implementation):", PMM_IMPLEMENTATION);
  
  console.log("\n⚠️  NEXT: Set PMM as TENBIN minter!");
  console.log(`   Call TenbinToken.setMinter("${proxyAddress}")`);
  
  console.log("\n🔗 View on Basescan:");
  console.log(`   https://basescan.org/address/${proxyAddress}`);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Error:", error);
    process.exit(1);
  });

