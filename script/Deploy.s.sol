// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {SeatStream} from "../src/SeatStream.sol";

/// forge script script/Deploy.s.sol --rpc-url <base|ethereum|base_sepolia|sepolia> --broadcast --verify --account <cast-wallet-name>
/// Env: SEATSTREAM_PAYEE (cold wallet), SEATSTREAM_KEEPER (hot keeper address),
///      SEATSTREAM_PRICE_WEI (testnets only; mainnets are fixed at 0.05 ether),
///      SEATSTREAM_CHAIN_ID (required on Base and Ethereum: 8453 or 1, must match the RPC).
contract Deploy is Script {
    uint256 internal constant MAINNET_PRICE = 0.05 ether;

    function deploy() public returns (SeatStream s) {
        address payee = vm.envAddress("SEATSTREAM_PAYEE");
        address keeper = vm.envAddress("SEATSTREAM_KEEPER");
        require(payee != keeper, "payee and keeper must differ");
        require(payee.code.length == 0, "payee must be a plain wallet");
        uint256 price = vm.envOr("SEATSTREAM_PRICE_WEI", MAINNET_PRICE);
        uint256 id = block.chainid;
        if (id == 8453 || id == 1) {
            // Roles are immutable: make the operator name the chain, so a wrong --rpc-url alias cannot deploy.
            require(
                vm.envOr("SEATSTREAM_CHAIN_ID", uint256(0)) == id, "SEATSTREAM_CHAIN_ID must equal the RPC chain id"
            );
            require(price == MAINNET_PRICE, "mainnet price is fixed at 0.05 ether");
        } else {
            require(id == 84532 || id == 11155111 || id == 31337, "unsupported chain");
        }
        s = new SeatStream(price, payee, keeper);
    }

    function run() external {
        vm.startBroadcast();
        SeatStream s = deploy();
        vm.stopBroadcast();
        console2.log("SeatStream", address(s));
        console2.log("chainid", block.chainid);
        console2.log("payee", s.payee());
        console2.log("keeper", s.keeper());
        console2.log("price", s.price());
    }
}
