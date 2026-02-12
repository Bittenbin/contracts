#!/usr/bin/env python3
"""
PMM Schematic - Base Mainnet
Reference guide for interacting with the latest PMM deployment.

Key facts:
- Payment token: USDC (Base)
- Reward token: TENBINIUM (TBN)
- Markets are created from a URL (pageId = keccak256(url))
- Single-axis moves only (x changes OR y changes)

Addresses (Base Mainnet):
- PMM Proxy: 0xc114Af4E0B845D268a744bEf780B5073bE06Ce97
- TENBINIUM (TBN): 0x942C0BfACFAB198E818d71bB0dceC091F213FCC9
- USDC: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
- Owner Fee Recipient: 0x2dfc776B09234f617DFc38Cb8De1BB2B0B7C4E5B
- Protocol Fee Recipient: 0xb322A547De3308C2426aEa700c8176574E57eEe6

Requirements:
pip install web3==7.12.0 eth-account python-dotenv

Usage examples:
  python schematic.py page-id https://apple.com
  python schematic.py check-market https://apple.com
  python schematic.py token-info
  python schematic.py health

For transactions, import and use PMMClient with a private key.
"""

import math
import os
from typing import Dict, Optional, Any, Tuple

from web3 import Web3
from eth_account import Account
from dotenv import load_dotenv

load_dotenv()

BASE_MAINNET_RPC = os.getenv("BASE_RPC_URL", "https://mainnet.base.org")
CHAIN_ID = 8453

PMM_ADDRESS = "0xc114Af4E0B845D268a744bEf780B5073bE06Ce97"
USDC_ADDRESS = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
TBN_ADDRESS = "0x942C0BfACFAB198E818d71bB0dceC091F213FCC9"

PMM_ABI = [
    # Market creation
    {
        "inputs": [
            {"name": "url", "type": "string"},
            {"name": "initialX", "type": "uint256"},
            {"name": "initialY", "type": "uint256"},
        ],
        "name": "createMarket",
        "outputs": [],
        "type": "function",
    },
    {
        "inputs": [
            {"name": "url", "type": "string"},
            {"name": "initialX", "type": "uint256"},
            {"name": "initialY", "type": "uint256"},
            {"name": "slippageBasisPoints", "type": "uint256"},
        ],
        "name": "createMarketWithSlippage",
        "outputs": [],
        "type": "function",
    },
    # Voting
    {
        "inputs": [
            {"name": "pageId", "type": "uint256"},
            {"name": "newX", "type": "uint256"},
            {"name": "newY", "type": "uint256"},
        ],
        "name": "voteOnMarket",
        "outputs": [],
        "type": "function",
    },
    {
        "inputs": [
            {"name": "pageId", "type": "uint256"},
            {"name": "newX", "type": "uint256"},
            {"name": "newY", "type": "uint256"},
            {"name": "slippageBasisPoints", "type": "uint256"},
        ],
        "name": "voteOnMarketWithSlippage",
        "outputs": [],
        "type": "function",
    },
    # Rewards
    {
        "inputs": [],
        "name": "claimRewards",
        "outputs": [],
        "type": "function",
    },
    # Market state
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
    {
        "inputs": [{"name": "pageId", "type": "uint256"}],
        "name": "marketExists",
        "outputs": [{"name": "", "type": "bool"}],
        "type": "function",
    },
    {
        "inputs": [{"name": "pageId", "type": "uint256"}],
        "name": "marketUrlHash",
        "outputs": [{"name": "", "type": "bytes32"}],
        "type": "function",
    },
    {
        "inputs": [
            {"name": "pageId", "type": "uint256"},
            {"name": "voter", "type": "address"},
        ],
        "name": "getVoterPosition",
        "outputs": [
            {"name": "upVotes", "type": "uint256"},
            {"name": "downVotes", "type": "uint256"},
            {"name": "exists", "type": "bool"},
        ],
        "type": "function",
    },
    # Pricing helpers
    {
        "inputs": [
            {"name": "currentX", "type": "uint256"},
            {"name": "currentY", "type": "uint256"},
            {"name": "newX", "type": "uint256"},
            {"name": "newY", "type": "uint256"},
            {"name": "slippageBasisPoints", "type": "uint256"},
        ],
        "name": "calculatePaymentWithSlippage",
        "outputs": [
            {"name": "expectedPayment", "type": "uint256"},
            {"name": "maxPaymentWithSlippage", "type": "uint256"},
        ],
        "type": "function",
    },
    {
        "inputs": [
            {"name": "currentX", "type": "uint256"},
            {"name": "currentY", "type": "uint256"},
            {"name": "newX", "type": "uint256"},
            {"name": "newY", "type": "uint256"},
            {"name": "slippageBasisPoints", "type": "uint256"},
        ],
        "name": "calculateRefundWithSlippage",
        "outputs": [
            {"name": "expectedRefund", "type": "uint256"},
            {"name": "minRefundWithSlippage", "type": "uint256"},
        ],
        "type": "function",
    },
    # Globals
    {"inputs": [], "name": "paymentToken", "outputs": [{"name": "", "type": "address"}], "type": "function"},
    {"inputs": [], "name": "rewardToken", "outputs": [{"name": "", "type": "address"}], "type": "function"},
    {"inputs": [], "name": "totalMarkets", "outputs": [{"name": "", "type": "uint256"}], "type": "function"},
    {"inputs": [], "name": "minimumFloatEstimate", "outputs": [{"name": "", "type": "uint256"}], "type": "function"},
    {"inputs": [], "name": "getContractBalance", "outputs": [{"name": "balance", "type": "uint256"}], "type": "function"},
    {"inputs": [], "name": "getAvailableLiquidity", "outputs": [{"name": "liquidity", "type": "uint256"}], "type": "function"},
    {"inputs": [], "name": "PROTOCOL_FEE_BASIS_POINTS", "outputs": [{"name": "", "type": "uint256"}], "type": "function"},
    {"inputs": [], "name": "DEFAULT_SLIPPAGE_BASIS_POINTS", "outputs": [{"name": "", "type": "uint256"}], "type": "function"},
]

ERC20_ABI = [
    {"inputs": [{"name": "account", "type": "address"}], "name": "balanceOf", "outputs": [{"name": "", "type": "uint256"}], "type": "function"},
    {"inputs": [{"name": "owner", "type": "address"}, {"name": "spender", "type": "address"}], "name": "allowance", "outputs": [{"name": "", "type": "uint256"}], "type": "function"},
    {"inputs": [{"name": "spender", "type": "address"}, {"name": "amount", "type": "uint256"}], "name": "approve", "outputs": [{"name": "", "type": "bool"}], "type": "function"},
    {"inputs": [], "name": "decimals", "outputs": [{"name": "", "type": "uint8"}], "type": "function"},
    {"inputs": [], "name": "name", "outputs": [{"name": "", "type": "string"}], "type": "function"},
    {"inputs": [], "name": "symbol", "outputs": [{"name": "", "type": "string"}], "type": "function"},
    {"inputs": [], "name": "totalSupply", "outputs": [{"name": "", "type": "uint256"}], "type": "function"},
    {"inputs": [], "name": "minter", "outputs": [{"name": "", "type": "address"}], "type": "function"},
]


class CoordinateHelper:
    """Coordinate utilities for PMM."""

    MAX_COORDINATE = 1_000_000_000
    MAX_HYPOTENUSE = 1_500_000_000

    @staticmethod
    def is_valid_coordinate(x: int, y: int) -> bool:
        if x <= 0 or y <= 0:
            return False
        if x > CoordinateHelper.MAX_COORDINATE or y > CoordinateHelper.MAX_COORDINATE:
            return False
        return (x * x + y * y) <= (CoordinateHelper.MAX_HYPOTENUSE ** 2)

    @staticmethod
    def calculate_page_score(x: int, y: int) -> float:
        if x == 0 and y == 0:
            return 0.0
        return (y * y) / (x * x + y * y)


def url_to_page_id(url: str) -> int:
    return int.from_bytes(Web3.keccak(text=url), byteorder="big")


class PMMClient:
    """Main PMM client for Base mainnet."""

    def __init__(self, private_key: Optional[str] = None):
        self.w3 = Web3(Web3.HTTPProvider(BASE_MAINNET_RPC))
        self.pmm = self.w3.eth.contract(address=PMM_ADDRESS, abi=PMM_ABI)
        self.usdc = self.w3.eth.contract(address=USDC_ADDRESS, abi=ERC20_ABI)
        self.tbn = self.w3.eth.contract(address=TBN_ADDRESS, abi=ERC20_ABI)

        self.account = Account.from_key(private_key) if private_key else None
        self.helper = CoordinateHelper()

        self.usdc_decimals = self.usdc.functions.decimals().call()
        self.usdc_multiplier = 10 ** self.usdc_decimals

        self.tbn_decimals = self.tbn.functions.decimals().call()
        self.tbn_multiplier = 10 ** self.tbn_decimals

        self.protocol_fee_basis_points = self.pmm.functions.PROTOCOL_FEE_BASIS_POINTS().call()
        self.default_slippage_basis_points = self.pmm.functions.DEFAULT_SLIPPAGE_BASIS_POINTS().call()
        self.basis_points_denominator = 10000

    def format_usdc(self, amount: int) -> str:
        return f"{amount / self.usdc_multiplier:,.6f} USDC"

    def format_tbn(self, amount: int) -> str:
        return f"{amount / self.tbn_multiplier:,.6f} TBN"

    def calculate_cost(self, current_x: int, current_y: int, new_x: int, new_y: int) -> Dict[str, Any]:
        current_scaled = math.isqrt((current_x * current_x + current_y * current_y) * (self.usdc_multiplier ** 2))
        new_scaled = math.isqrt((new_x * new_x + new_y * new_y) * (self.usdc_multiplier ** 2))
        delta = new_scaled - current_scaled
        if delta > 0:
            fee = (delta * self.protocol_fee_basis_points) // self.basis_points_denominator
            total = delta + fee
            return {"action": "buy", "payment": delta, "protocol_fee": fee, "total": total}
        if delta < 0:
            refund = -delta
            fee = (refund * self.protocol_fee_basis_points) // self.basis_points_denominator
            return {"action": "sell", "refund": refund, "protocol_fee": fee, "net_refund": refund - fee}
        return {"action": "rebalance", "payment": 0, "protocol_fee": 0, "total": 0}

    # Read helpers
    def check_market(self, page_id: int) -> Dict[str, Any]:
        exists = self.pmm.functions.marketExists(page_id).call()
        if not exists:
            return {"exists": False, "page_id": page_id}
        x, y, page_score, total_votes = self.pmm.functions.getMarketState(page_id).call()
        return {
            "exists": True,
            "page_id": page_id,
            "x": x,
            "y": y,
            "page_score": page_score / 10**18,
            "page_score_percent": (page_score / 10**18) * 100,
            "total_votes": total_votes,
            "position": f"({x}, {y})",
        }

    def check_voter_position(self, page_id: int, voter: str) -> Dict[str, Any]:
        up_votes, down_votes, exists = self.pmm.functions.getVoterPosition(page_id, voter).call()
        if not exists:
            return {"exists": False, "page_id": page_id, "voter": voter}
        return {
            "exists": True,
            "page_id": page_id,
            "voter": voter,
            "up_votes": up_votes,
            "down_votes": down_votes,
            "position": f"({down_votes}, {up_votes})",
        }

    def check_balance(self, address: str) -> Dict[str, Any]:
        eth_balance = self.w3.eth.get_balance(address)
        usdc_balance = self.usdc.functions.balanceOf(address).call()
        tbn_balance = self.tbn.functions.balanceOf(address).call()
        return {
            "address": address,
            "eth_balance": eth_balance / 10**18,
            "eth_formatted": f"{eth_balance / 10**18:.6f} ETH",
            "usdc_balance": usdc_balance / self.usdc_multiplier,
            "usdc_formatted": self.format_usdc(usdc_balance),
            "tbn_balance": tbn_balance / self.tbn_multiplier,
            "tbn_formatted": self.format_tbn(tbn_balance),
        }

    def check_allowance(self, owner_address: str) -> Dict[str, Any]:
        allowance = self.usdc.functions.allowance(owner_address, PMM_ADDRESS).call()
        return {"allowance": allowance, "allowance_formatted": self.format_usdc(allowance)}

    def get_token_info(self) -> Dict[str, Any]:
        tbn_name = self.tbn.functions.name().call()
        tbn_symbol = self.tbn.functions.symbol().call()
        tbn_total = self.tbn.functions.totalSupply().call()
        tbn_minter = self.tbn.functions.minter().call()
        return {
            "network": "Base Mainnet",
            "reward_token": TBN_ADDRESS,
            "reward_name": tbn_name,
            "reward_symbol": tbn_symbol,
            "reward_decimals": self.tbn_decimals,
            "reward_total_supply": tbn_total,
            "reward_total_supply_formatted": self.format_tbn(tbn_total),
            "reward_minter": tbn_minter,
            "pmm_is_minter": tbn_minter.lower() == PMM_ADDRESS.lower(),
            "payment_token": USDC_ADDRESS,
            "payment_decimals": self.usdc_decimals,
        }

    def get_contract_health(self) -> Dict[str, Any]:
        total_balance = self.pmm.functions.getContractBalance().call()
        available = self.pmm.functions.getAvailableLiquidity().call()
        total_markets = self.pmm.functions.totalMarkets().call()
        return {
            "total_balance": total_balance,
            "total_balance_formatted": self.format_usdc(total_balance),
            "available_liquidity": available,
            "available_liquidity_formatted": self.format_usdc(available),
            "total_markets": total_markets,
        }

    # Write helpers
    def _build_and_send_tx(self, tx_function, gas: int = 500000) -> str:
        if not self.account:
            raise ValueError("Private key required for transactions")
        tx = tx_function.build_transaction({
            "from": self.account.address,
            "nonce": self.w3.eth.get_transaction_count(self.account.address),
            "gas": gas,
            "gasPrice": self.w3.eth.gas_price,
            "chainId": CHAIN_ID,
        })
        signed_tx = self.account.sign_transaction(tx)
        tx_hash = self.w3.eth.send_raw_transaction(signed_tx.raw_transaction)
        receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)
        if receipt["status"] == 0:
            raise Exception("Transaction failed")
        return tx_hash.hex()

    def approve_usdc(self, amount: float) -> str:
        amount_wei = int(amount * self.usdc_multiplier)
        return self._build_and_send_tx(
            self.usdc.functions.approve(PMM_ADDRESS, amount_wei),
            gas=100000
        )

    def create_market(self, url: str, initial_x: int, initial_y: int) -> str:
        if not self.account:
            raise ValueError("Private key required for transactions")
        if not self.helper.is_valid_coordinate(initial_x, initial_y):
            raise ValueError("Invalid coordinates for market creation")
        return self._build_and_send_tx(
            self.pmm.functions.createMarket(url, initial_x, initial_y),
            gas=350000
        )

    def vote_on_market(self, page_id: int, new_x: int, new_y: int) -> str:
        if not self.account:
            raise ValueError("Private key required for transactions")
        current = self.check_market(page_id)
        if not current["exists"]:
            raise ValueError("Market does not exist")
        x_changed = new_x != current["x"]
        y_changed = new_y != current["y"]
        if x_changed == y_changed:
            raise ValueError("Single-axis rule: change x OR y (not both)")
        return self._build_and_send_tx(
            self.pmm.functions.voteOnMarket(page_id, new_x, new_y),
            gas=350000
        )

    def claim_rewards(self) -> str:
        if not self.account:
            raise ValueError("Private key required for transactions")
        return self._build_and_send_tx(
            self.pmm.functions.claimRewards(),
            gas=200000
        )


def main():
    import sys

    if len(sys.argv) < 2:
        print("Usage: python schematic.py <command> [args]")
        print("\nCommands:")
        print("  page-id <url>                  - Compute pageId from URL")
        print("  check-market <url>             - Check market state by URL")
        print("  token-info                     - Reward token info")
        print("  health                         - Contract balances and totals")
        return

    command = sys.argv[1]
    client = PMMClient()

    if command == "page-id":
        if len(sys.argv) < 3:
            print("Usage: python schematic.py page-id <url>")
            return
        url = sys.argv[2]
        print(url_to_page_id(url))
        return

    if command == "check-market":
        if len(sys.argv) < 3:
            print("Usage: python schematic.py check-market <url>")
            return
        url = sys.argv[2]
        page_id = url_to_page_id(url)
        result = client.check_market(page_id)
        for key, value in result.items():
            print(f"{key}: {value}")
        return

    if command == "token-info":
        result = client.get_token_info()
        for key, value in result.items():
            print(f"{key}: {value}")
        return

    if command == "health":
        result = client.get_contract_health()
        for key, value in result.items():
            print(f"{key}: {value}")
        return

    print(f"Unknown command: {command}")


if __name__ == "__main__":
    main()
