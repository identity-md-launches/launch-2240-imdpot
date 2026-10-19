// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IMDPotToken} from "../src/IMDPotToken.sol";

/// @notice Reviewable deployment for local or test networks. On the IMD launch the factory deploys
/// the token from its creation code instead; this script is not used for that and holds no keys.
contract DeployIMDPot is Script {
    /// @notice Deploys the token; the caller of this function becomes the holder of the whole supply.
    function deploy() public returns (IMDPotToken token) {
        token = new IMDPotToken();
    }

    function run() external returns (IMDPotToken token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
