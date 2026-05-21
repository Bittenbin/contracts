const { ethers } = require("hardhat");
const fs = require("fs");
const readline = require("readline");

const ETHEREUM_MAINNET_CHAIN_ID = 1n;
const MAINNET_USDC = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";

function ask(question) {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  return new Promise((resolve) => {
    rl.question(question, (answer) => {
      rl.close();
      resolve(answer);
    });
  });
}

async function main() {
  const network = await ethers.provider.getNetwork();
  if (network.chainId !== ETHEREUM_MAINNET_CHAIN_ID) {
    throw new Error(`Wrong network: expected Ethereum mainnet (${ETHEREUM_MAINNET_CHAIN_ID}), got ${network.chainId}`);
  }

  const [deployer] = await ethers.getSigners();
  const deployerBalance = await ethers.provider.getBalance(deployer.address);
  const paymentToken = process.env.PAYMENT_TOKEN || MAINNET_USDC;
  const initialOwner = process.env.INITIAL_OWNER || deployer.address;
  const freezeTbnMinter = process.env.FREEZE_TBN_MINTER === "true";
  const renouncePmmOwnership = process.env.RENOUNCE_PMM_OWNERSHIP === "true";
  const renounceTbnOwnership = process.env.RENOUNCE_TBN_OWNERSHIP === "true";
  const deployerIsInitialOwner = initialOwner.toLowerCase() === deployer.address.toLowerCase();

  console.log("Deploying PMM v2 to Ethereum mainnet");
  console.log("Deployer:", deployer.address);
  console.log("Deployer ETH:", ethers.formatEther(deployerBalance));
  console.log("Payment token:", paymentToken);
  console.log("Initial owner:", initialOwner);
  console.log("Freeze TBN minter:", freezeTbnMinter);
  console.log("Renounce PMM ownership:", renouncePmmOwnership);
  console.log("Renounce TBN ownership:", renounceTbnOwnership);

  if (deployerBalance < ethers.parseEther("0.05")) {
    throw new Error("Deployer balance is below the recommended 0.05 ETH minimum.");
  }

  if (renounceTbnOwnership && !freezeTbnMinter) {
    throw new Error("RENOUNCE_TBN_OWNERSHIP=true requires FREEZE_TBN_MINTER=true.");
  }

  if (!deployerIsInitialOwner && (freezeTbnMinter || renouncePmmOwnership || renounceTbnOwnership)) {
    throw new Error("Owner actions require INITIAL_OWNER to be the deployer address.");
  }

  const paymentTokenCode = await ethers.provider.getCode(paymentToken);
  if (paymentTokenCode === "0x") {
    throw new Error(`Payment token contract not found at ${paymentToken}`);
  }

  const confirmation = await ask('Type "DEPLOY PMM V2 MAINNET" to continue: ');
  if (confirmation !== "DEPLOY PMM V2 MAINNET") {
    throw new Error("Deployment cancelled.");
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
    initialOwner
  );
  await pmm.waitForDeployment();
  const pmmAddress = await pmm.getAddress();
  console.log("PythagoreanMarketMakerV2 deployed:", pmmAddress);

  if (deployerIsInitialOwner) {
    await (await tbn.setMinter(pmmAddress)).wait();
    console.log("Tenbinium minter set to PMM v2");
    if (freezeTbnMinter) {
      await (await tbn.freezeMinter()).wait();
      console.log("Tenbinium minter frozen permanently");
    }
  } else {
    console.log("Initial owner is not deployer. Set and optionally freeze the minter manually:");
    console.log(`  tbn.setMinter("${pmmAddress}")`);
    console.log("  tbn.freezeMinter()");
  }

  if (renouncePmmOwnership) {
    await (await pmm.renounceOwnership()).wait();
    console.log("PMM v2 ownership renounced");
  }

  if (renounceTbnOwnership) {
    await (await tbn.renounceOwnership()).wait();
    console.log("Tenbinium ownership renounced");
  }

  const pmmOwner = await pmm.owner();
  const tbnOwner = await tbn.owner();
  const tbnMinter = await tbn.minter();
  const tbnMinterFrozen = await tbn.minterFrozen();

  const deploymentInfo = {
    network: "mainnet",
    chainId: Number(ETHEREUM_MAINNET_CHAIN_ID),
    contracts: {
      Tenbinium: tbnAddress,
      PythagoreanMarketMakerV2: pmmAddress,
      PaymentToken: paymentToken,
    },
    roles: {
      initialOwner,
      pmmOwner,
      tbnOwner,
      tbnMinter,
      tbnMinterFrozen,
    },
    freezeTbnMinter,
    renouncePmmOwnership,
    renounceTbnOwnership,
    deployer: deployer.address,
    deploymentBlock: await ethers.provider.getBlockNumber(),
    timestamp: new Date().toISOString(),
    notes: "Fresh PMM v2 deployment for Ethereum mainnet",
  };

  fs.mkdirSync("deployments", { recursive: true });
  const deploymentPath = `deployments/deployment-v2-mainnet-${Date.now()}.json`;
  fs.writeFileSync(deploymentPath, JSON.stringify(deploymentInfo, null, 2));

  console.log("Deployment info saved:", deploymentPath);
  console.log("Verification commands:");
  console.log(`npx hardhat verify --network mainnet ${tbnAddress} ${initialOwner}`);
  console.log(
    `npx hardhat verify --network mainnet ${pmmAddress} ${paymentToken} ${tbnAddress} ${initialOwner}`
  );
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
