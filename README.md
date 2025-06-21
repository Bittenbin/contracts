# Pythagorean Market Maker (PMM)

A decentralized reputation system using Pythagorean coordinates to track trust and distrust votes for any platform entity.

## 🚀 Live Deployments

### Base Mainnet
- **Contract**: [`0xC37CC635f5fAf9D10f1C620BDc8431Efe7526fc8`](https://basescan.org/address/0xC37CC635f5fAf9D10f1C620BDc8431Efe7526fc8)
- **USDC**: [`0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`](https://basescan.org/token/0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913) (Official)
- **Chain ID**: 8453
- **Explorer**: [Basescan](https://basescan.org)

### Base Sepolia Testnet
- **Contract**: [`0xd37263E22862f36aB23427D33667e10AE1Fe3648`](https://sepolia.basescan.org/address/0xd37263E22862f36aB23427D33667e10AE1Fe3648)
- **MockUSDC**: [`0x37f48aE1ccc86c221C743318FdE68507bFF19319`](https://sepolia.basescan.org/address/0x37f48aE1ccc86c221C743318FdE68507bFF19319) (Mintable)
- **Chain ID**: 84532
- **Explorer**: [Sepolia Basescan](https://sepolia.basescan.org)
- **Faucet**: [Base Sepolia Faucet](https://www.alchemy.com/faucets/base-sepolia)

**Authors**: rtedwardchen and clwsqc

## Overview

PMM creates reputation markets where:
- Each market exists at coordinates (x, y) where **x = distrust votes** and **y = trust votes**
- Coordinates must satisfy the Pythagorean theorem: x² + y² = c² (where c is an integer)
- **Cost = sqrt(x² + y²) USDC** with 1% protocol fee
- Individual vote tracking ensures you can only sell votes you own
- Built-in MEV protection with 2.5% default slippage tolerance

### Key Features
- Create markets for any numeric platform ID
- Buy votes to increase trust or distrust
- Sell only the votes you personally contributed
- No expiration - markets exist forever
- Gas-efficient design for millions of users

## Quick Start

💡 **Tip**: Test on Base Sepolia first before using mainnet!

### Using Basescan UI
1. Visit [contract on Basescan](https://basescan.org/address/0xC37CC635f5fAf9D10f1C620BDc8431Efe7526fc8#writeProxyContract)
2. Click "Contract" → "Write as Proxy"
3. Connect wallet and interact

### Using JavaScript
```javascript
const PMM_ADDRESS = "0xC37CC635f5fAf9D10f1C620BDc8431Efe7526fc8";
const USDC_ADDRESS = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";

// Approve USDC first
await usdc.approve(PMM_ADDRESS, ethers.parseUnits("100", 6));

// Create a market at (3,4) - costs 5.05 USDC
await pmm.createMarket(1234567890, 3, 4);

// Vote to move market to (5,12) - costs 8.08 USDC  
await pmm.voteOnMarket(1234567890, 5, 12);
```

### Using Python
```bash
# For Base Mainnet (real USDC)
python pmm_cookbook_mainnet.py check-market 1234567890

# For Base Sepolia Testnet (test USDC - recommended for testing!)
python pmm_cookbook_testnet.py check-market 1234567890

# Testnet example - mint free test USDC
from pmm_cookbook_testnet import PMM_Cookbook
cookbook = PMM_Cookbook(private_key)
cookbook.mint_test_usdc(100)  # Mint 100 test USDC
cookbook.create_market(1234567890, 3, 4)
```

## How It Works

### Pricing Formula
```
Cost = sqrt(x_new² + y_new²) - sqrt(x_current² + y_current²) + 1% fee
```

| Action | From → To | Cost |
|--------|-----------|------|
| Create | (0,0) → (3,4) | 5.05 USDC |
| Buy | (3,4) → (5,12) | 8.08 USDC |
| Sell | (5,12) → (3,4) | -7.92 USDC (refund) |
| Rebalance | (3,4) → (4,3) | 0 USDC |

### Vote Tracking
- When you create a market, you own all initial votes
- When you move a market, you own the vote delta
- You can only sell votes you previously bought
- Your position accumulates across multiple transactions

### Trust Score
```
Trust Score = y² / (x² + y²)
```
- (3,4) = 64% trust
- (4,3) = 36% trust
- (5,12) = 92% trust

## Contract Functions

### Core Functions
- `createMarket(platformId, x, y)` - Create new market
- `voteOnMarket(platformId, newX, newY)` - Change market position
- `getMarketState(platformId)` - Get current position and trust score
- `getVoterPosition(platformId, voter)` - Check voter's owned votes

### With Custom Slippage
- `createMarketWithSlippage(platformId, x, y, slippageBasisPoints)`
- `voteOnMarketWithSlippage(platformId, newX, newY, slippageBasisPoints)`

## Valid Coordinates

Common Pythagorean triples for initial markets:
- (3,4) - 5 votes total
- (5,12) - 13 votes total  
- (8,15) - 17 votes total
- (7,24) - 25 votes total
- (20,21) - 29 votes total

Use `isValidCoordinate(x,y)` to check validity.

## Fee Distribution

- 1% fee on all transactions
- Split 50/50 between owner and protocol recipients
- Owner functions: `distributeProtocolFees()`, `updateFeeRecipients()`

## Safety Features

- Maximum coordinate: 1 billion
- Overflow protection on all math operations
- Pausable by owner in emergencies
- Comprehensive event logging for monitoring

## Development

### Setup
```bash
npm install
npx hardhat compile
npx hardhat test
```

### Deploy Your Own
```bash
npx hardhat run scripts/deploy.js --network base
```

### Python Cookbooks
- `pmm_cookbook_mainnet.py` - Base Mainnet (real USDC)
- `pmm_cookbook_testnet.py` - Base Sepolia (test USDC)

## Technical Documentation

For detailed technical information:
- [Pythagorean Coordinates Math](docs/PYTHAGOREAN_COORDINATES.md)
- Contract implements UUPS upgradeable pattern
- Uses OpenZeppelin security libraries

## License

MIT
