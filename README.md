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
