// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {SeatStream} from "../src/SeatStream.sol";

contract DeployTest is Test {
    // One test on purpose: env vars are process-global and forge runs tests in parallel.
    function test_deploy_rules() public {
        vm.setEnv("SEATSTREAM_PAYEE", vm.toString(makeAddr("payee")));
        vm.setEnv("SEATSTREAM_KEEPER", vm.toString(makeAddr("keeper")));
        vm.setEnv("SEATSTREAM_PRICE_WEI", "50000000000000000");

        vm.chainId(8453);
        vm.setEnv("SEATSTREAM_CHAIN_ID", "1");
        Deploy d = new Deploy();
        vm.expectRevert(bytes("SEATSTREAM_CHAIN_ID must equal the RPC chain id"));
        d.deploy();
        vm.setEnv("SEATSTREAM_CHAIN_ID", "8453");
        SeatStream s = new Deploy().deploy();
        assertEq(s.price(), 0.05 ether);
        assertEq(s.payee(), makeAddr("payee"));
        assertEq(s.keeper(), makeAddr("keeper"));
        vm.chainId(1);
        vm.setEnv("SEATSTREAM_CHAIN_ID", "1");
        assertEq(new Deploy().deploy().price(), 0.05 ether);
        vm.setEnv("SEATSTREAM_CHAIN_ID", "8453");

        vm.setEnv("SEATSTREAM_PRICE_WEI", "500000000000000");
        d = new Deploy();
        vm.chainId(8453);
        vm.expectRevert(bytes("mainnet price is fixed at 0.05 ether"));
        d.deploy();
        vm.chainId(84532);
        assertEq(new Deploy().deploy().price(), 0.0005 ether);
        vm.chainId(11155111);
        assertEq(new Deploy().deploy().price(), 0.0005 ether);

        vm.chainId(10);
        d = new Deploy();
        vm.expectRevert(bytes("unsupported chain"));
        d.deploy();

        vm.chainId(8453);
        vm.setEnv("SEATSTREAM_PRICE_WEI", "50000000000000000");
        vm.setEnv("SEATSTREAM_PAYEE", vm.toString(address(this))); // has code
        d = new Deploy();
        vm.expectRevert(bytes("payee must be a plain wallet"));
        d.deploy();

        vm.setEnv("SEATSTREAM_PAYEE", vm.toString(makeAddr("same")));
        vm.setEnv("SEATSTREAM_KEEPER", vm.toString(makeAddr("same")));
        d = new Deploy();
        vm.expectRevert(bytes("payee and keeper must differ"));
        d.deploy();
    }
}
