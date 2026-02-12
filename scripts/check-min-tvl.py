#!/usr/bin/env python3
"""
Check whether the heuristic minimumFloatEstimate is <= actual minTVL.

Method:
- Pull all MarketCreated events from deployment block.
- For each market, read current (x, y).
- Sum sqrt((x^2 + y^2) * paymentTokenDecimals^2) in raw token units.
- Compare with minimumFloatEstimate() from the contract.
"""

import math
import os
from typing import List

from web3 import Web3
from dotenv import load_dotenv

load_dotenv()

BASE_RPC_URL = os.getenv("BASE_RPC_URL", "https://mainnet.base.org")

PMM_ADDRESS = "0xc114Af4E0B845D268a744bEf780B5073bE06Ce97"
USDC_ADDRESS = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
DEPLOYMENT_BLOCK = int(os.getenv("PMM_DEPLOYMENT_BLOCK", "41879823"))

PMM_ABI = [
    {
        "anonymous": False,
        "inputs": [
            {"indexed": True, "name": "pageId", "type": "uint256"},
            {"indexed": True, "name": "creator", "type": "address"},
            {"indexed": False, "name": "x", "type": "uint256"},
            {"indexed": False, "name": "y", "type": "uint256"},
            {"indexed": False, "name": "cost", "type": "uint256"},
        ],
        "name": "MarketCreated",
        "type": "event",
    },
    {"inputs": [], "name": "minimumFloatEstimate", "outputs": [{"name": "", "type": "uint256"}], "type": "function"},
    {"inputs": [], "name": "totalMarkets", "outputs": [{"name": "", "type": "uint256"}], "type": "function"},
    {"inputs": [{"name": "pageId", "type": "uint256"}], "name": "marketExists", "outputs": [{"name": "", "type": "bool"}], "type": "function"},
    {
        "inputs": [{"name": "pageId", "type": "uint256"}],
        "name": "getMarketState",
        "outputs": [
            {"name": "x", "type": "uint256"},
            {"name": "y", "type": "uint256"},
            {"name": "pageScore", "type": "uint256"},
            {"name": "totalVotes", "type": "uint256"},
        ],
        "type": "function",
    },
]

ERC20_ABI = [
    {"inputs": [], "name": "decimals", "outputs": [{"name": "", "type": "uint8"}], "type": "function"},
]


def _scaled_hypotenuse(x: int, y: int, decimals: int) -> int:
    sum_squares = x * x + y * y
    d = 10 ** decimals
    return math.isqrt(sum_squares * d * d)


def main() -> None:
    w3 = Web3(Web3.HTTPProvider(BASE_RPC_URL))
    pmm = w3.eth.contract(address=PMM_ADDRESS, abi=PMM_ABI)
    usdc = w3.eth.contract(address=USDC_ADDRESS, abi=ERC20_ABI)

    latest = w3.eth.block_number
    decimals = usdc.functions.decimals().call()

    events = pmm.events.MarketCreated.get_logs(from_block=DEPLOYMENT_BLOCK, to_block=latest)
    page_ids: List[int] = sorted({event["args"]["pageId"] for event in events})

    actual_total = 0
    active_markets = 0
    for page_id in page_ids:
        if not pmm.functions.marketExists(page_id).call():
            continue
        x, y, _, _ = pmm.functions.getMarketState(page_id).call()
        actual_total += _scaled_hypotenuse(x, y, decimals)
        active_markets += 1

    heuristic = pmm.functions.minimumFloatEstimate().call()
    total_markets = pmm.functions.totalMarkets().call()

    print("PMM minTVL check")
    print("----------------")
    print(f"RPC: {BASE_RPC_URL}")
    print(f"Deployment block: {DEPLOYMENT_BLOCK}")
    print(f"Events fetched: {len(events)}")
    print(f"Active markets found: {active_markets}")
    print(f"totalMarkets() on-chain: {total_markets}")
    print(f"USDC decimals: {decimals}")
    print(f"Heuristic minimumFloatEstimate (raw): {heuristic}")
    print(f"Actual minTVL (raw): {actual_total}")

    if actual_total == 0:
        print("Result: actual minTVL is zero; comparison is trivial.")
    elif heuristic <= actual_total:
        ratio = actual_total / heuristic if heuristic > 0 else float("inf")
        print(f"Result: OK (heuristic <= actual). Ratio: {ratio:.6f}x")
    else:
        ratio = heuristic / actual_total
        print(f"Result: FAIL (heuristic > actual). Ratio: {ratio:.6f}x")


if __name__ == "__main__":
    main()
