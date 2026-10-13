# Bittenbin Contracts

Bittenbin is a decentralized intelligence system on Ethereum that answers Yes/No questions with a probability.  Many independent forecasters answer the same question, each answer is costly to give, and the answers are combined into one probability without a centralized platform.

For the full design, see the whitepaper: [docs/whitepaper-v2.6.pdf](docs/whitepaper-v2.6.pdf).

## How It Works

### Neurons

A wallet joins by creating a **neuron** at a Pythagorean lattice point `(x, y, C)`, where `x² + y² = C²`.  The neuron stands for one probability forever:

```text
P(Yes) = (x / C)²,   P(No) = (y / C)²
```

To create it, the wallet searches for a nonce such that

```text
H = keccak256(wallet, x, y, C, nonce)
```

begins with `x`, then `y`, then `C`, each written in binary.  A point whose three numbers take `ℓ` bits in total needs about `2^ℓ` hashes.  For example, `(15, 20, 25)` stands for 36% and needs a hash that begins with the 14 bits `1111 10100 11001`.

Each lattice point can hold only one neuron.  The smallest points are taken first, so the work needed to create a neuron rises with the number of neurons that already exist.

### Rewards

Creating a neuron mints Tenbinium (`TBN`), which has a zero initial supply and a hard cap of 21,000,000.  The reward depends only on how many neurons were created before:

| Neurons created | Reward per neuron |
| --- | --- |
| First 9,000,000 | 2 TBN |
| Next 1,000,000 | 1 TBN |
| After 10,000,000 | 0.5 TBN, halving every 2,000,000 neurons |

### Questions

A customer asks a question and chooses how long it stays open.  The fee is fixed for each duration and grows approximately with the square root of the time:

| Duration | Fee |
| --- | --- |
| 1 hour | 1 TBN |
| 4 hours | 2 TBN |
| 1 day | 5 TBN |
| 7 days | 13 TBN |

Until the deadline, a wallet answers by **storing** the question under a neuron that it owns, usually the one whose probability is closest to what it believes.  Storing is a single public transaction, and the wallet can attach an opinion of up to 280 bytes.

If no neuron stores a question, the fee returns to the customer.  Questions are never settled: the answer is the considered opinion of the neurons that stored it, and the protocol does not measure whether it was right.

### Memory

A neuron has a finite memory.  It can store one question for every bit of its proof, so the neuron at `(15, 20, 25)` can store 14 questions.  A slot given to one question cannot be given to another, which gives a wallet a reason to store only the questions where it expects to be close to the final answer.

### Aggregated Probability

Each neuron that stores a question is a vector `(x, y)`.  The protocol adds these vectors and reads the answer from the direction of their sum `q`:

```text
q = (Σ x, Σ y),   P(Yes) = (q_x / ‖q‖)²
```

A neuron with a larger hypotenuse moves the sum further, so the answer is weighted by the work behind each neuron.  After the deadline, the fee is shared among the neurons that stored the question, each receiving

```text
(x · q_x + y · q_y) / ‖q‖²
```

of it.  A neuron that points the same way as the sum earns in full proportion to its hypotenuse, and one that points away from it earns less.

## Contracts

- `src/BittenbinCoreV026.sol`: neurons, questions, storing, the aggregated probability, fee claims and refunds.
- `src/Tenbinium.sol`: the Tenbinium (`TBN`) ERC-20 token with burn support, zero initial supply and a 21,000,000 TBN hard cap.

The main entry points of `BittenbinCoreV026` are:

| Function | Purpose |
| --- | --- |
| `createNeuron(x, y, c, nonce)` | Creates the caller's neuron at an unused lattice point and mints its reward |
| `ask(text, duration)` | Asks a question for one of the four durations and pays its fee |
| `store(questionId, x, y, opinion)` | Stores an open question under the caller's neuron |
| `claim(questionId, x, y)` | Pays a neuron's share of a closed question's fee |
| `refund(questionId)` | Returns the fee of a closed question that no neuron stored |
| `answerOf(questionId)` | Returns the sum `q` and the aggregated probability |

## Deployment

`BittenbinCoreV026` has not been deployed yet.  It must be set as the minter of the Tenbinium token that it rewards neurons with, so it needs a new Tenbinium deployment.

The earlier PMM V2 protocol remains deployed on Ethereum mainnet.  Its Tenbinium token has a frozen minter and is not the token that `BittenbinCoreV026` will use.

```text
PythagoreanMarketMakerV2: 0x92223bC1D150FC7B17A136f7Ef9E39BFbC579DDd
Tenbinium (PMM V2):       0x279658aEBF8D15901f9e4362a97AeB4da54942c6
```

## Development

Install dependencies:

```bash
npm install
```

Compile contracts:

```bash
npm run compile
```

Run the Foundry test suite:

```bash
npm test
```

The tests are in `test/foundry/`, with one file for each part of the protocol: neurons, rewards, questions, memory and the aggregated probability.

## License

The contracts in `src/` are licensed under the Business Source License 1.1.  See [licenses/BUSL_LICENSE](licenses/BUSL_LICENSE).

Files that remain MIT-licensed are covered by [licenses/MIT_LICENSE](licenses/MIT_LICENSE).
