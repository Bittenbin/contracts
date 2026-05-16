const { ethers } = require("hardhat");
const fs = require("fs");
const path = require("path");

function latestDeployment() {
  const deploymentsDir = path.join(__dirname, "../deployments");
  if (!fs.existsSync(deploymentsDir)) return null;

  const files = fs.readdirSync(deploymentsDir)
    .filter((file) => file.startsWith(`deployment-v2-${network.name}`) && file.endsWith(".json"))
    .sort((a, b) => b.localeCompare(a));

  if (files.length === 0) return null;
  const deploymentPath = path.join(deploymentsDir, files[0]);
  return JSON.parse(fs.readFileSync(deploymentPath, "utf8"));
}

async function main() {
  const [signer] = await ethers.getSigners();
  const networkInfo = await ethers.provider.getNetwork();
  const deployment = latestDeployment();
  const pmmAddress = process.env.PMM_V2_ADDRESS || deployment?.contracts?.PythagoreanMarketMakerV2;
  const tbnAddress = process.env.TBN_ADDRESS || deployment?.contracts?.Tenbinium;
  const paymentTokenAddress = process.env.PAYMENT_TOKEN || deployment?.contracts?.PaymentToken;

  console.log("Network:", network.name);
  console.log("Chain ID:", networkInfo.chainId.toString());
  console.log("Signer:", signer.address);
  console.log("ETH:", ethers.formatEther(await ethers.provider.getBalance(signer.address)));

  if (!pmmAddress || !tbnAddress || !paymentTokenAddress) {
    console.log("\nSet PMM_V2_ADDRESS, TBN_ADDRESS, and PAYMENT_TOKEN or run after a saved v2 deployment.");
    return;
  }

  const pmm = await ethers.getContractAt("PythagoreanMarketMakerV2", pmmAddress);
  const tbn = await ethers.getContractAt("Tenbinium", tbnAddress);
  const paymentToken = await ethers.getContractAt("IERC20Metadata", paymentTokenAddress);
  const paymentDecimals = await paymentToken.decimals();

  console.log("\nContracts:");
  console.log("PMM v2:", pmmAddress);
  console.log("TBN:", tbnAddress);
  console.log("Payment token:", paymentTokenAddress);

  console.log("\nProtocol state:");
  console.log("totalStakedValue:", (await pmm.totalStakedValue()).toString());
  console.log("nMax:", (await pmm.nMax()).toString());
  console.log("totalPower:", (await pmm.totalPower()).toString());
  console.log("totalTbnEmitted:", ethers.formatEther(await pmm.totalTbnEmitted()), "TBN");
  console.log("accumulatedProtocolFees:", ethers.formatUnits(await pmm.accumulatedProtocolFees(), paymentDecimals));

  console.log("\nTBN state:");
  console.log("minter:", await tbn.minter());
  console.log("minterFrozen:", await tbn.minterFrozen());
  console.log("totalSupply:", ethers.formatEther(await tbn.totalSupply()), "TBN");

  console.log("\nSigner balances:");
  console.log("payment token:", ethers.formatUnits(await paymentToken.balanceOf(signer.address), paymentDecimals));
  console.log("TBN:", ethers.formatEther(await tbn.balanceOf(signer.address)));
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
