// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {RektdToken} from "../src/RektdToken.sol";

contract RektdTokenTest is Test {
    RektdToken token;
    address deployer = address(0xFAC7);

    function setUp() public {
        vm.prank(deployer);
        token = new RektdToken();
    }

    function test_metadata() public view {
        assertEq(token.name(), "REKTD");
        assertEq(token.symbol(), "REKTD");
        assertEq(token.decimals(), 18);
    }

    function test_mintsTheWholeSupplyToTheDeployer() public view {
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(deployer), 1e27);
        assertEq(token.TOTAL_SUPPLY(), 1e27);
    }

    function test_transferMovesExactlyTheAmount() public {
        address alice = address(0xA11CE);
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 1_000e18));
        assertEq(token.balanceOf(alice), 1_000e18);
        assertEq(token.balanceOf(deployer), 1e27 - 1_000e18);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_transferFromRespectsAllowance() public {
        address alice = address(0xA11CE);
        address spender = address(0x5BE4D);
        vm.prank(deployer);
        token.approve(spender, 5e18);
        vm.prank(spender);
        token.transferFrom(deployer, alice, 5e18);
        assertEq(token.balanceOf(alice), 5e18);
        vm.prank(spender);
        vm.expectRevert();
        token.transferFrom(deployer, alice, 1);
    }

    function test_transferMoreThanBalanceReverts() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        token.transfer(deployer, 1);
    }

    function test_hasNoMintPath() public {
        bytes memory data = abi.encodeWithSignature("mint(address,uint256)", deployer, 1);
        vm.prank(deployer);
        (bool ok,) = address(token).call(data);
        assertFalse(ok);
        assertEq(token.totalSupply(), 1e27);
    }
}
