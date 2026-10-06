// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MockIdentity721} from "../testnet/MockIdentity721.sol";

contract MockIdentity721Test is Test {
    function test_mint_owner_transfer() public {
        vm.chainId(84532);
        MockIdentity721 m = new MockIdentity721();
        address a = makeAddr("a");
        address b = makeAddr("b");
        vm.expectRevert(MockIdentity721.BadId.selector);
        m.ownerOf(7);
        vm.prank(a);
        m.mint(7);
        assertEq(m.ownerOf(7), a);
        vm.prank(b);
        vm.expectRevert(MockIdentity721.Taken.selector);
        m.mint(7);
        vm.prank(a);
        vm.expectRevert(MockIdentity721.BadId.selector);
        m.mint(2000);
        vm.prank(b);
        vm.expectRevert(MockIdentity721.NotOwner.selector);
        m.transferFrom(a, b, 7);
        vm.prank(a);
        m.transferFrom(a, b, 7);
        assertEq(m.ownerOf(7), b);
    }

    function test_refuses_mainnets() public {
        vm.chainId(8453);
        vm.expectRevert(bytes("testnet only"));
        new MockIdentity721();
        vm.chainId(1);
        vm.expectRevert(bytes("testnet only"));
        new MockIdentity721();
    }
}
