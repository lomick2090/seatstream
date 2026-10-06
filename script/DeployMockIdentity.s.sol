// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {MockIdentity721} from "../testnet/MockIdentity721.sol";

/// forge script script/DeployMockIdentity.s.sol --rpc-url base_sepolia --broadcast --verify --account <name>
contract DeployMockIdentity is Script {
    function run() external {
        vm.startBroadcast();
        MockIdentity721 m = new MockIdentity721();
        vm.stopBroadcast();
        console2.log("MockIdentity721", address(m));
        console2.log("chainid", block.chainid);
    }
}
