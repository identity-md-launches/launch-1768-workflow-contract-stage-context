// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

/// @notice Shared assertions about who may own a launched contract: never the launch factory that
/// deploys it, never the launch wallet that is `tx.origin` while it is deployed, never nobody.
abstract contract OwnerChecks is Test {
    /// @dev Stands in for IMD's launch wallet as `tx.origin` when a contract is deployed.
    address internal constant ORIGIN_PROBE = 0x0000000000000000000000000000000000000716;

    /// @dev If `target` exposes `owner()`, it must be a real owner: not the factory, not the origin
    /// probe and not the zero address. A contract with no `owner()` has nothing to check here.
    function checkOwner(string memory name, address target, address factory) internal view {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature("owner()"));
        if (!ok || ret.length < 32) return;
        address owner = abi.decode(ret, (address));
        assertTrue(
            owner != factory, string.concat(name, " is owned by the launch factory (msg.sender in its constructor)")
        );
        assertTrue(owner != ORIGIN_PROBE, string.concat(name, " is owned by the launch wallet (tx.origin)"));
        assertTrue(owner != address(0), string.concat(name, " has no owner"));
    }
}
