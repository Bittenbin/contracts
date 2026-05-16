#!/usr/bin/env python3
"""
PMM V2 Cookbook - Ethereum Mainnet

This script provides read and transaction helpers for the fresh PMM v2 contracts:
- PythagoreanMarketMakerV2
- Tenbinium (TBN)
- USDC payment token

Required environment variables for transactions:
  PRIVATE_KEY=0x...

Required once PMM v2 is deployed:
  PMM_V2_ADDRESS=0x...
  TBN_ADDRESS=0x...

Optional:
  ETHEREUM_RPC_URL=https://...
  USDC_ADDRESS=0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48

Examples:
  python pmm_cookbook_mainnet.py health
  python pmm_cookbook_mainnet.py agent-id https://agent.example
  python pmm_cookbook_mainnet.py validate 15 20
  python pmm_cookbook_mainnet.py state <agent_id>
  python pmm_cookbook_mainnet.py create <agent_id> 15 20
  python pmm_cookbook_mainnet.py relocate <agent_id> 15 20 20 21
  python pmm_cookbook_mainnet.py claim-tbn
"""

import argparse
import math
import os
from typing import Any, Dict, Optional

from dotenv import load_dotenv
from eth_account import Account
from web3 import Web3

load_dotenv()

RPC_URL = os.getenv("ETHEREUM_RPC_URL", "https://ethereum.publicnode.com")
CHAIN_ID = 1
USDC_ADDRESS = Web3.to_checksum_address(
    os.getenv("USDC_ADDRESS", "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48")
)
PMM_ADDRESS = os.getenv("PMM_V2_ADDRESS")
TBN_ADDRESS = os.getenv("TBN_ADDRESS")

PMM_V2_ABI = [
    {
        "inputs": [
            {"name": "agentId", "type": "bytes32"},
            {"name": "x", "type": "uint256"},
            {"name": "y", "type": "uint256"},
        ],
        "name": "createAgent",
        "outputs": [],
        "type": "function",
    },
    {
        "inputs": [
            {"name": "agentId", "type": "bytes32"},
            {"name": "currentX", "type": "uint256"},
            {"name": "currentY", "type": "uint256"},
            {"name": "newX", "type": "uint256"},
            {"name": "newY", "type": "uint256"},
        ],
        "name": "relocateAgent",
        "outputs": [],
        "type": "function",
    },
    {
        "inputs": [],
        "name": "claimTBN",
        "outputs": [{"name": "amount", "type": "uint256"}],
        "type": "function",
    },
    {
        "inputs": [{"name": "agentId", "type": "bytes32"}],
        "name": "getAgentState",
        "outputs": [
            {"name": "x", "type": "uint256"},
            {"name": "y", "type": "uint256"},
            {"name": "c", "type": "uint256"},
            {"name": "exists", "type": "bool"},
        ],
        "type": "function",
    },
    {
        "inputs": [
            {"name": "agentId", "type": "bytes32"},
            {"name": "participant", "type": "address"},
        ],
        "name": "getExposure",
        "outputs": [
            {"name": "xExposure", "type": "uint256"},
            {"name": "yExposure", "type": "uint256"},
            {"name": "exists", "type": "bool"},
        ],
        "type": "function",
    },
    {
        "inputs": [{"name": "solver", "type": "address"}],
        "name": "pendingTBN",
        "outputs": [{"name": "", "type": "uint256"}],
        "type": "function",
    },
    {
        "inputs": [
            {"name": "agentA", "type": "bytes32"},
            {"name": "agentB", "type": "bytes32"},
        ],
        "name": "areConnected",
        "outputs": [{"name": "", "type": "bool"}],
        "type": "function",
    },
    {
        "inputs": [
            {"name": "x", "type": "uint256"},
            {"name": "y", "type": "uint256"},
        ],
        "name": "isValidCoordinate",
        "outputs": [{"name": "", "type": "bool"}],
        "type": "function",
    },
    {
        "inputs": [],
        "name": "totalStakedValue",
        "outputs": [{"name": "", "type": "uint256"}],
        "type": "function",
    },
    {
        "inputs": [],
        "name": "nMax",
        "outputs": [{"name": "", "type": "uint256"}],
        "type": "function",
    },
    {
        "inputs": [{"name": "", "type": "address"}],
        "name": "solverRewards",
        "outputs": [
            {"name": "power", "type": "uint256"},
            {"name": "rewardPerPowerPaid", "type": "uint256"},
            {"name": "unclaimed", "type": "uint256"},
        ],
        "type": "function",
    },
    {
        "inputs": [],
        "name": "accumulatedProtocolFees",
        "outputs": [{"name": "", "type": "uint256"}],
        "type": "function",
    },
]

ERC20_ABI = [
    {
        "inputs": [
            {"name": "spender", "type": "address"},
            {"name": "amount", "type": "uint256"},
        ],
        "name": "approve",
        "outputs": [{"name": "", "type": "bool"}],
        "type": "function",
    },
    {
        "inputs": [
            {"name": "owner", "type": "address"},
            {"name": "spender", "type": "address"},
        ],
        "name": "allowance",
        "outputs": [{"name": "", "type": "uint256"}],
        "type": "function",
    },
    {
        "inputs": [{"name": "account", "type": "address"}],
        "name": "balanceOf",
        "outputs": [{"name": "", "type": "uint256"}],
        "type": "function",
    },
    {
        "inputs": [],
        "name": "decimals",
        "outputs": [{"name": "", "type": "uint8"}],
        "type": "function",
    },
    {
        "inputs": [],
        "name": "symbol",
        "outputs": [{"name": "", "type": "string"}],
        "type": "function",
    },
]


class PMMV2Cookbook:
    def __init__(self, private_key: Optional[str] = None):
        self.w3 = Web3(Web3.HTTPProvider(RPC_URL))
        self.account = Account.from_key(private_key) if private_key else None
        self.usdc = self.w3.eth.contract(address=USDC_ADDRESS, abi=ERC20_ABI)
        self.usdc_decimals = self.usdc.functions.decimals().call()
        self.usdc_unit = 10**self.usdc_decimals
        self.pmm = self._contract(PMM_ADDRESS, PMM_V2_ABI)
        self.tbn = self._contract(TBN_ADDRESS, ERC20_ABI)

    def _contract(self, address: Optional[str], abi: list):
        if not address:
            return None
        return self.w3.eth.contract(address=Web3.to_checksum_address(address), abi=abi)

    def require_pmm(self):
        if self.pmm is None:
            raise ValueError("Set PMM_V2_ADDRESS in your environment.")

    def require_tbn(self):
        if self.tbn is None:
            raise ValueError("Set TBN_ADDRESS in your environment.")

    def require_account(self):
        if self.account is None:
            raise ValueError("Set PRIVATE_KEY or instantiate with a private key.")

    @staticmethod
    def agent_id(primary_id: str) -> str:
        return Web3.keccak(text=primary_id).hex()

    @staticmethod
    def hypotenuse(x: int, y: int) -> int:
        c = math.isqrt((x * x) + (y * y))
        if (c * c) != (x * x) + (y * y):
            raise ValueError("Coordinates are not a Pythagorean triple.")
        return c

    def format_usdc(self, amount: int) -> str:
        return f"{amount / self.usdc_unit:,.6f} USDC"

    def format_tbn(self, amount: int) -> str:
        return f"{amount / 10**18:,.6f} TBN"

    def payment_quote(self, current_c: int, new_c: int) -> Dict[str, Any]:
        delta_c = new_c - current_c
        value = abs(delta_c) * self.usdc_unit
        fee = value // 100
        if delta_c > 0:
            return {
                "action": "payment",
                "deltaC": delta_c,
                "value": self.format_usdc(value),
                "fee": self.format_usdc(fee),
                "total": self.format_usdc(value + fee),
            }
        if delta_c < 0:
            return {
                "action": "refund",
                "deltaC": delta_c,
                "value": self.format_usdc(value),
                "fee": self.format_usdc(fee),
                "net": self.format_usdc(value - fee),
            }
        return {"action": "zero-delta", "deltaC": 0, "value": self.format_usdc(0)}

    def health(self) -> Dict[str, Any]:
        self.require_pmm()
        return {
            "chain_id": self.w3.eth.chain_id,
            "connected": self.w3.is_connected(),
            "pmm": self.pmm.address,
            "tbn": self.tbn.address if self.tbn else None,
            "usdc": self.usdc.address,
            "totalStakedValue": self.pmm.functions.totalStakedValue().call(),
            "nMax": self.pmm.functions.nMax().call(),
            "accumulatedProtocolFees": self.format_usdc(
                self.pmm.functions.accumulatedProtocolFees().call()
            ),
        }

    def validate_coordinate(self, x: int, y: int) -> Dict[str, Any]:
        self.require_pmm()
        valid = self.pmm.functions.isValidCoordinate(x, y).call()
        c = math.isqrt((x * x) + (y * y))
        return {"x": x, "y": y, "c": c, "valid": valid}

    def get_agent_state(self, agent_id: str) -> Dict[str, Any]:
        self.require_pmm()
        x, y, c, exists = self.pmm.functions.getAgentState(agent_id).call()
        return {"agentId": agent_id, "exists": exists, "x": x, "y": y, "c": c}

    def get_exposure(self, agent_id: str, participant: str) -> Dict[str, Any]:
        self.require_pmm()
        x, y, exists = self.pmm.functions.getExposure(
            agent_id, Web3.to_checksum_address(participant)
        ).call()
        return {"agentId": agent_id, "participant": participant, "exists": exists, "x": x, "y": y}

    def get_solver_rewards(self, solver: str) -> Dict[str, Any]:
        self.require_pmm()
        solver = Web3.to_checksum_address(solver)
        power, reward_per_power_paid, unclaimed = self.pmm.functions.solverRewards(solver).call()
        pending = self.pmm.functions.pendingTBN(solver).call()
        return {
            "solver": solver,
            "power": power,
            "rewardPerPowerPaid": reward_per_power_paid,
            "unclaimed": self.format_tbn(unclaimed),
            "pending": self.format_tbn(pending),
        }

    def are_connected(self, agent_a: str, agent_b: str) -> bool:
        self.require_pmm()
        return self.pmm.functions.areConnected(agent_a, agent_b).call()

    def balances(self, address: str) -> Dict[str, Any]:
        address = Web3.to_checksum_address(address)
        result = {
            "address": address,
            "eth": self.w3.from_wei(self.w3.eth.get_balance(address), "ether"),
            "usdc": self.format_usdc(self.usdc.functions.balanceOf(address).call()),
        }
        if self.tbn:
            result["tbn"] = self.format_tbn(self.tbn.functions.balanceOf(address).call())
        return result

    def allowance(self, token, owner: str, spender: str) -> int:
        return token.functions.allowance(
            Web3.to_checksum_address(owner), Web3.to_checksum_address(spender)
        ).call()

    def approve_usdc(self, amount: int):
        self.require_pmm()
        return self._send(self.usdc.functions.approve(self.pmm.address, amount))

    def approve_tbn_burn(self, amount: int = 10**18):
        self.require_pmm()
        self.require_tbn()
        return self._send(self.tbn.functions.approve(self.pmm.address, amount))

    def create_agent(self, agent_id: str, x: int, y: int):
        self.require_pmm()
        return self._send(self.pmm.functions.createAgent(agent_id, x, y))

    def relocate_agent(self, agent_id: str, current_x: int, current_y: int, new_x: int, new_y: int):
        self.require_pmm()
        return self._send(
            self.pmm.functions.relocateAgent(agent_id, current_x, current_y, new_x, new_y)
        )

    def claim_tbn(self):
        self.require_pmm()
        return self._send(self.pmm.functions.claimTBN())

    def _send(self, function_call):
        self.require_account()
        tx = function_call.build_transaction(
            {
                "from": self.account.address,
                "nonce": self.w3.eth.get_transaction_count(self.account.address),
                "chainId": CHAIN_ID,
            }
        )
        signed = self.account.sign_transaction(tx)
        tx_hash = self.w3.eth.send_raw_transaction(signed.raw_transaction)
        receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash)
        return {"txHash": tx_hash.hex(), "status": receipt.status, "gasUsed": receipt.gasUsed}


def print_result(result: Any):
    if isinstance(result, dict):
        for key, value in result.items():
            print(f"{key}: {value}")
    else:
        print(result)


def main():
    parser = argparse.ArgumentParser(description="PMM V2 Ethereum mainnet cookbook")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("health")
    agent_id_parser = sub.add_parser("agent-id")
    agent_id_parser.add_argument("primary_id")

    validate = sub.add_parser("validate")
    validate.add_argument("x", type=int)
    validate.add_argument("y", type=int)

    state = sub.add_parser("state")
    state.add_argument("agent_id")

    exposure = sub.add_parser("exposure")
    exposure.add_argument("agent_id")
    exposure.add_argument("participant")

    rewards = sub.add_parser("rewards")
    rewards.add_argument("solver")

    connected = sub.add_parser("connected")
    connected.add_argument("agent_a")
    connected.add_argument("agent_b")

    balances = sub.add_parser("balances")
    balances.add_argument("address")

    approve_usdc = sub.add_parser("approve-usdc")
    approve_usdc.add_argument("amount", type=float, help="USDC amount")

    sub.add_parser("approve-tbn-burn")

    create = sub.add_parser("create")
    create.add_argument("agent_id")
    create.add_argument("x", type=int)
    create.add_argument("y", type=int)

    relocate = sub.add_parser("relocate")
    relocate.add_argument("agent_id")
    relocate.add_argument("current_x", type=int)
    relocate.add_argument("current_y", type=int)
    relocate.add_argument("new_x", type=int)
    relocate.add_argument("new_y", type=int)

    sub.add_parser("claim-tbn")

    args = parser.parse_args()
    cookbook = PMMV2Cookbook(os.getenv("PRIVATE_KEY"))

    if args.command == "health":
        print_result(cookbook.health())
    elif args.command == "agent-id":
        print(cookbook.agent_id(args.primary_id))
    elif args.command == "validate":
        print_result(cookbook.validate_coordinate(args.x, args.y))
    elif args.command == "state":
        print_result(cookbook.get_agent_state(args.agent_id))
    elif args.command == "exposure":
        print_result(cookbook.get_exposure(args.agent_id, args.participant))
    elif args.command == "rewards":
        print_result(cookbook.get_solver_rewards(args.solver))
    elif args.command == "connected":
        print(cookbook.are_connected(args.agent_a, args.agent_b))
    elif args.command == "balances":
        print_result(cookbook.balances(args.address))
    elif args.command == "approve-usdc":
        print_result(cookbook.approve_usdc(int(args.amount * cookbook.usdc_unit)))
    elif args.command == "approve-tbn-burn":
        print_result(cookbook.approve_tbn_burn())
    elif args.command == "create":
        print_result(cookbook.create_agent(args.agent_id, args.x, args.y))
    elif args.command == "relocate":
        print_result(
            cookbook.relocate_agent(
                args.agent_id, args.current_x, args.current_y, args.new_x, args.new_y
            )
        )
    elif args.command == "claim-tbn":
        print_result(cookbook.claim_tbn())


if __name__ == "__main__":
    main()
