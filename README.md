Key changelogs compared to the original PMM V2:

1. Added `disableUpgrade` to permanently freeze PMM upgrades (one-way switch).

2. Moved to fixed-supply tokenomics:
- initial token supply is 0;
- hard cap is 21,000,000 TENBIN; and
- reward emissions are phased:
  - first 20 years: 1,000,000 TENBIN/year (per-second accrual), totaling 20,000,000 TENBIN; then
  - tail: yearly halving from 500,000 TENBIN/year (`500k -> 250k -> 125k -> ...`) for the remaining 1,000,000 TENBIN cap budget.

3. Emission clock starts on first stake (`emissionStartTime` initialized lazily).

4. Compared to `master` branch (semantic renaming updates):
- replaced `upvote(s)` / `downvote(s)` naming with neutral `y` / `x` naming for relevant parameters/fields/events;
- replaced `trust*` / `distrust*` cost-basis naming with `y*` / `x*` naming; and
- kept behavior equivalent while removing subjective axis semantics from contract interfaces and internals.

5. Work puzzle (PLP + perfect-square TVL gate) high-level summary:
- each page is at a PLP coordinate `(x, y)` with integer hypotenuse `c`, and global TVL is `H = sum(c_i)`;
- a legal move updates one page `c -> c'`, producing `delta = c' - c` and `H' = H + delta`;
- base gate requires `H'` to be a perfect square;
- with the stricter variant, `delta` must also be a perfect square, giving:
  - `H + delta = m^2`
  - `delta = t^2`
  - `m^2 - t^2 = H = (m - t)(m + t)`;
- this double filter narrows candidates before protocol constraints (occupied source, empty destination, liquidity/slippage, bounds);
- verification remains cheap onchain, while "work" is constrained offchain search (not cryptographic PoW).
