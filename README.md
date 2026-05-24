# Bittenbin Contracts

Smart contracts for Bittenbin's Pythagorean Market Maker V2, an Ethereum protocol for mapping agents into a Pythagorean coordinate system with proof-of-proximity rewards.

For the full protocol design, mechanism details, and economic discussion, see the whitepaper: [bittenbin.com/whitepaper.pdf](https://bittenbin.com/whitepaper.pdf).

## Contracts

The PMM V2 runtime is composed of two core contracts:

- `src/PythagoreanMarketMakerV2.sol`: agent creation, relocation, PMM accounting, proof-of-proximity detection, solver rewards, protocol fees, and proximity reads.
- `src/Tenbinium.sol`: the Tenbinium (`TBN`) ERC-20 reward token with burn support, zero initial supply, and a 21,000,000 TBN hard cap.

The protocol uses USDC as the payment token on Ethereum mainnet.

## Mainnet Deployment

```text
PythagoreanMarketMakerV2: 0x92223bC1D150FC7B17A136f7Ef9E39BFbC579DDd
Tenbinium:                0x279658aEBF8D15901f9e4362a97AeB4da54942c6
USDC:                     0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
```

Key deployment transactions:

```text
TBN deploy:     0x2d4f4c3c6c8b33883ca04f478e46c022596f5a386cd1d3bae492a6813ddfe7ed
PMM deploy:     0x491bb8b649c1219441bafe9c84ddcb7cc80979dbc4916177166fa60e5c35dc80
setMinter:      0xc4bdf0940224506ab1e5d04f460e11bd91d3b65854ccb0c590f906cc1e3e384f
freezeMinter:   0xf5a76cd2d19f8295b46675b20c0bdc1b594af76ca440ceb78483a10911467ff0
PMM renounce:   0x09c96be536f5e903b60bbc559a689eea13f3de246e3263051c184cdaef701a7f
TBN renounce:   0xe013f0c4d5458d5405ab4f3c3138c72707f8d537af3ce4f188ee04e6b64e1ad3
```

The deployed TBN minter is the PMM V2 contract. The minter has been frozen and ownership has been renounced for both core contracts.

## Development

Install dependencies:

```bash
npm install
```

Compile contracts:

```bash
npm run compile
```

Run the Hardhat test suite:

```bash
npm test
```

Run the Foundry test suite:

```bash
npm run test:foundry
```

Run all configured PMM V2 tests:

```bash
npm run test:all
```

## Deployment And Status Checks

Deploy PMM V2 to Ethereum mainnet:

```bash
npm run deploy:v2:mainnet
```

Common deployment environment variables:

```bash
MAINNET_RPC_URL=https://...
PRIVATE_KEY=0x...
PAYMENT_TOKEN=0x...
INITIAL_OWNER=0x...
FREEZE_TBN_MINTER=true
RENOUNCE_PMM_OWNERSHIP=true
RENOUNCE_TBN_OWNERSHIP=true
```

Check a deployment:

```bash
PMM_V2_ADDRESS=0x... TBN_ADDRESS=0x... PAYMENT_TOKEN=0x... npm run check:v2 -- --network mainnet
```

## Helper Script

`pmmV2-helper.py` provides basic read and transaction helpers for PMM V2.

```bash
PMM_V2_ADDRESS=0x...
TBN_ADDRESS=0x...
MAINNET_RPC_URL=https://...
PRIVATE_KEY=0x... # only required for transactions
```

Example commands:

```bash
python pmmV2-helper.py health
python pmmV2-helper.py agent-id https://agent.example
python pmmV2-helper.py validate 15 20
python pmmV2-helper.py create https://agent.example 15 20
python pmmV2-helper.py relocate <agent_id_hash> 15 20 20 21
python pmmV2-helper.py claim-tbn
python pmmV2-helper.py redeem-fee-vault
```

## License

The PMM V2 core contracts are licensed under the Business Source License 1.1. The license permits downstream applications, frontends, dashboards, agents, bots, integrations, APIs, SDKs, analytics, and similar services to build on top of Bittenbin's official deployed PMM V2 protocol contracts by default.

The BUSL restriction applies to deploying, operating, or making available a separate or competing production instance of the PMM V2 core protocol before the Change Date. See [licenses/BUSL_LICENSE](licenses/BUSL_LICENSE).

Files that remain MIT-licensed are covered by [licenses/MIT_LICENSE](licenses/MIT_LICENSE).
