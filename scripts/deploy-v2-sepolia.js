const { ethers } = require("hardhat");
const fs = require("fs");

const ETHEREUM_SEPOLIA_CHAIN_ID = 11155111n;
const DEFAULT_SEPOLIA_USDC = "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238";

async function main() {
  const network = await ethers.provider.getNetwork();
  if (network.chainId !== ETHEREUM_SEPOLIA_CHAIN_ID) {
    throw new Error(`Wrong network: expected Ethereum Sepolia (${ETHEREUM_SEPOLIA_CHAIN_ID}), got ${network.chainId}`);
  }

  const [deployer] = await ethers.getSigners();
  const deployerBalance = await ethers.provider.getBalance(deployer.address);
  const paymentToken = process.env.PAYMENT_TOKEN || DEFAULT_SEPOLIA_USDC;
  const feeRecipient = process.env.FEE_RECIPIENT || deployer.address;
  const initialOwner = process.env.INITIAL_OWNER || deployer.address;
  const freezeTbnMinter = process.env.FREEZE_TBN_MINTER === "true";

  console.log("Deploying PMM v2 to Ethereum Sepolia");
  console.log("Deployer:", deployer.address);
  console.log("Deployer ETH:", ethers.formatEther(deployerBalance));
  console.log("Payment token:", paymentToken);
  console.log("Fee recipient:", feeRecipient);
  console.log("Initial owner:", initialOwner);
  console.log("Freeze TBN minter:", freezeTbnMinter);

  const paymentTokenCode = await ethers.provider.getCode(paymentToken);
  if (paymentTokenCode === "0x") {
    throw new Error(`Payment token contract not found at ${paymentToken}`);
  }

  const Tenbinium = await ethers.getContractFactory("Tenbinium");
  const tbn = await Tenbinium.deploy(initialOwner);
  await tbn.waitForDeployment();
  const tbnAddress = await tbn.getAddress();
  console.log("Tenbinium deployed:", tbnAddress);

  const PythagoreanMarketMakerV2 = await ethers.getContractFactory("PythagoreanMarketMakerV2");
  const pmm = await PythagoreanMarketMakerV2.deploy(
    paymentToken,
    tbnAddress,
    feeRecipient,
    initialOwner
  );
  await pmm.waitForDeployment();
  const pmmAddress = await pmm.getAddress();
  console.log("PythagoreanMarketMakerV2 deployed:", pmmAddress);

  if (initialOwner.toLowerCase() === deployer.address.toLowerCase()) {
    await tbn.setMinter(pmmAddress);
    console.log("Tenbinium minter set to PMM v2");
    if (freezeTbnMinter) {
      await tbn.freezeMinter();
      console.log("Tenbinium minter frozen permanently");
    }
  } else {
    console.log("Initial owner is not deployer. Set the TBN minter manually:");
    console.log(`  tbn.setMinter("${pmmAddress}")`);
    console.log("Optionally freeze it after verification:");
    console.log("  tbn.freezeMinter()");
  }

  const deploymentInfo = {
    network: "sepolia",
    chainId: Number(ETHEREUM_SEPOLIA_CHAIN_ID),
    contracts: {
      Tenbinium: tbnAddress,
      PythagoreanMarketMakerV2: pmmAddress,
      PaymentToken: paymentToken
    },
    roles: {
      initialOwner,
      feeRecipient
    },
    freezeTbnMinter,
    deployer: deployer.address,
    deploymentBlock: await ethers.provider.getBlockNumber(),
    timestamp: new Date().toISOString(),
    notes: "Fresh v2 deployment for Ethereum Sepolia testing"
  };

  fs.mkdirSync("deployments", { recursive: true });
  const deploymentPath = `deployments/deployment-v2-sepolia-${Date.now()}.json`;
  fs.writeFileSync(deploymentPath, JSON.stringify(deploymentInfo, null, 2));

  console.log("Deployment info saved:", deploymentPath);
  console.log("Next verification commands:");
  console.log(`npx hardhat verify --network sepolia ${tbnAddress} ${initialOwner}`);
  console.log(
    `npx hardhat verify --network sepolia ${pmmAddress} ${paymentToken} ${tbnAddress} ${feeRecipient} ${initialOwner}`
  );
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
