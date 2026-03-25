Key changelogs compared to the original PMM V2:

1. Added `disableUpgrade` to permanently freeze PMM upgrades (one-way switch).

2. Moved to fixed-supply tokenomics:
- initial token supply is 0;
- hard cap is 21,000,000 TENBIN; and
- reward emissions are phased:
  - first 20 years: 1,000,000 TENBIN/year (per-second accrual), totaling 20,000,000 TENBIN; then
  - tail: yearly halving from 500,000 TENBIN/year (`500k -> 250k -> 125k -> ...`) for the remaining 1,000,000 TENBIN cap budget.

3. Emission clock starts on first stake (`emissionStartTime` initialized lazily).

4. Reward claiming is now global per player (vs per-entity in `master`):
- `master` used yield accrual and entity-level claims via `claimYield(platformId)`;
- current branch tracks rewards at the user aggregate level and uses one `claimRewards()` call for all positions.

5. Compared to `master` branch (semantic renaming updates):
- replaced `upvote(s)` / `downvote(s)` naming with neutral `y` / `x` naming for relevant parameters/fields/events;
- replaced `trust*` / `distrust*` cost-basis naming with `y*` / `x*` naming; and
- kept behavior equivalent while removing subjective axis semantics from contract interfaces and internals.

6. Restored strict PLP coordinate rule compared to `master`:
- current branch requires `(x, y, c)` to be a valid integer Pythagorean triple (`c^2 = x^2 + y^2`);
- `master` only required integer-positive `x`/`y` with hypotenuse upper-bound checks.

7. Work puzzle (PLP + perfect-square TVL gate) high-level summary:
- each page is at a PLP coordinate `(x, y)` with integer hypotenuse `c`, and global TVL is `C = sum(c_i)`;
- a legal move updates one page `c -> c'`, producing `delta = c' - c` and `C' = C + delta`;
- base gate requires `C'` to be a perfect square;
- with the stricter variant, `delta` must also be a perfect square, giving:
  - `C + delta = m^2`
  - `delta = n^2`
  - `m^2 - n^2 = C = (m - n)(m + n)`;
- this double filter narrows candidates before protocol constraints (occupied source, empty destination, liquidity/slippage, bounds);
- verification remains cheap onchain, while "work" is constrained offchain search (not cryptographic PoW).

8. Added onchain puzzle metric tracking:
- protocol now tracks `currentM`, `currentN`, `maxM`, `maxN`, and global `totalC`;
- metrics update on market create/vote transitions and only register non-zero `currentM/currentN` when the transition satisfies `delta = n^2` and `C' = m^2`.

9. Planned entity-connection radius feature:
- protocol intends to use either `currentN` (dynamic) or `maxN` (historical) as the connection radius across entities.

10. Relaunch target moved from Base to Ethereum mainnet:
- deployment scripts/config now target Ethereum L1 mainnet (chainId `1`) for fresh protocol redeploy;
- verification and deployment metadata paths are aligned to Etherscan/mainnet conventions.
