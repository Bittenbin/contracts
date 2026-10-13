# Bittenbin Contracts

Bittenbin is a decentralized intelligence system on Ethereum that answers Yes/No questions with a probability.  Many independent forecasters answer the same question, each answer is costly to give, and the answers are combined into one probability without a centralized platform.

For the full design, see the whitepaper: [docs/whitepaper-v2.6.pdf](docs/whitepaper-v2.6.pdf).

## How It Works

- **Neurons.**  A wallet creates a neuron at a Pythagorean lattice point `(x, y, C)` by finding a nonce such that `keccak256(wallet, x, y, C, nonce)` begins with `x`, then `y`, then `C` in binary.  The neuron stands for the probability `(x / C)²` forever, and each point can hold only one neuron.
- **Rewards.**  Creating a neuron mints Tenbinium (`TBN`): 2 TBN for each of the first 9,000,000 neurons, 1 TBN for the next 1,000,000, then 0.5 TBN halving every 2,000,000 neurons, up to a cap of 21,000,000 TBN.
- **Questions.**  A customer asks a question that stays open for 1 hour, 4 hours, 1 day or 7 days, for a fee of 1, 2, 5 or 13 TBN.
- **Memory.**  Until the deadline, a wallet answers by storing the question under one of its neurons.  A neuron can store one question for every bit of its proof.
- **Aggregated probability.**  The neurons that store a question are added together as vectors `(x, y)`, and the answer is `(q_x / ‖q‖)²` for their sum `q`.  The fee is shared among them by how much each contributed to the length of `q`, and it returns to the customer if no neuron stores the question.

## Contracts

- `src/BittenbinCoreV026.sol`: neurons, questions, storing, the aggregated probability, fee claims and refunds.
- `src/Tenbinium.sol`: the Tenbinium (`TBN`) ERC-20 token with zero initial supply and a 21,000,000 TBN hard cap.

## Deployment

Both contracts are deployed and verified on Ethereum mainnet.

```text
BittenbinCoreV026: 0x99ACB0507A53757505BdD4D4982B65EEA85b4f76
Tenbinium:         0x088132b2E55EEF29B82f2FF64ce1c4BD578b05Ba
```

The token's minter is `BittenbinCoreV026`.  The minter has been frozen and ownership of the token has been renounced, so TBN can only be minted by creating neurons.

Key deployment transactions:

```text
TBN deploy:    0xa4ab2c0cef7c459323fdc927424b2b6151493af94ec82e89090de048c6d740df
Core deploy:   0x1aacf0c449d7922c466e760d398228b8810af93175ed4163cbd05a75d6e45aba
setMinter:     0x1435d29aecbe25c1ad19da48c499acb01a998c2d91faf96d02f3660e4f044396
freezeMinter:  0xd63cbdc232f9725b6df3d82ecd20e00250e6ae6e160769ea9aca903c8e274e50
TBN renounce:  0x4b5e36dd42f87a67343f50a6a39a4e1d5958d0196973e93431df5ed6f136741b
```

## Development

```bash
npm install
npm run compile
npm test
```

The tests are in `test/foundry/`, with one file for each part of the protocol.

## License

The contracts in `src/` are licensed under the Business Source License 1.1.  See [licenses/BUSL_LICENSE](licenses/BUSL_LICENSE).

Files that remain MIT-licensed are covered by [licenses/MIT_LICENSE](licenses/MIT_LICENSE).
