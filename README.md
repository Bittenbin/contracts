# Pythagorean Market Maker V2

Bittenbin's PMM v2 is a fresh Ethereum-oriented implementation of the protocol described in `docs/whitepaper-v2.pdf`. It combines the Pythagorean market maker, automatic proof-of-proximity detection, and Tenbinium (`TBN`) token rewards.

The v2 runtime uses two contracts:

- `PythagoreanMarketMakerV2`: PMM locations, relocations, proof-of-proximity, solver power, rewards, fees, and proximity reads.
- `Tenbinium`: ERC-20 reward token with zero initial supply, a 21,000,000 TBN cap, burn support, and PMM v2 as minter.

## Protocol Overview

Each agent is created from a human-readable primary ID such as an agent URL. The contract derives the canonical `bytes32 agentId` as `keccak256(bytes(primaryId))`, stores that hash, and emits the readable primary ID in `AgentCreated` for frontends and indexers.

Each listed agent occupies a unique Pythagorean lattice point `(x, y, c)` where:

```text
c = sqrt(x^2 + y^2)
```

The PMM cost is based on the change in `c`:

```text
new listing:  c
relocation:   newC - oldC
```

Positive `deltaC` requires USDC payment plus a 1% protocol fee. Negative `deltaC` returns USDC minus a 1% protocol fee. These USDC fees accumulate in a fee vault that anyone can redeem by burning 100 TBN. Zero `deltaC` relocations do not pay or receive USDC, but can still trigger the separate TBN burn if the destination was previously used as a proof destination.

## Proof-Of-Proximity

Every positive listing or relocation automatically checks whether it solves proof-of-proximity.

A transaction is a valid solution when:

- `deltaC = n^2`
- post-transaction `totalStakedValue = m^2`
- destination `(x, y, c)` has not previously been used as a puzzle-solving destination

When valid, the contract:

- marks the destination as used
- updates `nMax = max(nMax, n)`
- increases the solver's power by `deltaC`
- emits `ProofOfProximitySolved`

The solver is the wallet that executed the transaction (`msg.sender`).

## TBN Rewards

TBN has zero initial supply and a hard cap of 21,000,000 tokens.

Solver power earns TBN pro rata through a global reward accumulator:

- Years 1-20: 1,000,000 TBN per year
- Year 21 onward: 500,000 TBN per year, halving yearly

Emission starts only after solver power first exists. Solvers claim rewards with `claimTBN()`.

If total solver power later falls to zero, emissions for that time window are not allocated or minted. This acts like unminted emission decay, so actual TBN supply may finish below the 21,000,000 hard cap.

Any transaction that enters a destination previously used as a proof-solving destination burns `1 TBN` from the caller.

Separately, the accumulated USDC fee vault can be redeemed permissionlessly by burning `100 TBN`. The redeemer receives the full vault balance, the vault resets to zero, and the burned TBN is permanently removed from supply.

## Core Functions

`createAgent(string primaryId, uint256 x, uint256 y)`

Lists a new agent at a unique valid Pythagorean coordinate. The contract derives `agentId = keccak256(bytes(primaryId))`; the caller pays `c` USDC plus 1% fee, receives initial x/y exposure, and may automatically solve proof-of-proximity if the transaction qualifies.

`relocateAgent(bytes32 agentId, uint256 currentX, uint256 currentY, uint256 newX, uint256 newY)`

Moves an existing agent from the caller's expected current coordinate to a new valid Pythagorean coordinate. The `currentX` and `currentY` guard prevents stale-state execution: if the agent has moved before the transaction lands, the relocation reverts before payment, refund, burn, exposure update, or proof detection. Positive `deltaC` charges USDC, negative `deltaC` refunds USDC and reduces the caller's solver power, and qualifying positive moves automatically solve proof-of-proximity.

`claimTBN()`

Settles and mints the caller's accrued TBN rewards.

`redeemFeeVault()`

Burns `100 TBN` from the caller and transfers the full accumulated USDC fee vault to the caller.

## Read Functions

`getAgentState(bytes32 agentId)`

Returns `(x, y, c, exists)` for an agent.

`getExposure(bytes32 agentId, address participant)`

Returns a participant's owned x/y exposure for an agent. A participant can only sell exposure they previously acquired.

`pendingTBN(address solver)`

Returns the solver's claimable TBN, including rewards accrued since the last global update.

`areConnected(bytes32 agentA, bytes32 agentB)`

Returns whether two agents are within the current proximity radius `nMax`.

`isValidCoordinate(uint256 x, uint256 y)`

Returns whether `(x, y)` forms a valid Pythagorean coordinate under protocol bounds.

`destinationHash(uint256 x, uint256 y, uint256 c)` and `coordinateHash(uint256 x, uint256 y)`

Pure helpers for deriving destination and coordinate hashes used by the protocol.

## Key Events

`AgentCreated(bytes32 indexed agentId, string primaryId, address indexed creator, uint256 x, uint256 y, uint256 c)`

Emitted when an agent is listed. `primaryId` is not indexed so event consumers can read the original human-readable ID.

`AgentRelocated(bytes32 indexed agentId, address indexed participant, uint256 fromX, uint256 fromY, uint256 toX, uint256 toY, int256 deltaC)`

Emitted when an agent is relocated.

`ExposureUpdated(bytes32 indexed agentId, address indexed participant, uint256 xExposure, uint256 yExposure)`

Emitted after participant exposure changes.

`ProofOfProximitySolved(address indexed solver, bytes32 indexed agentId, uint256 x, uint256 y, uint256 deltaC, uint256 n, uint256 newTVL, uint256 nMax)`

Emitted when a transaction automatically solves proof-of-proximity.

`SolverPowerUpdated(address indexed solver, uint256 power, uint256 totalPower)`

Emitted when solver power changes.

`TbnClaimed(address indexed solver, uint256 amount)`

Emitted when a solver claims TBN.

`TbnBurnedForUsedDestination(address indexed payer, bytes32 indexed destinationHash, uint256 amount)`

Emitted when the 1 TBN used-destination fee is burned.

`FeeVaultRedeemed(address indexed redeemer, uint256 tbnBurned, uint256 usdcRedeemed)`

Emitted when a caller burns TBN to redeem the accumulated USDC fee vault.

## Development

Install dependencies and run tests:

```bash
npm install
npx hardhat compile
npx hardhat test
```

Run only the v2 tests:

```bash
npm run test:v2
```

Run a specific category:

```bash
npm run test:pmm
npm run test:proof
npm run test:tbn
npm run test:fees
npm run test:security
npm run test:frontrun
npm run test:lategame
npm run test:integration
```

## Deployment

The v2 mainnet deployment script deploys fresh `Tenbinium` and `PythagoreanMarketMakerV2` contracts.

```bash
npm run deploy:v2:mainnet
```

### Mainnet Deployment

Contracts:

```text
Tenbinium: 0x279658aEBF8D15901f9e4362a97AeB4da54942c6
PythagoreanMarketMakerV2: 0x92223bC1D150FC7B17A136f7Ef9E39BFbC579DDd
USDC payment token: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
```

Key deployment transactions:

```text
TBN deploy: 0x2d4f4c3c6c8b33883ca04f478e46c022596f5a386cd1d3bae492a6813ddfe7ed
PMM deploy: 0x491bb8b649c1219441bafe9c84ddcb7cc80979dbc4916177166fa60e5c35dc80
setMinter: 0xc4bdf0940224506ab1e5d04f460e11bd91d3b65854ccb0c590f906cc1e3e384f
freezeMinter: 0xf5a76cd2d19f8295b46675b20c0bdc1b594af76ca440ceb78483a10911467ff0
PMM renounce: 0x09c96be536f5e903b60bbc559a689eea13f3de246e3263051c184cdaef701a7f
TBN renounce: 0xe013f0c4d5458d5405ab4f3c3138c72707f8d537af3ce4f188ee04e6b64e1ad3
```

By default, the script uses Ethereum mainnet USDC:

```text
0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
```

Override deployment parameters with:

```bash
MAINNET_RPC_URL=https://...
PRIVATE_KEY=0x...
PAYMENT_TOKEN=0x...
INITIAL_OWNER=0x...
FREEZE_TBN_MINTER=true # optional, one-way
RENOUNCE_PMM_OWNERSHIP=true
RENOUNCE_TBN_OWNERSHIP=true
```

After deployment, `Tenbinium` should have `PythagoreanMarketMakerV2` set as its minter. Freezing the minter makes this assignment permanent, preventing the TBN owner from later installing another minter and minting outside the PMM reward schedule.

Check a saved deployment or explicit contract addresses:

```bash
PMM_V2_ADDRESS=0x... TBN_ADDRESS=0x... PAYMENT_TOKEN=0x... npm run check:v2 -- --network mainnet
```

Ownership renounce checklist:

1. Verify `Tenbinium.minter()` is the deployed PMM v2 address.
2. Call `Tenbinium.freezeMinter()` if it was not frozen during deployment.
3. Verify `Tenbinium.minterFrozen()` is `true`.
4. Verify `PythagoreanMarketMakerV2.owner()` is `0x0000000000000000000000000000000000000000` when `RENOUNCE_PMM_OWNERSHIP=true`.
5. Verify `Tenbinium.owner()` is `0x0000000000000000000000000000000000000000` when `RENOUNCE_TBN_OWNERSHIP=true`.

## Python Helper

The Python helper targets PMM v2 on Ethereum mainnet:

- `pmmV2-helper.py`

Set deployed contract addresses before use:

```bash
PMM_V2_ADDRESS=0x...
TBN_ADDRESS=0x...
MAINNET_RPC_URL=https://...
PRIVATE_KEY=0x... # only needed for transactions
```

Common commands:

```bash
python pmmV2-helper.py health
python pmmV2-helper.py agent-id https://agent.example
python pmmV2-helper.py validate 15 20
python pmmV2-helper.py state <agent_id_hash>
python pmmV2-helper.py approve-usdc 100
python pmmV2-helper.py approve-tbn-burn 100
python pmmV2-helper.py create https://agent.example 15 20
python pmmV2-helper.py relocate <agent_id_hash> 15 20 20 21
python pmmV2-helper.py redeem-fee-vault
python pmmV2-helper.py claim-tbn
```

## License

The PMM V2 core contracts are licensed under the Business Source License 1.1.
See [licenses/BUSL_LICENSE](licenses/BUSL_LICENSE).

Files that remain MIT-licensed are covered by [licenses/MIT_LICENSE](licenses/MIT_LICENSE).
