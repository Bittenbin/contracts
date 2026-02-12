# Protocol Float (Cumulative Owner Withdrawals)

## Overview
The protocol allows the owner to withdraw a **cumulative float** from the USDC pool
based on a heuristic lower bound of total market coordinates.

## Heuristic Minimum TVL
We use a first-quadrant lattice packing estimate:

```
minTVL ≈ (4 / (3 * sqrt(pi))) * n^(3/2)
```

Where:
- `n` = `totalMarkets`
- `minTVL` is a geometric lower bound on the **sum of market hypotenuse costs**
  under idealized packing of unique positive lattice points.

## On-Chain Implementation
The PMM contract tracks:
- `totalOwnerFloatWithdrawn`
- `minimumFloatEstimate()` (the formula above)

Owner withdrawals via `withdrawOwnerFloat(amount)` are capped so that:

```
totalOwnerFloatWithdrawn + amount <= minimumFloatEstimate()
```

## Important Notes
- The float is **cumulative**, not per-withdrawal.
- The cap is **heuristic**, not a hard solvency guarantee.
- Protocol fees are tracked separately and are not counted against the float.
- If you want a strict solvency guarantee, the cap must be derived
  from actual refundable liabilities, not just coordinate geometry.

## Heuristic Check (Base Mainnet)
We added `scripts/check-min-tvl.py` to compare the on-chain heuristic with
an off-chain "actual minTVL" computed as the sum of scaled hypotenuses for
current market coordinates (using `MarketCreated` to enumerate markets).

Findings (run against Base mainnet, deployment block 41879823):
- `totalMarkets()` = 0
- `minimumFloatEstimate()` = 0
- Computed actual minTVL = 0

Result: the comparison is trivially satisfied because there are no markets yet.
