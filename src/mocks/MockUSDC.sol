// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockUSDC
 * @author rtedwardchen
 * @notice Mock USDC token for testing on Base testnet
 * @dev This contract should NOT be deployed to mainnet - testing purposes only
 */
contract MockUSDC is ERC20 {
    uint8 private constant DECIMALS = 6;
    
    constructor() ERC20("Mock USDC", "mUSDC") {}
    
    /**
     * @dev Mint tokens to any address (for testing only)
     * @param to Address to mint tokens to
     * @param amount Amount of tokens to mint (with 6 decimals)
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
    
    /**
     * @dev Returns the number of decimals (6 for USDC)
     */
    function decimals() public pure override returns (uint8) {
        return DECIMALS;
    }
    
    /**
     * @dev Convenience function to mint tokens with dollar amount
     * @param to Address to mint to
     * @param dollars Number of dollars (will be converted to 6 decimal format)
     */
    function mintDollars(address to, uint256 dollars) external {
        _mint(to, dollars * 10**DECIMALS);
    }
} 