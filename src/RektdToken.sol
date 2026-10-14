// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title REKTD launch token
/// @notice Plain fixed-supply ERC-20. The whole supply (1,000,000,000 tokens, 18 decimals) is minted
/// once to the deployer, which on the launch is the IMD launch factory. There is no owner, no mint,
/// no pause, no blocklist, no transfer fee and no upgrade path: every fee of the project lives in the
/// RektJackpotHook, never in the token.
contract RektdToken is ERC20 {
    /// @notice Total supply in minor units: 10^27 (one billion tokens at 18 decimals).
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;

    constructor() ERC20("REKTD", "REKTD") {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
