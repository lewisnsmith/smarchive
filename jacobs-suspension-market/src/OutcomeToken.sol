// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice One side of a binary market. Freely transferable so it can be traded
///         anywhere an ERC-20 trades; only the owning market can change supply.
contract OutcomeToken is ERC20 {
    address public immutable market;
    uint8 private immutable _tokenDecimals;

    error OnlyMarket();

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        market = msg.sender;
        _tokenDecimals = decimals_;
    }

    modifier onlyMarket() {
        if (msg.sender != market) revert OnlyMarket();
        _;
    }

    /// @dev Matches the collateral token so 1 unit of collateral mints 1 whole share.
    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    function mint(address to, uint256 amount) external onlyMarket {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyMarket {
        _burn(from, amount);
    }
}
