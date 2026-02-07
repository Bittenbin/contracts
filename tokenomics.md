 # Tenbin Dollar Tokenomics
 
 ## Circulating vs Total Supply
 We assume a capped supply (e.g., 21,000,000) with initial circulating supply at 0.
 The Tenbin Dollar is "mined" over time by solving the on-chain puzzle.
 In this model:
 
 - `totalSupply` is the hard cap and does not change.
 - `circulatingSupply` starts at 0 and grows only when rewards are minted.
 - The reward condition uses `circulatingSupply` so early rewards are easier
   and become harder over time as supply grows.
 
 If the token is only minted via rewards and never burned or locked, then:
 
   circulatingSupply == totalSupply()
 
 If there are burns, locks, or excluded addresses, then:
 
   circulatingSupply = totalSupply - sum(nonCirculatingBalances)
 
 In that case, maintain a circulating counter that only changes on mint/burn
 and transfers into or out of non-circulating addresses.
 
 ---
 
 ## Reward Condition
 A trader earns 1 Tenbin Dollar when moving a market from PT1 to PT2 with:
 
 - c' - c > c
 - circulatingSupply <= (c' - c)
 
 This makes rewards easy to earn at the beginning and harder later.
 
 ---
 
 ## Is This Computationally Trivial?
 
 **Verification is trivial.**
 Given a transaction, the contract can check:
 
 - Both states are valid Pythagorean triples
 - The move is valid (single-axis with required constraints)
 - k = c' - c satisfies k > c
 - circulatingSupply <= k
 
 These are constant-time arithmetic checks plus an integer square check.
 
 **Finding a valid move is a search problem.**
 It is not cryptographically hard unless you add additional constraints
 (bounds, parity rules, modular constraints, or hash targets). Without
 such constraints, a motivated trader can search offline and submit
 a valid move.
 
 ---
 
 ## Reward Distribution: Auto vs Claim
 
 ### Auto Mint (Airdrop on Valid Tx)
 - On every valid puzzle transaction, mint 1 token to the trader.
 - Simple UX and minimal friction.
 - Higher on-chain work per tx (mint in same call).
 
 ### Claim-Based Rewards
 - Record that a trader completed a valid puzzle move.
 - Trader calls a separate `claim()` to mint the reward.
 - Lower gas for the puzzle transaction, but more user friction.
 - Requires storage for pending rewards and replay protection.
 
 **Recommendation:** Auto-mint is simpler unless gas is a major concern.
