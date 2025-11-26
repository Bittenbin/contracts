# Coordinate System in Platform Markets

## Overview

The Pythagorean Market Maker (PMM) uses a **coordinate-based system** to represent market positions for platform entities. Each market occupies a coordinate (x, y) in a 2D space where:

- **x = Distrust votes** (stake against the entity)
- **y = Trust votes** (stake for the entity)

> **Note**: Despite the "Pythagorean" name, the contract now accepts **any positive coordinates** within bounds. The name is historical - coordinates do NOT need to form Pythagorean triples.

## Coordinate Rules

### Valid Coordinates
A coordinate (x, y) is valid if:
- `x > 0` and `y > 0` (both positive)
- `x ≤ MAX_COORDINATE_VALUE` (1 billion)
- `y ≤ MAX_COORDINATE_VALUE` (1 billion)
- `sqrt(x² + y²) ≤ MAX_HYPOTENUSE` (1.5 billion)

### Creation Restrictions
When **creating** a market, additional rules apply:
- `x ≠ y` (cannot start on the "genesis line")
- Total votes `x + y ≥ MINIMUM_VOTES` (7)

### Examples of Valid Coordinates
| Position | Total Votes | Hypotenuse | Trust Score | Notes |
|----------|-------------|------------|-------------|-------|
| (3, 4) | 7 | 5.00 | 64.0% | Classic Pythagorean triple |
| (5, 12) | 17 | 13.00 | 85.2% | Integer hypotenuse |
| (4, 5) | 9 | 6.40 | 61.0% | Non-integer hypotenuse ✓ |
| (10, 11) | 21 | 14.87 | 54.8% | Near-balanced |
| (100, 200) | 300 | 223.61 | 80.0% | Large market |

## Pricing Formula

### Cost = Hypotenuse in TENBIN

The cost of a market position is determined by its **hypotenuse** (distance from origin):

```
Cost = sqrt(x² + y²) TENBIN + 1% protocol fee
```

### Transaction Types

| Action | Formula | Example |
|--------|---------|---------|
| **Create** | `sqrt(x² + y²) * 1.01` | (3,4) → 5.05 TENBIN |
| **Buy** | `(newHyp - currentHyp) * 1.01` | (3,4)→(5,12) = 8.08 TENBIN |
| **Sell** | `(currentHyp - newHyp) * 0.99` | (5,12)→(3,4) = 7.92 TENBIN refund |
| **Rebalance** | 0 (same hypotenuse) | (5,12)→(12,5) = 0 TENBIN |

### Fractional Hypotenuse Handling
- The hypotenuse can be any positive real number
- Payments are calculated with 6-decimal precision (TENBIN decimals)
- Example: Position (4,5) has hypotenuse √41 ≈ 6.403124
  - Cost = 6.403124 TENBIN + 0.064031 fee = 6.467155 TENBIN

## Trust Score

The trust score represents the proportion of trust in a market:

```
Trust Score = y² / (x² + y²)
```

### Trust Score Properties
- **Range**: 0 to 1 (displayed as 0% to 100%)
- **Neutral**: 50% at x = y (genesis line, not allowed for creation)
- **Trust-leaning**: > 50% when y > x
- **Distrust-leaning**: < 50% when x > y

### Trust Score Examples
| Position | Calculation | Trust Score |
|----------|-------------|-------------|
| (3, 4) | 16/25 | 64% |
| (4, 3) | 9/25 | 36% |
| (5, 12) | 144/169 | 85.2% |
| (12, 5) | 25/169 | 14.8% |
| (20, 21) | 441/841 | 52.4% |

## Market Application Workflow

Markets are not created directly. Instead:

1. **Apply**: User calls `applyForMarket(platformId)` with 10 TENBIN fee
2. **Review**: Contract owner reviews the application
3. **Approve/Deny**: Owner calls `approveMarket()` or `denyMarket()`
4. **Initial Position**: Approved market starts at (0, 0)
5. **First Vote**: Any user can vote to move from (0, 0) to desired position

This prevents spam and ensures quality market creation.

## Yield System

PMM rewards long-term holders with yield on their positions:

### Annual Yield Rate
```
Rate = K / sqrt(totalMarkets)
where K = 0.75 * sqrt(π) ≈ 1.329
```

- More markets → lower individual yield rate
- Sustainable tokenomics as system grows

### Cost Basis Tracking
For each user and market, PMM tracks:
- **trustCost**: TENBIN spent on trust votes
- **distrustCost**: TENBIN spent on distrust votes
- **lastAccrual**: Timestamp of last yield calculation
- **unclaimedYield**: Accumulated rewards

### Yield Accrual
```
Reward = (trustCost + distrustCost) × annualRate × (now - lastAccrual) / year
```

- Accrues linearly over time
- Does not compound (base stays constant until trading)
- Claimed by calling `claimYield(platformId)`

## Market Evolution Examples

### Trust Building Path
A market gaining community trust:
```
(0,0) → (4, 3) → (3, 4) → (5, 12) → (8, 15)
Trust:  N/A     36%      64%       85%       78%
Cost:   0       5.05     0         8.08      7.07
```

### Controversy Path  
A market becoming controversial:
```
(0,0) → (3, 4) → (5, 12) → (12, 5) → (20, 21)
Trust:  N/A     64%       85%       15%       52%
```

### Rebalancing (No Cost)
Moving along the same "circle" (same hypotenuse):
```
(5, 12) → (12, 5)    Hypotenuse: 13 → 13    Cost: 0
(3, 4) → (4, 3)      Hypotenuse: 5 → 5      Cost: 0
```

## Coordinate Scarcity

Each coordinate can only be occupied by **one market**:
- Coordinates are globally unique across all platform IDs
- If (3, 4) is taken by platform A, platform B cannot use it
- Creates natural competition for "good" coordinates

### Popular Coordinates
Some coordinates are more desirable:
- **Pythagorean triples**: Integer hypotenuse = cleaner costs
- **Low coordinates**: Cheaper to create (e.g., (3,4) = 5 TENBIN)
- **High trust**: e.g., (5, 12) with 85% trust score
- **Balanced**: e.g., (20, 21) near 50% for neutral platforms

## Best Practices

### Starting a Market
Choose coordinates that reflect initial sentiment:
- **Positive outlook**: Start trust-leaning, e.g., (3, 4), (5, 12)
- **Negative outlook**: Start distrust-leaning, e.g., (4, 3), (12, 5)
- **Neutral**: Near-balanced like (20, 21)

### Cost Efficiency
- Pythagorean triples have integer hypotenuse (cleaner math)
- Smaller coordinates = lower initial cost
- Consider future growth room

### Common Pythagorean Triples (Reference)
These have integer hypotenuse, making costs exact:
```
(3, 4, 5)    - Minimal: 5 TENBIN
(5, 12, 13)  - Standard: 13 TENBIN
(8, 15, 17)  - Medium: 17 TENBIN
(7, 24, 25)  - Large trust: 25 TENBIN
(20, 21, 29) - Balanced: 29 TENBIN
```

## Mathematical Limits

| Constant | Value | Purpose |
|----------|-------|---------|
| MAX_COORDINATE_VALUE | 1,000,000,000 | Max x or y value |
| MAX_HYPOTENUSE | 1,500,000,000 | Max sqrt(x² + y²) |
| MINIMUM_VOTES | 7 | Min x + y for creation |
| PROTOCOL_FEE_BASIS_POINTS | 100 | 1% fee on transactions |
| DEFAULT_SLIPPAGE_BASIS_POINTS | 250 | 2.5% default slippage |

## Contract Functions Reference

### Read Functions
```solidity
// Check if coordinate is valid
function isValidCoordinate(uint256 x, uint256 y) returns (bool)

// Calculate trust score (returns WAD - 18 decimals)
function calculateTrustScore(uint256 x, uint256 y) returns (uint256)

// Get market state
function getMarketState(uint256 platformId) returns (
    uint256 x,
    uint256 y, 
    uint256 trustScore,
    uint256 totalVotes
)

// Get user holdings for yield
function holdings(uint256 platformId, address user) returns (
    uint256 trustCost,
    uint256 distrustCost,
    uint256 lastAccrual,
    uint256 unclaimedYield
)
```

### Write Functions
```solidity
// Apply for market (10 TENBIN fee)
function applyForMarket(uint256 platformId)

// Vote on market
function voteOnMarket(uint256 platformId, uint256 newX, uint256 newY)

// Claim yield
function claimYield(uint256 platformId)
```
