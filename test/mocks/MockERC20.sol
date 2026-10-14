// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Plain ERC-20 for tests: mints `supply` to the deployer and exposes a free `mint`.
contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 supply) ERC20(name_, symbol_) {
        if (supply > 0) _mint(msg.sender, supply);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
