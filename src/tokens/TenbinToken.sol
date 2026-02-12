// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title TENBINIUM Token
 * @author clwsqc and rtedwardchen
 * @notice Native ERC20 token used by Pythagorean Market Maker as payment and reward token
 * @dev 6 decimals for precise financial calculations. Supports role-based minting and burning.
 * 
 * Tokenomics:
 * - Initial supply: 0 TENBIN (minted over time by PMM rewards)
 * - Max total supply: 21,000,000 TENBIN (hard cap)
 * - PMM reward emission target: 1,000,000 TENBIN/year over 21 years (capped by MAX_SUPPLY)
 * 
 * Key Features:
 * - Separate minter and burner roles (independent from owner)
 * - PMM contract should be set as minter to enable staking reward claims
 */
contract TenbinToken is ERC20, Ownable {
    uint8 private constant DECIMALS = 6;
    uint256 public constant MAX_SUPPLY = 21_000_000 * 10**DECIMALS;
    
    address public minter;
    address public burner;
    
    event MinterUpdated(address indexed previousMinter, address indexed newMinter);
    event BurnerUpdated(address indexed previousBurner, address indexed newBurner);
    
    error InvalidAddress();
    error NotMinter();
    error NotBurner();
    error ExceedsMaxSupply();

    constructor(address initialOwner) ERC20("TENBINIUM", "TBN") Ownable(initialOwner) {
        // Initialize roles to owner
        minter = initialOwner;
        burner = initialOwner;
    }
    
    modifier onlyMinter() {
        if (msg.sender != minter) revert NotMinter();
        _;
    }
    
    modifier onlyBurner() {
        if (msg.sender != burner) revert NotBurner();
        _;
    }
    
    /**
     * @notice Update the minter address (typically set to PMM contract)
     * @dev Only callable by owner. Reverts if newMinter is zero address.
     * @param newMinter New address authorized to mint tokens
     */
    function setMinter(address newMinter) external onlyOwner {
        if (newMinter == address(0)) revert InvalidAddress();
        address old = minter;
        minter = newMinter;
        emit MinterUpdated(old, newMinter);
    }
    
    /**
     * @notice Update the burner address
     * @dev Only callable by owner. Reverts if newBurner is zero address.
     * @param newBurner New address authorized to burn tokens
     */
    function setBurner(address newBurner) external onlyOwner {
        if (newBurner == address(0)) revert InvalidAddress();
        address old = burner;
        burner = newBurner;
        emit BurnerUpdated(old, newBurner);
    }

    /**
     * @dev Mint tokens to any address (minter only)
     * @param to Address to mint tokens to
     * @param amount Amount of tokens to mint (with 6 decimals)
     * @notice Reverts if minting would exceed MAX_SUPPLY (21M TENBIN)
     */
    function mint(address to, uint256 amount) external onlyMinter {
        if (totalSupply() + amount > MAX_SUPPLY) revert ExceedsMaxSupply();
        _mint(to, amount);
    }
    
    /**
     * @notice Burn tokens from a specific address (burner only)
     * @dev WARNING: Burner can burn from ANY address without approval.
     *      Only assign trusted addresses as burner.
     * @param from Address to burn tokens from
     * @param amount Amount to burn (with 6 decimals)
     */
    function burn(address from, uint256 amount) external onlyBurner {
        _burn(from, amount);
    }

    /**
     * @dev Returns the number of decimals (6)
     */
    function decimals() public pure override returns (uint8) {
        return DECIMALS;
    }
    
    /**
     * @notice Returns the remaining amount that can be minted before hitting MAX_SUPPLY
     * @return Remaining mintable amount in raw units (with 6 decimals)
     */
    function remainingMintableSupply() external view returns (uint256) {
        uint256 current = totalSupply();
        if (current >= MAX_SUPPLY) return 0;
        return MAX_SUPPLY - current;
    }
}

