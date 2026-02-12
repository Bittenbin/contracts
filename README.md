Key changelogs compared to the original PMM V2:


1. Added a function ‘disableUpgrade’ that can disable PMM contract upgrade to mitigate trust/censorship risk. For official launch, renounce Tenbin token contract ownership too.


2. Kept our mint-on-demand model but with a capped supply of 21M instead of perpetual inflation. Initial supply is still 1M, and the remaining 20M will be emitted at a constant rate over 20 years (i.e. 1M/year converted as 0.031709/sec) as rewards to stakers in proportional to their “cost basis”.  This model now uses Synthetix-style O(1) staking rewards algorithm pioneered around the 2020 DeFi Summer, which was also used by Uniswap V2 and SushiSwap’s liquidity mining program.


3. The 20-year emission clock only starts when the first stake happens.


4. In light of the new tokenomics, we:

- removed Milestone-related contract logics and tests for simplicity;
- updated some test scripts, for example removed the Flash loan test (Security.test.js:476);and - Reward farming test (Security.test.js:195) as rewards are proportional for time staked; and
ensured that all other 195 tests passed.
