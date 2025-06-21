#!/usr/bin/env python3
"""
Pythagorean Market Maker (PMM) Cookbook - Base Mainnet Version
Complete guide for interacting with PMM on Base Mainnet

⚠️  WARNING: This is for BASE MAINNET with REAL USDC!
⚠️  All transactions use real money. Be careful!

Contract Addresses (deployed 2025-01-15):
- PythagoreanMarketMaker: 0xC37CC635f5fAf9D10f1C620BDc8431Efe7526fc8
- USDC (Official): 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
- Owner Fee Recipient: 0x2dfc776B09234f617DFc38Cb8De1BB2B0B7C4E5B
- Protocol Fee Recipient: 0xb322A547De3308C2426aEa700c8176574E57eEe6

Requirements:
pip install web3==7.12.0 eth-account python-dotenv

Usage Examples:
  # Check if market exists (no private key needed)
  python pmm_cookbook_mainnet.py check-market 1234567890
  
  # Get USDC information
  python pmm_cookbook_mainnet.py get-usdc-info
  
  # Check contract health
  python pmm_cookbook_mainnet.py health

For transactions, import and use the PMM_Cookbook class with your private key.
"""

import math
from typing import List, Tuple, Optional, Dict
from web3 import Web3
from eth_account import Account
import secrets
from dotenv import load_dotenv

load_dotenv()

BASE_MAINNET_RPC = (
    "https://mainnet.base.org"  # You can also use your own RPC like Alchemy
)
CHAIN_ID = 8453

PMM_ADDRESS = "0xC37CC635f5fAf9D10f1C620BDc8431Efe7526fc8"
USDC_ADDRESS = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"  # Official USDC on Base
PMM_ABI = [
    {
        "inputs": [
            {"name": "platformId", "type": "uint256"},
            {"name": "initialX", "type": "uint256"},
            {"name": "initialY", "type": "uint256"},
        ],
        "name": "createMarket",
        "outputs": [],
        "type": "function",
    },
    {
        "inputs": [
            {"name": "platformId", "type": "uint256"},
            {"name": "initialX", "type": "uint256"},
            {"name": "initialY", "type": "uint256"},
            {"name": "slippageBasisPoints", "type": "uint256"},
        ],
        "name": "createMarketWithSlippage",
        "outputs": [],
        "type": "function",
    },
    {
        "inputs": [
            {"name": "platformId", "type": "uint256"},
            {"name": "newX", "type": "uint256"},
            {"name": "newY", "type": "uint256"},
        ],
        "name": "voteOnMarket",
        "outputs": [],
        "type": "function",
    },
    {
        "inputs": [
            {"name": "platformId", "type": "uint256"},
            {"name": "newX", "type": "uint256"},
            {"name": "newY", "type": "uint256"},
            {"name": "slippageBasisPoints", "type": "uint256"},
        ],
        "name": "voteOnMarketWithSlippage",
        "outputs": [],
        "type": "function",
    },
    {
        "inputs": [{"name": "platformId", "type": "uint256"}],
        "name": "getMarketState",
        "outputs": [
            {"name": "x", "type": "uint256"},
            {"name": "y", "type": "uint256"},
            {"name": "trustScore", "type": "uint256"},
            {"name": "totalVotes", "type": "uint256"},
        ],
        "type": "function",
    },
    {
        "inputs": [{"name": "platformId", "type": "uint256"}],
        "name": "marketExistsFor",
        "outputs": [{"name": "", "type": "bool"}],
        "type": "function",
    },
    {
        "inputs": [{"name": "x", "type": "uint256"}, {"name": "y", "type": "uint256"}],
        "name": "isValidCoordinate",
        "outputs": [{"name": "", "type": "bool"}],
        "type": "function",
    },
    {
        "inputs": [{"name": "x", "type": "uint256"}, {"name": "y", "type": "uint256"}],
        "name": "calculateTrustScore",
        "outputs": [{"name": "", "type": "uint256"}],
        "type": "function",
    },
    {
        "inputs": [],
        "name": "PROTOCOL_FEE_BASIS_POINTS",
        "outputs": [{"name": "", "type": "uint256"}],
        "type": "function",
    },
    {
        "inputs": [],
        "name": "DEFAULT_SLIPPAGE_BASIS_POINTS",
        "outputs": [{"name": "", "type": "uint256"}],
        "type": "function",
    },
    {
        "inputs": [],
        "name": "getDefaultSlippage",
        "outputs": [
            {"name": "slippageBasisPoints", "type": "uint256"},
            {"name": "slippagePercentage", "type": "uint256"},
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
    {
        "inputs": [],
        "name": "MINIMUM_VOTES",
        "outputs": [{"name": "", "type": "uint256"}],
        "type": "function",
    },
    {
        "inputs": [{"name": "", "type": "bytes32"}],
        "name": "coordinateToMarket",
        "outputs": [{"name": "", "type": "uint256"}],
        "type": "function",
    },
    {
        "inputs": [{"name": "", "type": "uint256"}],
        "name": "marketCoordinates",
        "outputs": [
            {"name": "x", "type": "uint256"},
            {"name": "y", "type": "uint256"},
        ],
        "type": "function",
    },
    {
        "inputs": [{"name": "", "type": "uint256"}],
        "name": "marketExists",
        "outputs": [{"name": "", "type": "bool"}],
        "type": "function",
    },
    {
        "inputs": [{"name": "", "type": "uint256"}],
        "name": "marketCreator",
        "outputs": [{"name": "", "type": "address"}],
        "type": "function",
    },
    {
        "inputs": [{"name": "", "type": "uint256"}],
        "name": "marketCreationTime",
        "outputs": [{"name": "", "type": "uint256"}],
        "type": "function",
    },
    {
        "inputs": [{"name": "", "type": "uint256"}],
        "name": "totalVoteVolume",
        "outputs": [{"name": "", "type": "uint256"}],
        "type": "function",
    },
    {
        "inputs": [],
        "name": "paymentToken",
        "outputs": [{"name": "", "type": "address"}],
        "type": "function",
    },
    {
        "inputs": [
            {"name": "platformId", "type": "uint256"},
            {"name": "voter", "type": "address"},
        ],
        "name": "getVoterPosition",
        "outputs": [
            {"name": "trustVotes", "type": "uint256"},
            {"name": "distrustVotes", "type": "uint256"},
            {"name": "exists", "type": "bool"},
        ],
        "type": "function",
    },
    {
        "inputs": [],
        "name": "getFeeDistributionInfo",
        "outputs": [
            {"name": "ownerRecipient", "type": "address"},
            {"name": "protocolRecipient", "type": "address"},
            {"name": "pendingFees", "type": "uint256"},
        ],
        "type": "function",
    },
    {
        "inputs": [],
        "name": "accumulatedProtocolFees",
        "outputs": [{"name": "", "type": "uint256"}],
        "type": "function",
    },
    {
        "inputs": [],
        "name": "calculateFeeDistribution",
        "outputs": [
            {"name": "ownerShare", "type": "uint256"},
            {"name": "protocolShare", "type": "uint256"},
        ],
        "type": "function",
    },
    {
        "inputs": [],
        "name": "distributeProtocolFees",
        "outputs": [{"name": "totalAmount", "type": "uint256"}],
        "type": "function",
    },
    {
        "inputs": [{"name": "amount", "type": "uint256"}],
        "name": "distributeProtocolFees",
        "outputs": [{"name": "totalAmount", "type": "uint256"}],
        "type": "function",
    },
    {
        "inputs": [{"name": "amount", "type": "uint256"}],
        "name": "withdrawToOwner",
        "outputs": [],
        "type": "function",
    },
    {
        "inputs": [
            {"name": "newOwnerRecipient", "type": "address"},
            {"name": "newProtocolRecipient", "type": "address"},
        ],
        "name": "updateFeeRecipients",
        "outputs": [],
        "type": "function",
    },
    {
        "inputs": [],
        "name": "ownerFeeRecipient",
        "outputs": [{"name": "", "type": "address"}],
        "type": "function",
    },
    {
        "inputs": [],
        "name": "protocolFeeRecipient",
        "outputs": [{"name": "", "type": "address"}],
        "type": "function",
    },
    {
        "inputs": [],
        "name": "owner",
        "outputs": [{"name": "", "type": "address"}],
        "type": "function",
    },
]

USDC_ABI = [
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
        "inputs": [
            {"name": "to", "type": "address"},
            {"name": "amount", "type": "uint256"},
        ],
        "name": "mint",
        "outputs": [],
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
]


def create_wallet():
    """Generate a new Ethereum wallet with a secure random private key."""
    print("Creating a new Ethereum wallet...\n")

    private_key = "0x" + secrets.token_hex(32)
    account = Account.from_key(private_key)

    print("🔐 New Wallet Created!")
    print("=" * 50)
    print(f"Address: {account.address}")
    print(f"Private Key: {private_key}")
    print("=" * 50)

    print("\n⚠️  IMPORTANT SECURITY NOTICE:")
    print("- Keep your private key SECRET!")
    print("- Never share it with anyone")
    print("- Store it in a secure location")
    print("- Consider using a hardware wallet for large amounts")

    return {"address": account.address, "private_key": private_key}


class PythagoreanHelper:
    """Python helper class for Pythagorean coordinate operations

    Note: This is a pure Python implementation for client-side calculations.
    The Solidity contract performs these validations on-chain.
    """

    @staticmethod
    def is_perfect_square(n: int) -> bool:
        """Check if a number is a perfect square"""
        if n < 0:
            return False
        root = int(math.sqrt(n))
        return root * root == n

    @staticmethod
    def is_valid_coordinate(x: int, y: int) -> bool:
        """Check if (x,y) forms a valid Pythagorean coordinate"""
        if x <= 0 or y <= 0:
            return False
        return PythagoreanHelper.is_perfect_square(x * x + y * y)

    @staticmethod
    def calculate_trust_score(x: int, y: int) -> float:
        """Calculate trust score as percentage"""
        if x == 0 and y == 0:
            return 0.0
        return (y * y) / (x * x + y * y)

    @staticmethod
    def generate_common_coordinates(max_votes: int = 50) -> List[Tuple[int, int, int]]:
        """Generate common Pythagorean triples"""
        triples = [
            (3, 4, 5),
            (5, 12, 13),
            (8, 15, 17),
            (7, 24, 25),
            (20, 21, 29),
            (9, 40, 41),
            (12, 35, 37),
            (11, 60, 61),
            (13, 84, 85),
        ]

        valid_triples = []
        for x, y, c in triples:
            if x + y <= max_votes:
                valid_triples.append((x, y, c))
            if y != x and y + x <= max_votes:
                valid_triples.append((y, x, c))

        return sorted(valid_triples, key=lambda t: t[0] + t[1])


class PMM_Cookbook:
    """Main cookbook class for PMM interactions"""

    def __init__(self, private_key: Optional[str] = None):
        """Initialize the cookbook

        Args:
            private_key: Private key for transactions (optional for read-only)
        """
        self.w3 = Web3(Web3.HTTPProvider(BASE_MAINNET_RPC))

        # Initialize contracts
        self.pmm = self.w3.eth.contract(address=PMM_ADDRESS, abi=PMM_ABI)
        self.usdc = self.w3.eth.contract(address=USDC_ADDRESS, abi=USDC_ABI)

        self.account = None
        if private_key:
            self.account = Account.from_key(private_key)

        self.helper = PythagoreanHelper()

        self.usdc_decimals = self.usdc.functions.decimals().call()
        self.usdc_multiplier = 10**self.usdc_decimals

        self.protocol_fee_basis_points = (
            self.pmm.functions.PROTOCOL_FEE_BASIS_POINTS().call()
        )
        self.basis_points_denominator = 10000
        self.minimum_votes = self.pmm.functions.MINIMUM_VOTES().call()

        try:
            self.default_slippage_basis_points = (
                self.pmm.functions.DEFAULT_SLIPPAGE_BASIS_POINTS().call()
            )
        except:
            self.default_slippage_basis_points = 250  # 2.5% fallback

    def format_usdc(self, amount: int) -> str:
        """Format USDC amount for display"""
        return f"{amount / self.usdc_multiplier:,.2f} USDC"

    def calculate_cost(self, votes: int, buying: bool = True) -> Dict[str, int]:
        """Calculate cost including protocol fee

        UPDATED: Now uses hypotenuse-based pricing instead of vote-based
        This method is kept for backward compatibility but the logic has changed
        """
        hypotenuse_in_usdc = votes * self.usdc_multiplier
        protocol_fee = (
            hypotenuse_in_usdc * self.protocol_fee_basis_points
        ) // self.basis_points_denominator

        if buying:
            total_cost = hypotenuse_in_usdc + protocol_fee
            return {
                "votes": votes,
                "votes_usdc": hypotenuse_in_usdc,
                "protocol_fee": protocol_fee,
                "total_cost": total_cost,
            }
        else:
            refund = hypotenuse_in_usdc - protocol_fee
            return {
                "votes": votes,
                "votes_usdc": hypotenuse_in_usdc,
                "protocol_fee": protocol_fee,
                "refund": refund,
            }

    def calculate_hypotenuse_cost(
        self, current_x: int, current_y: int, new_x: int, new_y: int
    ) -> Dict[str, any]:
        """Calculate the cost/refund for a vote transaction using hypotenuse formula"""
        current_hypotenuse = math.sqrt(current_x * current_x + current_y * current_y)
        new_hypotenuse = math.sqrt(new_x * new_x + new_y * new_y)
        hypotenuse_change = new_hypotenuse - current_hypotenuse

        if hypotenuse_change > 0:
            payment_usdc = hypotenuse_change * self.usdc_multiplier
            protocol_fee = (
                payment_usdc * self.protocol_fee_basis_points
            ) / self.basis_points_denominator
            total_cost = payment_usdc + protocol_fee

            return {
                "action": "buy",
                "hypotenuse_change": hypotenuse_change,
                "payment_usdc": payment_usdc,
                "protocol_fee": protocol_fee,
                "total_cost": total_cost,
                "total_cost_formatted": self.format_usdc(total_cost),
            }
        elif hypotenuse_change < 0:
            refund_usdc = -hypotenuse_change * self.usdc_multiplier
            protocol_fee = (
                refund_usdc * self.protocol_fee_basis_points
            ) / self.basis_points_denominator
            net_refund = refund_usdc - protocol_fee

            return {
                "action": "sell",
                "hypotenuse_change": hypotenuse_change,
                "refund_usdc": refund_usdc,
                "protocol_fee": protocol_fee,
                "net_refund": net_refund,
                "net_refund_formatted": self.format_usdc(net_refund),
            }
        else:
            return {
                "action": "rebalance",
                "hypotenuse_change": 0,
                "cost": 0,
                "cost_formatted": "0.00 USDC",
            }

    def check_market(self, platform_id: int) -> Dict:
        """Check if a market exists and get its state"""
        exists = self.pmm.functions.marketExistsFor(platform_id).call()

        if not exists:
            return {"exists": False, "platform_id": platform_id}

        x, y, trust_score_raw, total_votes = self.pmm.functions.getMarketState(
            platform_id
        ).call()

        return {
            "exists": True,
            "platform_id": platform_id,
            "x": x,
            "y": y,
            "trust_score": trust_score_raw / 10**18,
            "trust_score_percent": (trust_score_raw / 10**18) * 100,
            "total_votes": total_votes,
            "position": f"({x}, {y})",
            "hypotenuse": math.sqrt(x * x + y * y),
        }

    def check_voter_position(self, platform_id: int, voter_address: str) -> Dict:
        """Check a voter's position in a market"""
        trust_votes, distrust_votes, exists = self.pmm.functions.getVoterPosition(
            platform_id, voter_address
        ).call()

        if not exists:
            return {"exists": False, "platform_id": platform_id, "voter": voter_address}

        return {
            "exists": True,
            "platform_id": platform_id,
            "voter": voter_address,
            "trust_votes": trust_votes,
            "distrust_votes": distrust_votes,
            "total_votes": trust_votes + distrust_votes,
            "position": f"({distrust_votes}, {trust_votes})",
        }

    def validate_coordinate(self, x: int, y: int) -> Dict:
        """Validate if coordinates are valid"""
        _ = self.helper.is_valid_coordinate(x, y)
        is_valid_chain = self.pmm.functions.isValidCoordinate(x, y).call()

        result = {
            "x": x,
            "y": y,
            "valid": is_valid_chain,
            "total_votes": x + y,
            "trust_score": self.helper.calculate_trust_score(x, y),
            "trust_score_percent": self.helper.calculate_trust_score(x, y) * 100,
            "hypotenuse": math.sqrt(x * x + y * y),
        }

        if x + y < self.minimum_votes:
            result["error"] = f"Below minimum {self.minimum_votes} votes"
        elif x == y:
            result["error"] = "Cannot use genesis line (x = y)"
        elif not is_valid_chain:
            result["error"] = "Not a valid Pythagorean coordinate"

        return result

    def get_suggested_coordinates(
        self, target_trust_percent: float, max_votes: int = 50
    ) -> List[Dict]:
        """Get suggested coordinates for a target trust score"""
        target_trust = target_trust_percent / 100
        suggestions = []

        for x, y, c in self.helper.generate_common_coordinates(max_votes):
            trust_score = self.helper.calculate_trust_score(x, y)
            if abs(trust_score - target_trust) < 0.15:  # Within 15% of target
                hypotenuse = math.sqrt(x * x + y * y)
                cost_info = self.calculate_cost(int(hypotenuse), buying=True)
                suggestions.append(
                    {
                        "position": f"({x}, {y})",
                        "x": x,
                        "y": y,
                        "trust_score_percent": trust_score * 100,
                        "total_votes": x + y,
                        "hypotenuse": hypotenuse,
                        "cost_usdc": cost_info["total_cost"] / self.usdc_multiplier,
                        "cost_formatted": self.format_usdc(cost_info["total_cost"]),
                    }
                )

        return sorted(
            suggestions,
            key=lambda s: abs(s["trust_score_percent"] - target_trust_percent),
        )[:5]

    def check_balance(self, address: str) -> Dict:
        """Check ETH and USDC balances"""
        eth_balance = self.w3.eth.get_balance(address)
        usdc_balance = self.usdc.functions.balanceOf(address).call()

        return {
            "address": address,
            "eth_balance": eth_balance / 10**18,
            "eth_formatted": f"{eth_balance / 10**18:.6f} ETH",
            "usdc_balance": usdc_balance / self.usdc_multiplier,
            "usdc_formatted": self.format_usdc(usdc_balance),
        }

    def check_allowance(self, owner_address: str) -> Dict:
        """Check USDC allowance for PMM contract"""
        allowance = self.usdc.functions.allowance(owner_address, PMM_ADDRESS).call()

        return {
            "allowance": allowance,
            "allowance_usdc": allowance / self.usdc_multiplier,
            "allowance_formatted": self.format_usdc(allowance),
        }

    def check_contract_owner(self) -> Dict:
        """Check who is the contract owner and if current account is owner"""
        try:
            owner_address = self.pmm.functions.owner().call()

            is_owner = False
            if self.account:
                is_owner = owner_address.lower() == self.account.address.lower()

            return {
                "owner": owner_address,
                "current_account": self.account.address if self.account else None,
                "is_owner": is_owner,
            }
        except:
            return {
                "owner": "Unknown (function not available)",
                "current_account": self.account.address if self.account else None,
                "is_owner": False,
            }

    def approve_usdc(self, amount_usdc: float) -> str:
        """Approve PMM to spend USDC"""
        if not self.account:
            raise ValueError("Private key required for transactions")

        amount = int(amount_usdc * self.usdc_multiplier)

        tx = self.usdc.functions.approve(PMM_ADDRESS, amount).build_transaction(
            {
                "from": self.account.address,
                "nonce": self.w3.eth.get_transaction_count(self.account.address),
                "gas": 100000,
                "gasPrice": self.w3.eth.gas_price,
                "chainId": CHAIN_ID,
            }
        )

        signed_tx = self.account.sign_transaction(tx)
        tx_hash = self.w3.eth.send_raw_transaction(signed_tx.raw_transaction)

        print(f"Approval transaction sent: {tx_hash.hex()}")
        receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash)

        if receipt["status"] == 0:
            raise Exception("Approval transaction failed")

        print(f"Approval confirmed in block {receipt['blockNumber']}")

        return tx_hash.hex()

    def create_market(self, platform_id: int, initial_x: int, initial_y: int) -> str:
        """Create a new market (uses default 2.5% slippage protection)

        Args:
            platform_id: Platform identifier
            initial_x: Initial distrust votes
            initial_y: Initial trust votes

        Returns:
            Transaction hash
        """
        return self.create_market_with_slippage(
            platform_id, initial_x, initial_y, self.default_slippage_basis_points
        )

    def create_market_with_slippage(
        self,
        platform_id: int,
        initial_x: int,
        initial_y: int,
        slippage_basis_points: int = None,
    ) -> str:
        """Create a new market with custom slippage tolerance

        Args:
            platform_id: Platform identifier
            initial_x: Initial distrust votes
            initial_y: Initial trust votes
            slippage_basis_points: Max acceptable slippage (None = use default)

        Returns:
            Transaction hash
        """
        if not self.account:
            raise ValueError("Private key required for transactions")

        if slippage_basis_points is None:
            slippage_basis_points = self.default_slippage_basis_points

        validation = self.validate_coordinate(initial_x, initial_y)
        if "error" in validation:
            raise ValueError(f"Invalid coordinates: {validation['error']}")

        if self.pmm.functions.marketExistsFor(platform_id).call():
            raise ValueError(f"Market already exists for platform {platform_id}")

        hypotenuse = math.sqrt(initial_x * initial_x + initial_y * initial_y)
        cost_info = self.calculate_cost(int(hypotenuse), buying=True)

        print(f"\nCreating market for platform {platform_id}")
        print(f"Position: ({initial_x}, {initial_y})")
        print(f"Trust score: {validation['trust_score_percent']:.1f}%")
        print(f"Hypotenuse: {hypotenuse:.2f}")
        print(f"Cost: {self.format_usdc(cost_info['total_cost'])}")

        allowance_info = self.check_allowance(self.account.address)
        if allowance_info["allowance"] < cost_info["total_cost"]:
            raise ValueError(
                f"Insufficient allowance. Have {allowance_info['allowance_formatted']}, need {self.format_usdc(cost_info['total_cost'])}"
            )

        balance_info = self.check_balance(self.account.address)
        if (
            balance_info["usdc_balance"] * self.usdc_multiplier
            < cost_info["total_cost"]
        ):
            raise ValueError(
                f"Insufficient USDC. Have {balance_info['usdc_formatted']}, need {self.format_usdc(cost_info['total_cost'])}"
            )

        tx = self.pmm.functions.createMarketWithSlippage(
            platform_id, initial_x, initial_y, slippage_basis_points
        ).build_transaction(
            {
                "from": self.account.address,
                "nonce": self.w3.eth.get_transaction_count(self.account.address),
                "gas": 500000,
                "gasPrice": self.w3.eth.gas_price,
                "chainId": CHAIN_ID,
            }
        )

        signed_tx = self.account.sign_transaction(tx)
        tx_hash = self.w3.eth.send_raw_transaction(signed_tx.raw_transaction)

        print(f"Transaction sent: {tx_hash.hex()}")
        receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60)

        if receipt["status"] == 0:
            try:
                self.pmm.functions.createMarketWithSlippage(
                    platform_id, initial_x, initial_y, slippage_basis_points
                ).call({"from": self.account.address})
            except Exception as e:
                raise Exception(f"Transaction reverted: {str(e)}")
            raise Exception("Transaction failed with unknown reason")

        print(f"Market created in block {receipt['blockNumber']}")

        if not self.pmm.functions.marketExistsFor(platform_id).call():
            raise Exception("Market creation succeeded but market doesn't exist")

        return tx_hash.hex()

    def vote_on_market(self, platform_id: int, new_x: int, new_y: int) -> str:
        """Vote on an existing market (uses default 2.5% slippage protection)

        Args:
            platform_id: Platform identifier
            new_x: New distrust votes
            new_y: New trust votes

        Returns:
            Transaction hash
        """
        return self.vote_on_market_with_slippage(
            platform_id, new_x, new_y, self.default_slippage_basis_points
        )

    def vote_on_market_with_slippage(
        self,
        platform_id: int,
        new_x: int,
        new_y: int,
        slippage_basis_points: int = None,
    ) -> str:
        """Vote on an existing market with custom slippage tolerance

        Args:
            platform_id: Platform identifier
            new_x: New distrust votes
            new_y: New trust votes
            slippage_basis_points: Max acceptable slippage (None = use default)

        Returns:
            Transaction hash
        """
        if not self.account:
            raise ValueError("Private key required for transactions")

        if slippage_basis_points is None:
            slippage_basis_points = self.default_slippage_basis_points

        current_state = self.check_market(platform_id)
        if not current_state["exists"]:
            raise ValueError(f"Market does not exist for platform {platform_id}")

        validation = self.validate_coordinate(new_x, new_y)
        if "error" in validation:
            raise ValueError(f"Invalid coordinates: {validation['error']}")

        cost_info = self.calculate_hypotenuse_cost(
            current_state["x"], current_state["y"], new_x, new_y
        )

        print(f"\nVoting on platform {platform_id}")
        print(
            f"Position: ({current_state['x']}, {current_state['y']}) → ({new_x}, {new_y})"
        )
        print(
            f"Trust: {current_state['trust_score_percent']:.1f}% → {validation['trust_score_percent']:.1f}%"
        )

        if cost_info["action"] == "sell":
            voter_pos = self.check_voter_position(platform_id, self.account.address)
            if voter_pos["exists"]:
                trust_delta = new_y - current_state["y"]
                distrust_delta = new_x - current_state["x"]

                if trust_delta < 0 and voter_pos["trust_votes"] < -trust_delta:
                    raise ValueError(
                        f"Insufficient trust votes. Have {voter_pos['trust_votes']}, need {-trust_delta}"
                    )
                if distrust_delta < 0 and voter_pos["distrust_votes"] < -distrust_delta:
                    raise ValueError(
                        f"Insufficient distrust votes. Have {voter_pos['distrust_votes']}, need {-distrust_delta}"
                    )
            else:
                raise ValueError("No position to sell from")

        if cost_info["action"] == "buy":
            print(f"Cost: {cost_info['total_cost_formatted']}")
        elif cost_info["action"] == "sell":
            print(f"Refund: {cost_info['net_refund_formatted']}")
        else:
            print("Rebalancing (no cost)")

        if cost_info["action"] == "buy":
            allowance_info = self.check_allowance(self.account.address)
            if allowance_info["allowance"] < cost_info["total_cost"]:
                raise ValueError("Insufficient allowance for vote")

            balance_info = self.check_balance(self.account.address)
            if (
                balance_info["usdc_balance"] * self.usdc_multiplier
                < cost_info["total_cost"]
            ):
                raise ValueError("Insufficient USDC for vote")

        tx = self.pmm.functions.voteOnMarketWithSlippage(
            platform_id, new_x, new_y, slippage_basis_points
        ).build_transaction(
            {
                "from": self.account.address,
                "nonce": self.w3.eth.get_transaction_count(self.account.address),
                "gas": 500000,
                "gasPrice": self.w3.eth.gas_price,
                "chainId": CHAIN_ID,
            }
        )

        signed_tx = self.account.sign_transaction(tx)
        tx_hash = self.w3.eth.send_raw_transaction(signed_tx.raw_transaction)

        print(f"Transaction sent: {tx_hash.hex()}")
        receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60)

        if receipt["status"] == 0:
            raise Exception("Vote transaction failed")

        print(f"Vote completed in block {receipt['blockNumber']}")

        return tx_hash.hex()

    def get_usdc_info(self) -> Dict:
        """Get information about USDC on Base mainnet

        Returns:
            Dictionary with USDC information and how to acquire it
        """
        balance = 0
        if self.account:
            balance_raw = self.usdc.functions.balanceOf(self.account.address).call()
            balance = balance_raw / self.usdc_multiplier

        return {
            "network": "Base Mainnet",
            "usdc_address": USDC_ADDRESS,
            "usdc_explorer": f"https://basescan.org/token/{USDC_ADDRESS}",
            "decimals": self.usdc_decimals,
            "your_balance": (
                f"{balance:,.2f} USDC" if self.account else "N/A (no account)"
            ),
            "how_to_get_usdc": {
                "option_1": {
                    "method": "Bridge from Ethereum",
                    "url": "https://app.across.to",
                    "time": "~2 minutes",
                    "note": "Fast and reliable",
                },
                "option_2": {
                    "method": "Coinbase Withdrawal",
                    "steps": [
                        "1. Buy USDC on Coinbase",
                        "2. Select 'Send'",
                        "3. Choose 'Base' network",
                        "4. Send to your wallet",
                    ],
                    "time": "Instant if you have Coinbase account",
                },
                "option_3": {
                    "method": "DEX Swap",
                    "url": "https://app.uniswap.org",
                    "steps": [
                        "1. Connect wallet",
                        "2. Select Base network",
                        "3. Swap ETH → USDC",
                    ],
                },
                "option_4": {
                    "method": "Other Bridges",
                    "options": [
                        "Stargate: https://stargate.finance",
                        "Official Base Bridge: https://bridge.base.org",
                    ],
                },
            },
            "important_note": "⚠️ This is REAL USDC on mainnet - cannot be minted like testnet!",
        }

    def check_accumulated_fees(self) -> Dict:
        """Check accumulated protocol fees"""
        fees = self.pmm.functions.accumulatedProtocolFees().call()
        contract_balance = self.usdc.functions.balanceOf(PMM_ADDRESS).call()

        owner_recipient, protocol_recipient, pending_fees = (
            self.pmm.functions.getFeeDistributionInfo().call()
        )
        owner_share, protocol_share = (
            self.pmm.functions.calculateFeeDistribution().call()
        )

        return {
            "accumulated_fees": fees,
            "accumulated_fees_usdc": fees / self.usdc_multiplier,
            "accumulated_fees_formatted": self.format_usdc(fees),
            "contract_balance": contract_balance,
            "contract_balance_formatted": self.format_usdc(contract_balance),
            "owner_recipient": owner_recipient,
            "protocol_recipient": protocol_recipient,
            "owner_share": owner_share,
            "owner_share_formatted": self.format_usdc(owner_share),
            "protocol_share": protocol_share,
            "protocol_share_formatted": self.format_usdc(protocol_share),
        }

    def distribute_protocol_fees(self, amount_usdc: float = None) -> str:
        """Distribute protocol fees 50/50 (owner only)

        Args:
            amount_usdc: Amount in USDC to distribute (None = distribute all)

        Returns:
            Transaction hash
        """
        if not self.account:
            raise ValueError("Private key required for transactions")

        fee_info = self.check_accumulated_fees()

        if amount_usdc is None:
            amount_wei = fee_info["accumulated_fees"]
            print("\n💰 Distributing all protocol fees")
            print(f"Total fees: {fee_info['accumulated_fees_formatted']}")
            print(
                f"Owner share: {fee_info['owner_share_formatted']} → {fee_info['owner_recipient'][:10]}..."
            )
            print(
                f"Protocol share: {fee_info['protocol_share_formatted']} → {fee_info['protocol_recipient'][:10]}..."
            )

            tx_function = self.pmm.functions.distributeProtocolFees()
        else:
            amount_wei = int(amount_usdc * self.usdc_multiplier)

            if amount_wei > fee_info["accumulated_fees"]:
                raise ValueError(
                    f"Amount exceeds accumulated fees. "
                    f"Requested: {self.format_usdc(amount_wei)}, "
                    f"Available: {fee_info['accumulated_fees_formatted']}"
                )

            owner_share = amount_wei // 2
            protocol_share = amount_wei - owner_share

            print(f"\n💰 Distributing {self.format_usdc(amount_wei)} protocol fees")
            print(
                f"Owner share: {self.format_usdc(owner_share)} → {fee_info['owner_recipient'][:10]}..."
            )
            print(
                f"Protocol share: {self.format_usdc(protocol_share)} → {fee_info['protocol_recipient'][:10]}..."
            )

            tx_function = self.pmm.functions.distributeProtocolFees(amount_wei)

        tx_dict = {
            "from": self.account.address,
            "nonce": self.w3.eth.get_transaction_count(self.account.address),
            "gas": 200000,
            "gasPrice": self.w3.eth.gas_price,
            "chainId": CHAIN_ID,
        }

        tx = tx_function.build_transaction(tx_dict)

        signed_tx = self.account.sign_transaction(tx)
        tx_hash = self.w3.eth.send_raw_transaction(signed_tx.raw_transaction)

        print(f"   Transaction sent: {tx_hash.hex()}")
        print("   Waiting for confirmation...")

        receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash)

        if receipt["status"] == 0:
            owner_info = self.check_contract_owner()
            if not owner_info["is_owner"]:
                raise Exception(
                    f"Fee distribution failed - only owner can call this function. "
                    f"Contract owner: {owner_info['owner']}, "
                    f"Your address: {self.account.address}"
                )
            else:
                try:
                    if amount_usdc is None:
                        self.pmm.functions.distributeProtocolFees().call(
                            {"from": self.account.address}
                        )
                    else:
                        self.pmm.functions.distributeProtocolFees(amount_wei).call(
                            {"from": self.account.address}
                        )
                except Exception as e:
                    raise Exception(f"Fee distribution failed: {str(e)}")
                raise Exception("Fee distribution transaction failed")

        print("   Fees distributed successfully!")
        print(f"   Gas used: {receipt['gasUsed']:,}")
        return tx_hash.hex()

    def withdraw_to_owner(self, amount_usdc: float) -> str:
        """Withdraw fees to owner recipient only (owner only)

        Args:
            amount_usdc: Amount in USDC to withdraw

        Returns:
            Transaction hash
        """
        if not self.account:
            raise ValueError("Private key required for transactions")

        amount_wei = int(amount_usdc * self.usdc_multiplier)

        fee_info = self.check_accumulated_fees()

        if amount_wei > fee_info["accumulated_fees"]:
            raise ValueError(
                f"Amount exceeds accumulated fees. "
                f"Requested: {self.format_usdc(amount_wei)}, "
                f"Available: {fee_info['accumulated_fees_formatted']}"
            )

        print(f"\n💰 Withdrawing {self.format_usdc(amount_wei)} to owner")
        print(f"Recipient: {fee_info['owner_recipient']}")

        tx_function = self.pmm.functions.withdrawToOwner(amount_wei)

        tx_dict = {
            "from": self.account.address,
            "nonce": self.w3.eth.get_transaction_count(self.account.address),
            "gas": 150000,
            "gasPrice": self.w3.eth.gas_price,
            "chainId": CHAIN_ID,
        }

        tx = tx_function.build_transaction(tx_dict)

        signed_tx = self.account.sign_transaction(tx)
        tx_hash = self.w3.eth.send_raw_transaction(signed_tx.raw_transaction)

        print(f"✅ Transaction sent: {tx_hash.hex()}")

        receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash)

        if receipt["status"] == 0:
            raise Exception("Withdraw transaction failed")

        return tx_hash.hex()

    def update_fee_recipients(
        self, owner_recipient: str, protocol_recipient: str
    ) -> str:
        """Update fee recipient addresses (owner only)"""
        if not self.account:
            raise ValueError("Private key required for transactions")

        print("\n🔄 Updating fee recipients")
        print(f"New owner recipient: {owner_recipient}")
        print(f"New protocol recipient: {protocol_recipient}")

        tx_function = self.pmm.functions.updateFeeRecipients(
            self.w3.to_checksum_address(owner_recipient),
            self.w3.to_checksum_address(protocol_recipient),
        )

        tx_dict = {
            "from": self.account.address,
            "nonce": self.w3.eth.get_transaction_count(self.account.address),
            "gas": 100000,
            "gasPrice": self.w3.eth.gas_price,
            "chainId": CHAIN_ID,
        }

        tx = tx_function.build_transaction(tx_dict)

        signed_tx = self.account.sign_transaction(tx)
        tx_hash = self.w3.eth.send_raw_transaction(signed_tx.raw_transaction)

        print(f"Transaction sent: {tx_hash.hex()}")

        receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash)

        if receipt["status"] == 0:
            raise Exception("Update fee recipients transaction failed")

        print("✅ Recipients updated successfully!")
        return tx_hash.hex()

    def get_contract_health(self) -> Dict:
        """Get overall contract health metrics"""
        total_balance = self.usdc.functions.balanceOf(PMM_ADDRESS).call()
        accumulated_fees = 0

        if hasattr(self.pmm.functions, "accumulatedProtocolFees"):
            accumulated_fees = self.pmm.functions.accumulatedProtocolFees().call()

        available_liquidity = total_balance - accumulated_fees

        return {
            "total_balance": total_balance,
            "total_balance_formatted": self.format_usdc(total_balance),
            "accumulated_fees": accumulated_fees,
            "accumulated_fees_formatted": self.format_usdc(accumulated_fees),
            "available_liquidity": available_liquidity,
            "available_liquidity_formatted": self.format_usdc(available_liquidity),
            "health_status": "healthy" if available_liquidity > 0 else "warning",
        }

    def get_slippage_info(self) -> Dict:
        """Get slippage protection information"""
        try:
            slippage_basis_points, slippage_percentage = (
                self.pmm.functions.getDefaultSlippage().call()
            )
            return {
                "default_slippage_basis_points": slippage_basis_points,
                "default_slippage_percentage": slippage_percentage,
                "slippage_formatted": f"{slippage_percentage}%",
            }
        except:
            return {
                "default_slippage_basis_points": self.default_slippage_basis_points,
                "default_slippage_percentage": self.default_slippage_basis_points / 100,
                "slippage_formatted": f"{self.default_slippage_basis_points / 100}%",
            }

    def calculate_payment_with_slippage(
        self,
        current_x: int,
        current_y: int,
        new_x: int,
        new_y: int,
        slippage_basis_points: int = None,
    ) -> Dict:
        """Calculate expected payment with slippage protection"""
        if slippage_basis_points is None:
            slippage_basis_points = self.default_slippage_basis_points

        try:
            expected_payment, max_payment = (
                self.pmm.functions.calculatePaymentWithSlippage(
                    current_x, current_y, new_x, new_y, slippage_basis_points
                ).call()
            )

            return {
                "expected_payment": expected_payment,
                "expected_payment_formatted": self.format_usdc(expected_payment),
                "max_payment_with_slippage": max_payment,
                "max_payment_formatted": self.format_usdc(max_payment),
                "slippage_amount": max_payment - expected_payment,
                "slippage_amount_formatted": self.format_usdc(
                    max_payment - expected_payment
                ),
            }
        except:
            cost_info = self.calculate_hypotenuse_cost(
                current_x, current_y, new_x, new_y
            )
            if cost_info["action"] == "buy":
                expected = int(cost_info["total_cost"])
                max_payment = (
                    expected
                    + (expected * slippage_basis_points)
                    // self.basis_points_denominator
                )
                return {
                    "expected_payment": expected,
                    "expected_payment_formatted": self.format_usdc(expected),
                    "max_payment_with_slippage": max_payment,
                    "max_payment_formatted": self.format_usdc(max_payment),
                    "slippage_amount": max_payment - expected,
                    "slippage_amount_formatted": self.format_usdc(
                        max_payment - expected
                    ),
                }
            return {"error": "Not a buy transaction"}

    def calculate_refund_with_slippage(
        self,
        current_x: int,
        current_y: int,
        new_x: int,
        new_y: int,
        slippage_basis_points: int = None,
    ) -> Dict:
        """Calculate expected refund with slippage protection"""
        if slippage_basis_points is None:
            slippage_basis_points = self.default_slippage_basis_points

        try:
            expected_refund, min_refund = (
                self.pmm.functions.calculateRefundWithSlippage(
                    current_x, current_y, new_x, new_y, slippage_basis_points
                ).call()
            )

            return {
                "expected_refund": expected_refund,
                "expected_refund_formatted": self.format_usdc(expected_refund),
                "min_refund_with_slippage": min_refund,
                "min_refund_formatted": self.format_usdc(min_refund),
                "slippage_amount": expected_refund - min_refund,
                "slippage_amount_formatted": self.format_usdc(
                    expected_refund - min_refund
                ),
            }
        except:
            cost_info = self.calculate_hypotenuse_cost(
                current_x, current_y, new_x, new_y
            )
            if cost_info["action"] == "sell":
                expected = int(cost_info["net_refund"])
                min_refund = (
                    expected
                    - (expected * slippage_basis_points)
                    // self.basis_points_denominator
                )
                return {
                    "expected_refund": expected,
                    "expected_refund_formatted": self.format_usdc(expected),
                    "min_refund_with_slippage": min_refund,
                    "min_refund_formatted": self.format_usdc(min_refund),
                    "slippage_amount": expected - min_refund,
                    "slippage_amount_formatted": self.format_usdc(
                        expected - min_refund
                    ),
                }
            return {"error": "Not a sell transaction"}
