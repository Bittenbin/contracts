#!/usr/bin/env python3
"""
Pythagorean Market Maker (PMM) Cookbook - Base Mainnet Version
Complete guide for interacting with PMM on Base Mainnet

⚠️  WARNING: This is for BASE MAINNET with REAL TENBIN!
⚠️  All transactions use real money. Be careful!

Contract Addresses:
# TODO: Update these addresses once contracts are deployed on Base Mainnet
- PythagoreanMarketMaker: TODO
- TENBIN Token: TODO
- Owner Fee Recipient: 0x2dfc776B09234f617DFc38Cb8De1BB2B0B7C4E5B
- Protocol Fee Recipient: 0xb322A547De3308C2426aEa700c8176574E57eEe6

Requirements:
pip install web3==7.12.0 eth-account python-dotenv

Usage Examples:
  # Check if market exists (no private key needed)
  python pmm_cookbook_mainnet.py check-market 1234567890
  
  # Get TENBIN information
  python pmm_cookbook_mainnet.py get-token-info
  
  # Check contract health
  python pmm_cookbook_mainnet.py health

For transactions, import and use the PMM_Cookbook class with your private key.
"""

import math
from typing import List, Tuple, Optional, Dict, Any
from web3 import Web3
from eth_account import Account
import secrets
from dotenv import load_dotenv

load_dotenv()

BASE_MAINNET_RPC = (
    "https://mainnet.base.org"  # You can also use your own RPC like Alchemy
)
CHAIN_ID = 8453

# Base Mainnet Deployed Addresses (November 26, 2025)
PMM_ADDRESS = "0x92AcC35FE215a065146F93132cF27D5C3E39D826"
TENBIN_ADDRESS = "0x420331D6396B7290B57Ac4633983FC9a95F9913C"

PMM_ABI = [
    # Market Creation
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
    # Market Application Workflow
    {
        "inputs": [{"name": "platformId", "type": "uint256"}],
        "name": "applyForMarket",
        "outputs": [],
        "type": "function",
    },
    {
        "inputs": [{"name": "platformId", "type": "uint256"}],
        "name": "approveMarket",
        "outputs": [],
        "type": "function",
    },
    {
        "inputs": [{"name": "platformId", "type": "uint256"}],
        "name": "denyMarket",
        "outputs": [],
        "type": "function",
    },
    {
        "inputs": [{"name": "", "type": "uint256"}],
        "name": "marketApplications",
        "outputs": [
            {"name": "applicant", "type": "address"},
            {"name": "timestamp", "type": "uint256"},
        ],
        "type": "function",
    },
    # Voting
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
    # Yield
    {
        "inputs": [{"name": "platformId", "type": "uint256"}],
        "name": "claimYield",
        "outputs": [],
        "type": "function",
    },
    {
        "inputs": [],
        "name": "currentAnnualYieldWad",
        "outputs": [{"name": "", "type": "uint256"}],
        "type": "function",
    },
    {
        "inputs": [
            {"name": "", "type": "uint256"},
            {"name": "", "type": "address"},
        ],
        "name": "holdings",
        "outputs": [
            {"name": "trustCost", "type": "uint256"},
            {"name": "distrustCost", "type": "uint256"},
            {"name": "lastAccrual", "type": "uint256"},
            {"name": "unclaimedYield", "type": "uint256"},
        ],
        "type": "function",
    },
    # Market State
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
    # Constants
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
        "name": "MINIMUM_VOTES",
        "outputs": [{"name": "", "type": "uint256"}],
        "type": "function",
    },
    {
        "inputs": [],
        "name": "MAX_COORDINATE_VALUE",
        "outputs": [{"name": "", "type": "uint256"}],
        "type": "function",
    },
    {
        "inputs": [],
        "name": "MAX_HYPOTENUSE",
        "outputs": [{"name": "", "type": "uint256"}],
        "type": "function",
    },
    {
        "inputs": [],
        "name": "totalMarkets",
        "outputs": [{"name": "", "type": "uint256"}],
        "type": "function",
    },
    # Slippage helpers
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
    # Mappings
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
        "name": "totalVoteVolume",
        "outputs": [{"name": "", "type": "uint256"}],
        "type": "function",
    },
    {
        "inputs": [{"name": "", "type": "uint256"}],
        "name": "highestMilestoneReached",
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
    # Fee management
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
        "inputs": [{"name": "amount", "type": "uint256"}],
        "name": "withdrawToProtocol",
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
    # Contract state
    {
        "inputs": [],
        "name": "getContractBalance",
        "outputs": [{"name": "balance", "type": "uint256"}],
        "type": "function",
    },
    {
        "inputs": [],
        "name": "getAvailableLiquidity",
        "outputs": [{"name": "liquidity", "type": "uint256"}],
        "type": "function",
    },
]

TENBIN_ABI = [
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
        "inputs": [],
        "name": "name",
        "outputs": [{"name": "", "type": "string"}],
        "type": "function",
    },
    {
        "inputs": [],
        "name": "symbol",
        "outputs": [{"name": "", "type": "string"}],
        "type": "function",
    },
    {
        "inputs": [],
        "name": "totalSupply",
        "outputs": [{"name": "", "type": "uint256"}],
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
        "inputs": [],
        "name": "minter",
        "outputs": [{"name": "", "type": "address"}],
        "type": "function",
    },
    {
        "inputs": [],
        "name": "burner",
        "outputs": [{"name": "", "type": "address"}],
        "type": "function",
    },
    # ERC20 transfer
    {
        "inputs": [
            {"name": "to", "type": "address"},
            {"name": "amount", "type": "uint256"},
        ],
        "name": "transfer",
        "outputs": [{"name": "", "type": "bool"}],
        "type": "function",
    },
    # Minting - minter can mint tokens
    {
        "inputs": [
            {"name": "to", "type": "address"},
            {"name": "amount", "type": "uint256"},
        ],
        "name": "mint",
        "outputs": [],
        "type": "function",
    },
    # Set minter role
    {
        "inputs": [{"name": "newMinter", "type": "address"}],
        "name": "setMinter",
        "outputs": [],
        "type": "function",
    },
]


def create_wallet() -> Dict[str, str]:
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


class CoordinateHelper:
    """Helper class for coordinate operations.
    
    Note: Unlike the name "Pythagorean" suggests, the contract now accepts
    ANY positive coordinates within bounds. This helper provides utilities
    for working with the coordinate system.
    """

    MAX_COORDINATE = 1_000_000_000  # 1 billion
    MAX_HYPOTENUSE = 1_500_000_000  # 1.5 billion

    @staticmethod
    def is_valid_coordinate(x: int, y: int) -> bool:
        """Check if (x, y) is a valid coordinate for PMM.
        
        Valid if:
        - x > 0 and y > 0
        - Both within MAX_COORDINATE_VALUE
        - Hypotenuse within MAX_HYPOTENUSE
        """
        if x <= 0 or y <= 0:
            return False
        if x > CoordinateHelper.MAX_COORDINATE or y > CoordinateHelper.MAX_COORDINATE:
            return False
        hypotenuse_squared = x * x + y * y
        max_hyp_squared = CoordinateHelper.MAX_HYPOTENUSE ** 2
        return hypotenuse_squared <= max_hyp_squared

    @staticmethod
    def calculate_trust_score(x: int, y: int) -> float:
        """Calculate trust score as a decimal (0 to 1)."""
        if x == 0 and y == 0:
            return 0.0
        return (y * y) / (x * x + y * y)

    @staticmethod
    def calculate_hypotenuse(x: int, y: int) -> float:
        """Calculate hypotenuse (cost basis) for coordinates."""
        return math.sqrt(x * x + y * y)

    @staticmethod
    def generate_pythagorean_triples(max_votes: int = 50) -> List[Tuple[int, int, int]]:
        """Generate common Pythagorean triples for reference.
        
        Note: These are just commonly used coordinates with integer hypotenuse.
        The contract accepts any valid coordinates.
        """
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
    """Main cookbook class for PMM interactions on Base Mainnet."""

    def __init__(self, private_key: Optional[str] = None):
        """Initialize the cookbook.

        Args:
            private_key: Private key for transactions (optional for read-only)
        """
        self.w3 = Web3(Web3.HTTPProvider(BASE_MAINNET_RPC))

        # Check if addresses are configured
        if PMM_ADDRESS == "0x0000000000000000000000000000000000000000":
            print("⚠️  WARNING: PMM contract address not configured!")
            print("   Update PMM_ADDRESS after deployment.")

        # Initialize contracts
        self.pmm = self.w3.eth.contract(address=PMM_ADDRESS, abi=PMM_ABI)
        self.tenbin = self.w3.eth.contract(address=TENBIN_ADDRESS, abi=TENBIN_ABI)

        self.account = None
        if private_key:
            self.account = Account.from_key(private_key)

        self.helper = CoordinateHelper()

        # Try to get token decimals
        try:
            self.token_decimals = self.tenbin.functions.decimals().call()
        except:
            self.token_decimals = 6  # Default for TENBIN

        self.token_multiplier = 10 ** self.token_decimals

        # Try to get contract constants
        try:
            self.protocol_fee_basis_points = (
                self.pmm.functions.PROTOCOL_FEE_BASIS_POINTS().call()
            )
            self.minimum_votes = self.pmm.functions.MINIMUM_VOTES().call()
            self.default_slippage_basis_points = (
                self.pmm.functions.DEFAULT_SLIPPAGE_BASIS_POINTS().call()
            )
        except:
            # Defaults if contract not deployed
            self.protocol_fee_basis_points = 100  # 1%
            self.minimum_votes = 7
            self.default_slippage_basis_points = 250  # 2.5%

        self.basis_points_denominator = 10000

    def format_token(self, amount: int) -> str:
        """Format token amount for display."""
        return f"{amount / self.token_multiplier:,.6f} TENBIN"

    def calculate_hypotenuse_cost(
        self, current_x: int, current_y: int, new_x: int, new_y: int
    ) -> Dict[str, Any]:
        """Calculate the cost/refund for a vote transaction using hypotenuse formula."""
        current_hypotenuse = math.sqrt(current_x * current_x + current_y * current_y)
        new_hypotenuse = math.sqrt(new_x * new_x + new_y * new_y)
        hypotenuse_change = new_hypotenuse - current_hypotenuse

        if hypotenuse_change > 0:
            payment = hypotenuse_change * self.token_multiplier
            protocol_fee = (
                payment * self.protocol_fee_basis_points
            ) / self.basis_points_denominator
            total_cost = payment + protocol_fee

            return {
                "action": "buy",
                "hypotenuse_change": hypotenuse_change,
                "payment": payment,
                "protocol_fee": protocol_fee,
                "total_cost": total_cost,
                "total_cost_formatted": self.format_token(int(total_cost)),
            }
        elif hypotenuse_change < 0:
            refund = -hypotenuse_change * self.token_multiplier
            protocol_fee = (
                refund * self.protocol_fee_basis_points
            ) / self.basis_points_denominator
            net_refund = refund - protocol_fee

            return {
                "action": "sell",
                "hypotenuse_change": hypotenuse_change,
                "refund": refund,
                "protocol_fee": protocol_fee,
                "net_refund": net_refund,
                "net_refund_formatted": self.format_token(int(net_refund)),
            }
        else:
            return {
                "action": "rebalance",
                "hypotenuse_change": 0,
                "cost": 0,
                "cost_formatted": "0.000000 TENBIN",
            }

    # ==================== Read Functions ====================

    def check_market(self, platform_id: int) -> Dict:
        """Check if a market exists and get its state."""
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
        """Check a voter's position in a market."""
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

    def check_holdings(self, platform_id: int, user_address: str) -> Dict:
        """Check user's holdings and unclaimed yield for a market."""
        trust_cost, distrust_cost, last_accrual, unclaimed_yield = (
            self.pmm.functions.holdings(platform_id, user_address).call()
        )

        return {
            "platform_id": platform_id,
            "user": user_address,
            "trust_cost": trust_cost,
            "trust_cost_formatted": self.format_token(trust_cost),
            "distrust_cost": distrust_cost,
            "distrust_cost_formatted": self.format_token(distrust_cost),
            "total_cost_basis": trust_cost + distrust_cost,
            "total_cost_basis_formatted": self.format_token(trust_cost + distrust_cost),
            "last_accrual": last_accrual,
            "unclaimed_yield": unclaimed_yield,
            "unclaimed_yield_formatted": self.format_token(unclaimed_yield),
        }

    def check_application(self, platform_id: int) -> Dict:
        """Check if there's a pending application for a market."""
        applicant, timestamp = self.pmm.functions.marketApplications(platform_id).call()

        if applicant == "0x0000000000000000000000000000000000000000":
            return {"exists": False, "platform_id": platform_id}

        return {
            "exists": True,
            "platform_id": platform_id,
            "applicant": applicant,
            "timestamp": timestamp,
        }

    def get_current_yield_rate(self) -> Dict:
        """Get the current annual yield rate."""
        try:
            rate_wad = self.pmm.functions.currentAnnualYieldWad().call()
            total_markets = self.pmm.functions.totalMarkets().call()

            return {
                "rate_wad": rate_wad,
                "rate_decimal": rate_wad / 10**18,
                "rate_percent": (rate_wad / 10**18) * 100,
                "total_markets": total_markets,
            }
        except Exception as e:
            return {"error": str(e)}

    def validate_coordinate(self, x: int, y: int) -> Dict:
        """Validate if coordinates are valid."""
        is_valid_local = self.helper.is_valid_coordinate(x, y)

        try:
            is_valid_chain = self.pmm.functions.isValidCoordinate(x, y).call()
        except:
            is_valid_chain = is_valid_local

        result = {
            "x": x,
            "y": y,
            "valid": is_valid_chain,
            "total_votes": x + y,
            "trust_score": self.helper.calculate_trust_score(x, y),
            "trust_score_percent": self.helper.calculate_trust_score(x, y) * 100,
            "hypotenuse": self.helper.calculate_hypotenuse(x, y),
        }

        if x <= 0 or y <= 0:
            result["error"] = "Coordinates must be positive"
        elif x + y < self.minimum_votes:
            result["error"] = f"Below minimum {self.minimum_votes} votes"
        elif x == y:
            result["error"] = "Cannot use genesis line (x = y) for creation"
        elif not is_valid_chain:
            result["error"] = "Invalid coordinate (exceeds bounds)"

        return result

    def check_balance(self, address: str) -> Dict:
        """Check ETH and TENBIN balances."""
        eth_balance = self.w3.eth.get_balance(address)

        try:
            token_balance = self.tenbin.functions.balanceOf(address).call()
        except:
            token_balance = 0

        return {
            "address": address,
            "eth_balance": eth_balance / 10**18,
            "eth_formatted": f"{eth_balance / 10**18:.6f} ETH",
            "token_balance": token_balance / self.token_multiplier,
            "token_formatted": self.format_token(token_balance),
        }

    def check_allowance(self, owner_address: str) -> Dict:
        """Check TENBIN allowance for PMM contract."""
        try:
            allowance = self.tenbin.functions.allowance(owner_address, PMM_ADDRESS).call()
        except:
            allowance = 0

        return {
            "allowance": allowance,
            "allowance_formatted": self.format_token(allowance),
        }

    def check_contract_owner(self) -> Dict:
        """Check who is the contract owner and if current account is owner."""
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
                "owner": "Unknown (contract not deployed)",
                "current_account": self.account.address if self.account else None,
                "is_owner": False,
            }

    def check_accumulated_fees(self) -> Dict:
        """Check accumulated protocol fees."""
        try:
            fees = self.pmm.functions.accumulatedProtocolFees().call()
            contract_balance = self.tenbin.functions.balanceOf(PMM_ADDRESS).call()

            owner_recipient, protocol_recipient, pending_fees = (
                self.pmm.functions.getFeeDistributionInfo().call()
            )
            owner_share, protocol_share = (
                self.pmm.functions.calculateFeeDistribution().call()
            )

            return {
                "accumulated_fees": fees,
                "accumulated_fees_formatted": self.format_token(fees),
                "contract_balance": contract_balance,
                "contract_balance_formatted": self.format_token(contract_balance),
                "owner_recipient": owner_recipient,
                "protocol_recipient": protocol_recipient,
                "owner_share": owner_share,
                "owner_share_formatted": self.format_token(owner_share),
                "protocol_share": protocol_share,
                "protocol_share_formatted": self.format_token(protocol_share),
            }
        except Exception as e:
            return {"error": str(e)}

    def get_contract_health(self) -> Dict:
        """Get overall contract health metrics."""
        try:
            total_balance = self.tenbin.functions.balanceOf(PMM_ADDRESS).call()
            accumulated_fees = self.pmm.functions.accumulatedProtocolFees().call()
            available_liquidity = total_balance - accumulated_fees
            total_markets = self.pmm.functions.totalMarkets().call()

            return {
                "total_balance": total_balance,
                "total_balance_formatted": self.format_token(total_balance),
                "accumulated_fees": accumulated_fees,
                "accumulated_fees_formatted": self.format_token(accumulated_fees),
                "available_liquidity": available_liquidity,
                "available_liquidity_formatted": self.format_token(available_liquidity),
                "total_markets": total_markets,
                "health_status": "healthy" if available_liquidity >= 0 else "warning",
            }
        except Exception as e:
            return {"error": str(e), "health_status": "unknown"}

    def get_token_info(self) -> Dict:
        """Get information about the TENBIN token."""
        try:
            name = self.tenbin.functions.name().call()
            symbol = self.tenbin.functions.symbol().call()
            decimals = self.tenbin.functions.decimals().call()
            total_supply = self.tenbin.functions.totalSupply().call()
            minter = self.tenbin.functions.minter().call()

            balance = 0
            if self.account:
                balance = self.tenbin.functions.balanceOf(self.account.address).call()

            return {
                "network": "Base Mainnet",
                "address": TENBIN_ADDRESS,
                "name": name,
                "symbol": symbol,
                "decimals": decimals,
                "total_supply": total_supply,
                "total_supply_formatted": self.format_token(total_supply),
                "minter": minter,
                "pmm_is_minter": minter.lower() == PMM_ADDRESS.lower(),
                "your_balance": self.format_token(balance) if self.account else "N/A",
            }
        except Exception as e:
            return {
                "network": "Base Mainnet",
                "address": TENBIN_ADDRESS,
                "error": str(e),
                "note": "Contract may not be deployed yet",
            }

    # ==================== Write Functions ====================

    def _build_and_send_tx(self, tx_function, gas: int = 500000) -> str:
        """Build and send a transaction."""
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

        print(f"Transaction sent: {tx_hash.hex()}")
        receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)

        if receipt["status"] == 0:
            raise Exception("Transaction failed")

        print(f"Confirmed in block {receipt['blockNumber']}")
        return tx_hash.hex()

    def approve_tenbin(self, amount: float) -> str:
        """Approve PMM to spend TENBIN."""
        amount_wei = int(amount * self.token_multiplier)

        print(f"\nApproving {self.format_token(amount_wei)} for PMM...")
        return self._build_and_send_tx(
            self.tenbin.functions.approve(PMM_ADDRESS, amount_wei),
            gas=100000
        )

    def apply_for_market(self, platform_id: int) -> str:
        """Apply to create a new market (costs 10 TENBIN)."""
        if not self.account:
            raise ValueError("Private key required for transactions")

        # Check if market already exists
        if self.pmm.functions.marketExistsFor(platform_id).call():
            raise ValueError(f"Market already exists for platform {platform_id}")

        # Check for existing application
        app = self.check_application(platform_id)
        if app.get("exists"):
            raise ValueError(f"Application already pending for platform {platform_id}")

        print(f"\nApplying for market {platform_id}")
        print("Application fee: 10 TENBIN")

        return self._build_and_send_tx(
            self.pmm.functions.applyForMarket(platform_id),
            gas=200000
        )

    def create_market(self, platform_id: int, initial_x: int, initial_y: int) -> str:
        """Create a new market (uses default slippage protection)."""
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
        """Create a new market with custom slippage tolerance."""
        if not self.account:
            raise ValueError("Private key required for transactions")

        if slippage_basis_points is None:
            slippage_basis_points = self.default_slippage_basis_points

        validation = self.validate_coordinate(initial_x, initial_y)
        if "error" in validation:
            raise ValueError(f"Invalid coordinates: {validation['error']}")

        if self.pmm.functions.marketExistsFor(platform_id).call():
            raise ValueError(f"Market already exists for platform {platform_id}")

        cost_info = self.calculate_hypotenuse_cost(0, 0, initial_x, initial_y)

        print(f"\nCreating market for platform {platform_id}")
        print(f"Position: ({initial_x}, {initial_y})")
        print(f"Trust score: {validation['trust_score_percent']:.1f}%")
        print(f"Cost: {cost_info['total_cost_formatted']}")

        return self._build_and_send_tx(
            self.pmm.functions.createMarketWithSlippage(
                platform_id, initial_x, initial_y, slippage_basis_points
            )
        )

    def vote_on_market(self, platform_id: int, new_x: int, new_y: int) -> str:
        """Vote on an existing market (uses default slippage protection)."""
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
        """Vote on an existing market with custom slippage tolerance."""
        if not self.account:
            raise ValueError("Private key required for transactions")

        if slippage_basis_points is None:
            slippage_basis_points = self.default_slippage_basis_points

        current_state = self.check_market(platform_id)
        if not current_state["exists"]:
            raise ValueError(f"Market does not exist for platform {platform_id}")

        validation = self.validate_coordinate(new_x, new_y)
        if "error" in validation and validation["error"] != "Cannot use genesis line (x = y) for creation":
            raise ValueError(f"Invalid coordinates: {validation['error']}")

        cost_info = self.calculate_hypotenuse_cost(
            current_state["x"], current_state["y"], new_x, new_y
        )

        print(f"\nVoting on platform {platform_id}")
        print(f"Position: ({current_state['x']}, {current_state['y']}) → ({new_x}, {new_y})")
        print(f"Trust: {current_state['trust_score_percent']:.1f}% → {validation['trust_score_percent']:.1f}%")

        if cost_info["action"] == "buy":
            print(f"Cost: {cost_info['total_cost_formatted']}")
        elif cost_info["action"] == "sell":
            print(f"Refund: {cost_info['net_refund_formatted']}")
        else:
            print("Rebalancing (no cost)")

        return self._build_and_send_tx(
            self.pmm.functions.voteOnMarketWithSlippage(
                platform_id, new_x, new_y, slippage_basis_points
            )
        )

    def claim_yield(self, platform_id: int) -> str:
        """Claim accrued yield for a market."""
        if not self.account:
            raise ValueError("Private key required for transactions")

        holdings = self.check_holdings(platform_id, self.account.address)
        print(f"\nClaiming yield for platform {platform_id}")
        print(f"Unclaimed yield: {holdings['unclaimed_yield_formatted']}")

        return self._build_and_send_tx(
            self.pmm.functions.claimYield(platform_id),
            gas=200000
        )

    def distribute_protocol_fees(self, amount: float = None) -> str:
        """Distribute protocol fees 50/50 (owner only)."""
        if not self.account:
            raise ValueError("Private key required for transactions")

        if amount is None:
            print("\n💰 Distributing all protocol fees")
            return self._build_and_send_tx(
                self.pmm.functions.distributeProtocolFees(0),
                gas=200000
            )
        else:
            amount_wei = int(amount * self.token_multiplier)
            print(f"\n💰 Distributing {self.format_token(amount_wei)} protocol fees")
            return self._build_and_send_tx(
                self.pmm.functions.distributeProtocolFees(amount_wei),
                gas=200000
            )


# ==================== CLI Interface ====================

def main():
    import sys

    if len(sys.argv) < 2:
        print("Usage: python pmm_cookbook_mainnet.py <command> [args]")
        print("\nAvailable commands:")
        print("  check-market <platform_id>     - Check market state")
        print("  get-token-info                 - Get TENBIN token info")
        print("  health                         - Check contract health")
        print("  yield-rate                     - Get current yield rate")
        print("  create-wallet                  - Generate new wallet")
        return

    command = sys.argv[1]
    cookbook = PMM_Cookbook()

    if command == "check-market":
        if len(sys.argv) < 3:
            print("Usage: python pmm_cookbook_mainnet.py check-market <platform_id>")
            return
        platform_id = int(sys.argv[2])
        result = cookbook.check_market(platform_id)
        print(f"\nMarket {platform_id}:")
        for key, value in result.items():
            print(f"  {key}: {value}")

    elif command == "get-token-info":
        result = cookbook.get_token_info()
        print("\nTENBIN Token Info:")
        for key, value in result.items():
            print(f"  {key}: {value}")

    elif command == "health":
        result = cookbook.get_contract_health()
        print("\nContract Health:")
        for key, value in result.items():
            print(f"  {key}: {value}")

    elif command == "yield-rate":
        result = cookbook.get_current_yield_rate()
        print("\nYield Rate:")
        for key, value in result.items():
            print(f"  {key}: {value}")

    elif command == "create-wallet":
        create_wallet()

    else:
        print(f"Unknown command: {command}")


if __name__ == "__main__":
    main()
