Key changelogs compared to the original PMM V2:

1. Added `disableUpgrade` to permanently freeze PMM upgrades (one-way switch).

2. Moved to fixed-supply tokenomics:
- initial token supply is 0;
- hard cap is 21,000,000 TENBIN; and
- reward emissions target 1,000,000 TENBIN/year over 21 years via PMM staking (subject to cap).

3. Emission clock starts on first stake (`emissionStartTime` initialized lazily).

4. Simplified and modernized the test/tooling stack:
- removed milestone-era contract/testing logic;
- migrated active tests to Foundry (`.t.sol`);
- removed legacy Hardhat JS test files; and
- aligned scripts/docs with the fixed-supply PMM design.

5. Added owner float withdrawals with a cumulative cap:
- owner can call `withdrawOwnerFloat(amount)` to withdraw from liquidity;
- withdrawals are capped cumulatively by a heuristic minimum float estimate (`minimumFloatEstimate()`); and
- cap enforcement is: `totalOwnerFloatWithdrawn + amount <= minimumFloatEstimate()`.

6. Restricted each vote-trade transaction to a single axis:
- a trade can change either upvotes or downvotes in one transaction, not both;
- diagonal coordinate moves are rejected; and
- this simplifies position accounting and cost transitions for buy/sell flows.
