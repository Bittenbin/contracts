const { ethers } = require("hardhat");

const PROXY_ADDRESS = "0xff763ea9508Be30840edB942D4ffDEAaa4Ec9FEc";
const IMPLEMENTATION_ADDRESS = "0xe735BEe34055C071a918E762B3E46c53F89ea274";
const TOKEN_ADDRESS = "0xAEe7CdeEB72D645Fc9598d4AF47C43303A6c699f";

async function main() {
  console.log("=================================");
  console.log("CHECKING PROXY STATUS");
  console.log("=================================\n");

  // Check if there's code at the proxy address
  const proxyCode = await ethers.provider.getCode(PROXY_ADDRESS);
  console.log("Proxy has code:", proxyCode !== "0x");
  console.log("Proxy code length:", proxyCode.length);

  // Read the implementation slot (ERC1967)
  // Implementation slot: 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
  const implSlot = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
  const storedImpl = await ethers.provider.getStorage(PROXY_ADDRESS, implSlot);
  const implAddress = "0x" + storedImpl.slice(-40);
  console.log("\nStored implementation address:", implAddress);
  console.log("Expected implementation:", IMPLEMENTATION_ADDRESS);
  console.log("Match:", implAddress.toLowerCase() === IMPLEMENTATION_ADDRESS.toLowerCase());

  // Try to read owner directly from storage
  // In Ownable, owner is typically at slot 0 or after proxy slots
  console.log("\n--- Trying to read contract state ---");
  
  try {
    const PythagoreanMarketMaker = await ethers.getContractFactory("PythagoreanMarketMaker");
    const pmm = PythagoreanMarketMaker.attach(PROXY_ADDRESS);
    
    // Try calling owner
    const owner = await pmm.owner();
    console.log("Owner:", owner);
  } catch (e) {
    console.log("Failed to get owner:", e.message);
  }

  // Check raw storage slots
  console.log("\n--- Raw storage check ---");
  for (let i = 0; i < 5; i++) {
    const slot = await ethers.provider.getStorage(PROXY_ADDRESS, i);
    console.log(`Slot ${i}:`, slot);
  }

  // Check if implementation has code
  const implCode = await ethers.provider.getCode(IMPLEMENTATION_ADDRESS);
  console.log("\nImplementation has code:", implCode !== "0x");
  console.log("Implementation code length:", implCode.length);

  // Try calling implementation directly (should fail for UUPS but shows code exists)
  console.log("\n--- Direct implementation call test ---");
  try {
    const PythagoreanMarketMaker = await ethers.getContractFactory("PythagoreanMarketMaker");
    const impl = PythagoreanMarketMaker.attach(IMPLEMENTATION_ADDRESS);
    const owner = await impl.owner();
    console.log("Implementation owner:", owner);
  } catch (e) {
    console.log("Implementation call result:", e.message.substring(0, 100));
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });

