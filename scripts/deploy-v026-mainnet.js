const { ethers, network } = require("hardhat");
const fs = require("fs");

const ETHEREUM_MAINNET_CHAIN_ID = 1n;
const CONFIRMATION = "DEPLOY V026 MAINNET";

async function main() {
  const dryRun = process.env.DRY_RUN === "true";
  const { chainId } = await ethers.provider.getNetwork();
  if (!dryRun && chainId !== ETHEREUM_MAINNET_CHAIN_ID) {
    throw new Error(`Wrong network: expected Ethereum mainnet (${ETHEREUM_MAINNET_CHAIN_ID}), got ${chainId}`);
  }
  if (!dryRun && process.env.CONFIRM_DEPLOY !== CONFIRMATION) {
    throw new Error(`Set CONFIRM_DEPLOY="${CONFIRMATION}" to deploy.`);
  }

  const [deployer] = await ethers.getSigners();
  const balanceBefore = await ethers.provider.getBalance(deployer.address);
  console.log(dryRun ? "Dry run of the V026 deployment" : "Deploying V026 to Ethereum mainnet");
  console.log("Network:", network.name, `(chain ${chainId})`);
  console.log("Deployer:", deployer.address);
  console.log("Deployer ETH:", ethers.formatEther(balanceBefore));

  let gasUsed = 0n;
  const mined = async (tx, label) => {
    const receipt = await tx.wait();
    gasUsed += receipt.gasUsed;
    console.log(`${label}: ${receipt.hash} (gas ${receipt.gasUsed})`);
    return receipt;
  };

  // The deployer owns the token only long enough to set and freeze the minter.
  const Tenbinium = await ethers.getContractFactory("Tenbinium");
  const tbn = await Tenbinium.deploy(deployer.address);
  await mined(tbn.deploymentTransaction(), "Tenbinium deploy");
  const tbnAddress = await tbn.getAddress();
  console.log("Tenbinium:", tbnAddress);

  const Core = await ethers.getContractFactory("BittenbinCoreV026");
  const core = await Core.deploy(tbnAddress);
  await mined(core.deploymentTransaction(), "BittenbinCoreV026 deploy");
  const coreAddress = await core.getAddress();
  console.log("BittenbinCoreV026:", coreAddress);

  await mined(await tbn.setMinter(coreAddress), "setMinter");
  await mined(await tbn.freezeMinter(), "freezeMinter");
  await mined(await tbn.renounceOwnership(), "renounceOwnership");

  const state = {
    coreToken: await core.tbn(),
    tbnMinter: await tbn.minter(),
    tbnMinterFrozen: await tbn.minterFrozen(),
    tbnOwner: await tbn.owner(),
    tbnTotalSupply: (await tbn.totalSupply()).toString(),
    neuronCount: (await core.neuronCount()).toString(),
  };
  if (
    state.coreToken !== tbnAddress ||
    state.tbnMinter !== coreAddress ||
    !state.tbnMinterFrozen ||
    state.tbnOwner !== ethers.ZeroAddress ||
    state.tbnTotalSupply !== "0"
  ) {
    throw new Error(`Unexpected state after deployment: ${JSON.stringify(state)}`);
  }
  console.log("Minter is the core, frozen, and the token has no owner.");

  const spent = balanceBefore - (await ethers.provider.getBalance(deployer.address));
  console.log("Total gas used:", gasUsed.toString());
  console.log("ETH spent:", ethers.formatEther(spent));
  if (dryRun) return;

  const deployment = {
    network: "mainnet",
    chainId: Number(chainId),
    contracts: { Tenbinium: tbnAddress, BittenbinCoreV026: coreAddress },
    state,
    deployer: deployer.address,
    deploymentBlock: await ethers.provider.getBlockNumber(),
    timestamp: new Date().toISOString(),
  };
  fs.mkdirSync("deployments", { recursive: true });
  const path = `deployments/deployment-v026-mainnet-${Date.now()}.json`;
  fs.writeFileSync(path, JSON.stringify(deployment, null, 2));
  console.log("Deployment info saved:", path);
  console.log("Verification commands:");
  console.log(`npx hardhat verify --network mainnet ${tbnAddress} ${deployer.address}`);
  console.log(`npx hardhat verify --network mainnet ${coreAddress} ${tbnAddress}`);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
