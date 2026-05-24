// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title Tenbinium
 * @notice Protocol reward token for proof-of-proximity solvers.
 */
contract Tenbinium is ERC20, ERC20Burnable, Ownable {
    uint256 public constant MAX_SUPPLY = 21_000_000 ether;

    address public minter;
    bool public minterFrozen;

    error InvalidMinter();
    error UnauthorizedMinter();
    error CapExceeded();
    error MinterFrozen();

    event MinterUpdated(address indexed minter);
    event MinterFrozenPermanently(address indexed minter);

    constructor(address initialOwner) ERC20("Tenbinium", "TBN") Ownable(initialOwner) {}

    function setMinter(address newMinter) external onlyOwner {
        if (minterFrozen) revert MinterFrozen();
        if (newMinter == address(0)) revert InvalidMinter();
        minter = newMinter;
        emit MinterUpdated(newMinter);
    }

    function freezeMinter() external onlyOwner {
        if (minter == address(0)) revert InvalidMinter();
        minterFrozen = true;
        emit MinterFrozenPermanently(minter);
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != minter) revert UnauthorizedMinter();
        if (totalSupply() + amount > MAX_SUPPLY) revert CapExceeded();
        _mint(to, amount);
    }
}
