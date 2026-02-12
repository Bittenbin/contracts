# TENBIN Tokenomics (Current Contract)

## Payment vs Reward Tokens
- **USDC** is the payment token for market creation and vote changes.
- **TENBINIUM (TBN)** is the reward token minted via staking rewards.
- **Reward token address (Base):** `0x942C0BfACFAB198E818d71bB0dceC091F213FCC9`

## Reward Emissions
- **Total cap:** 21,000,000 TBN
- **Emission schedule:** 1,000,000 TBN per year over 21 years
- **Rate:** ~31,709 raw units per second (6 decimals)
- **Start time:** emission starts on first stake
- **Minting:** rewards are minted on `claimRewards()` and require PMM to be set as minter

## Staking Basis
- Rewards use the Synthetix/SushiSwap **O(1) accumulator** pattern.
- A user’s stake is their **cost basis** (USDC) across all markets.
- Stake increases when buying votes and decreases proportionally when selling.

## Fees
- **Protocol fee:** 1% on buy/sell transactions (paid in USDC).
- Fees accumulate and can be distributed 50/50 to owner and protocol recipients.

## URL-Derived Markets
- Each market’s **page ID** is `uint256(keccak256(url))`.
- Raw URLs are emitted in `MarketMetadata` events for off-chain indexing.
