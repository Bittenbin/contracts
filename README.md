# Pythagorean Market Maker (PMM)

A decentralized reputation system using coordinate-based markets to track trust and distrust votes for any platform entity.

## 🚀 Live Deployments

### Base Mainnet
- **PMM Contract**: [`0x92AcC35FE215a065146F93132cF27D5C3E39D826`](https://basescan.org/address/0x92AcC35FE215a065146F93132cF27D5C3E39D826)
- **TENBIN Token**: [`0x420331D6396B7290B57Ac4633983FC9a95F9913C`](https://basescan.org/address/0x420331D6396B7290B57Ac4633983FC9a95F9913C)
- **Chain ID**: 8453
- **Deployed**: November 26, 2025
- **Explorer**: [Basescan](https://basescan.org)

### Base Sepolia Testnet
- **PMM Contract**: [`0x8F6a072098B0440690f81246538CF761BE201C7F`](https://sepolia.basescan.org/address/0x8F6a072098B0440690f81246538CF761BE201C7F)
- **TENBIN Token**: [`0x5399156BAab6A6e2C51D2239B23366dE66A01E5b`](https://sepolia.basescan.org/address/0x5399156BAab6A6e2C51D2239B23366dE66A01E5b)
- **Chain ID**: 84532
- **Deployed**: November 26, 2025
- **Explorer**: [Sepolia Basescan](https://sepolia.basescan.org)
- **Faucet**: [Base Sepolia Faucet](https://www.alchemy.com/faucets/base-sepolia)

**Authors**: clwsqc and rtedwardchen

## Overview

PMM creates reputation markets where:
- Each market exists at coordinates (x, y) where **x = distrust votes** and **y = trust votes**
- Coordinates are valid when x>0, y>0 within bounds (max 1 billion each)
- **Cost = sqrt(x² + y²) TENBIN** with configurable protocol fee (0-1%, default 1%)
- Individual vote tracking ensures you can only sell votes you own
- Built-in MEV protection with 2.5% default slippage tolerance
- **Yield accrual** on held positions based on market count

### Key Features
- Create markets for any numeric platform ID (via application workflow)
- Buy votes to increase trust or distrust
- Sell only the votes you personally contributed
- Earn yield on your holdings over time
- No expiration - markets exist forever
- Gas-efficient design for millions of users

## TENBIN Token

PMM uses **TENBIN** as its native payment and reward token:

- **Name/Symbol**: TENBIN (`TENBIN`)
- **Decimals**: 6
- **Initial Supply**: 1,000,000 TENBIN minted to deployer
- **Roles**:
  - **Minter**: Can mint unlimited TENBIN (set to PMM contract after deployment)
  - **Burner**: Can burn TENBIN from any address (initially owner)
- **No hard cap**: Minting is unlimited for yield distribution

### Deployment Environment Variables
```bash
# Deploy fresh TENBIN + PMM
DEPLOY_TENBIN=true npx hardhat run scripts/deploy.js --network base

# Use existing TENBIN token
PAYMENT_TOKEN=0xYourTENBIN npx hardhat run scripts/deploy.js --network base
```

## Quick Start

💡 **Tip**: Test on Base Sepolia first before using mainnet!

### Using Basescan UI
1. Visit the contract on Basescan (see deployment addresses above)
2. Click "Contract" → "Write as Proxy"
3. Connect wallet and interact

### Using JavaScript
```javascript
const PMM_ADDRESS = "<PMM_PROXY_ADDRESS>";
const TENBIN_ADDRESS = "<TENBIN_TOKEN_ADDRESS>";

// Approve TENBIN first
await tenbin.approve(PMM_ADDRESS, ethers.parseUnits("100", 6));

// Apply to create a market (costs 10 TENBIN application fee)
await pmm.applyForMarket(1234567890);

// After owner approval, vote to set initial position
// Market starts at (0,0), first vote moves it to desired position
await pmm.voteOnMarket(1234567890, 3, 4); // Costs ~5.05 TENBIN

// Or if directly creating (owner can bypass application):
await pmm.createMarket(1234567890, 3, 4);

// Vote to move market to (5,12) - costs ~8.08 TENBIN
await pmm.voteOnMarket(1234567890, 5, 12);

// Claim accrued yield
await pmm.claimYield(1234567890);
```

### Using Python
```bash
# For Base Mainnet
python pmm_cookbook_mainnet.py check-market 1234567890

# For Base Sepolia Testnet
python pmm_cookbook_testnet.py check-market 1234567890
```

## How It Works

### Pricing Formula
```
Cost = sqrt(x_new² + y_new²) - sqrt(x_current² + y_current²) + 1% fee
```

The hypotenuse can be fractional; payments are calculated with token-decimal precision (6 decimals for TENBIN).

| Action | From → To | Cost |
|--------|-----------|------|
| Create | (0,0) → (3,4) | 5.05 TENBIN |
| Buy | (3,4) → (5,12) | 8.08 TENBIN |
| Sell | (5,12) → (3,4) | -7.92 TENBIN (refund) |
| Rebalance | (3,4) → (4,3) | 0 TENBIN |

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

## Market Application Flow

To prevent spam and ensure quality markets, PMM uses an application/approval workflow:

1. **Apply**: Anyone calls `applyForMarket(platformId)` with a **10 TENBIN** fee
2. **Review**: Contract owner reviews pending applications
3. **Approve/Deny**: Owner calls `approveMarket(platformId)` or `denyMarket(platformId)`
4. **Trade**: Upon approval, market is created at (0,0) and anyone can vote

```javascript
// Step 1: Applicant submits (10 TENBIN consumed regardless of outcome)
await tenbin.approve(PMM_ADDRESS, ethers.parseUnits("10", 6));
await pmm.applyForMarket(1234567890);

// Step 2: Owner approves (market now live at (0,0))
await pmm.approveMarket(1234567890);

// Step 3: Anyone can trade after approval
await tenbin.approve(PMM_ADDRESS, ethers.parseUnits("100", 6));
await pmm.voteOnMarket(1234567890, 3, 4); // Costs ~5.05 TENBIN
```

**Note**: The owner can also directly create markets using `createMarket()` without the application process.

## Yield and Rewards

PMM implements a yield system that rewards long-term holders:

### Yield Rate Formula
```
Annual Yield Rate = K / sqrt(totalMarkets)
where K = 0.75 * sqrt(π) ≈ 1.329
```

- More markets → lower individual yield rate (sustainable tokenomics)
- Yield accrues linearly on your **cost basis** (trustCost + distrustCost)

### Cost Basis Tracking
For each user and market, PMM tracks:
- `trustCost`: TENBIN spent on trust votes
- `distrustCost`: TENBIN spent on distrust votes
- `lastAccrual`: Timestamp of last yield calculation
- `unclaimedYield`: Accumulated rewards pending claim

### How Yield Accrues
```
reward = (trustCost + distrustCost) × annualRate × timeElapsed / year
```

- **Buying**: Adds to cost basis (decomposed along trust/distrust path)
- **Selling**: Reduces cost basis pro-rata for units sold
- **Rebalancing**: No change to cost basis (same hypotenuse)
- **Claiming**: Mints accrued TENBIN to caller, resets unclaimed to 0

### Claiming Yield
```javascript
// Check current yield rate
const rateWad = await pmm.currentAnnualYieldWad();
console.log("Annual rate:", Number(rateWad) / 1e18);

// Claim rewards for a specific market
await pmm.claimYield(1234567890);
```

**Important**: PMM must be set as the TENBIN minter for yield claiming to work. Deployment scripts handle this automatically.

## Contract Functions

### Core Trading Functions
- `createMarket(platformId, x, y)` - Create new market (owner only, or after application)
- `voteOnMarket(platformId, newX, newY)` - Change market position
- `voteOnMarketWithSlippage(platformId, newX, newY, slippageBP)` - With custom slippage

### Application Functions
- `applyForMarket(platformId)` - Submit application (10 TENBIN fee)
- `approveMarket(platformId)` - Owner approves application
- `denyMarket(platformId)` - Owner denies application

### Yield Functions
- `claimYield(platformId)` - Claim accrued rewards
- `currentAnnualYieldWad()` - Get current annual yield rate (WAD format)

### Read Functions
- `getMarketState(platformId)` - Get position, trust score, total votes
- `getVoterPosition(platformId, voter)` - Check voter's owned votes
- `holdings(platformId, voter)` - Get cost basis and unclaimed yield
- `marketExistsFor(platformId)` - Check if market exists
- `isValidCoordinate(x, y)` - Validate coordinates

### With Custom Slippage
- `createMarketWithSlippage(platformId, x, y, slippageBasisPoints)`
- `voteOnMarketWithSlippage(platformId, newX, newY, slippageBasisPoints)`

## Valid Coordinates

Coordinates are valid if:
- `x > 0` and `y > 0`
- Both within `MAX_COORDINATE_VALUE` (1 billion)
- Hypotenuse ≤ `MAX_HYPOTENUSE` (1.5 billion)
- For creation: `x ≠ y` (cannot start on genesis line)

**Note**: Unlike the name suggests, coordinates do NOT need to form Pythagorean triples. Any valid (x, y) pair works.

Examples:
- Valid: (3,4), (5,12), (4,5), (10,11), (100,200)
- Invalid: (0,5), (5,0), (5,5) for creation

Use `isValidCoordinate(x, y)` to check validity.

## Fee Distribution

- **Configurable protocol fee**: 0% to 1% (default 1%)
- Fee can be adjusted by owner or protocol fee recipient via `setProtocolFee()`
- Split 50/50 between owner and protocol recipients
- Owner functions: `distributeProtocolFees()`, `updateFeeRecipients()`, `setProtocolFee()`

```javascript
// Check accumulated fees
const feeInfo = await pmm.getFeeDistributionInfo();
console.log("Pending fees:", feeInfo.pendingFees);

// Distribute all fees (owner only)
await pmm.distributeProtocolFees(0); // 0 = distribute all

// Or distribute specific amount
await pmm.distributeProtocolFees(ethers.parseUnits("100", 6));

// Individual withdrawals
await pmm.withdrawToOwner(amount);
await pmm.withdrawToProtocol(amount);

// Set protocol fee (owner or protocol recipient)
await pmm.setProtocolFee(50);  // Set to 0.5% (50 basis points)
await pmm.setProtocolFee(0);   // Set to 0%
await pmm.setProtocolFee(100); // Set to 1% (maximum)
```

## Safety Features

- **Maximum coordinate**: 1 billion
- **Maximum hypotenuse**: 1.5 billion
- **Overflow protection**: All math operations checked
- **Pausable**: Owner can pause in emergencies
- **Upgradeable**: UUPS proxy pattern for future improvements
- **Reentrancy guard**: Protection against reentrancy attacks
- **Comprehensive event logging**: For monitoring and indexing

## Development

### Setup
```bash
npm install
npx hardhat compile
npx hardhat test
```

### Local Development
```bash
# Start local node
npm run node

# Deploy with fresh TENBIN
DEPLOY_TENBIN=true npx hardhat run scripts/deploy.js --network localhost
```

### Deploy to Testnet
```bash
# Set environment variables in .env
# PRIVATE_KEY, BASE_SEPOLIA_RPC_URL

DEPLOY_TENBIN=true npx hardhat run scripts/deploy.js --network base-sepolia
```

### Deploy to Mainnet
```bash
# Set environment variables in .env
# PRIVATE_KEY, BASE_RPC_URL

DEPLOY_TENBIN=true npx hardhat run scripts/deploy-mainnet.js --network base
```

### Python Cookbooks
- `pmm_cookbook_mainnet.py` - Base Mainnet interactions
- `pmm_cookbook_testnet.py` - Base Sepolia interactions

## Technical Documentation

For detailed technical information:
- [Coordinate System Documentation](docs/PYTHAGOREAN_COORDINATES.md)
- Contract implements UUPS upgradeable pattern
- Uses OpenZeppelin security libraries

## License

MIT
