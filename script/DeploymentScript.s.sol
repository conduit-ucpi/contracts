// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {DeployEscrow} from "./DeployEscrow.s.sol";
import {DeployCompletionEscrow} from "./DeployCompletionEscrow.s.sol";

/**
 * Combined deployment: the LEGACY escrow pair (via [deployEscrow]) and then, in the
 * same broadcast, the COMPLETION (fan-out) pair (via [deployCompletion]).
 *
 * CI deploys ONLY the legacy pair, through DeployEscrow. Use this script when you
 * deliberately want both; run DeployEscrow or DeployCompletionEscrow for one.
 *
 * Env: the union of DeployEscrow's and DeployCompletionEscrow's.
 */
contract DeploymentScript is DeployEscrow, DeployCompletionEscrow {
    function run() external override(DeployEscrow, DeployCompletionEscrow) {
        uint256 deployerPrivateKey = vm.envUint("RELAYER_WALLET_PRIVATE_KEY");
        address relayerAddress = vm.addr(deployerPrivateKey);
        (address defaultArbiter, address feeRecipient, address feeSplitSigner, bytes20 gitCommit) =
            _readEscrowConfig(relayerAddress);

        vm.startBroadcast(deployerPrivateKey);
        deployEscrow(relayerAddress, defaultArbiter, feeRecipient, feeSplitSigner, gitCommit);
        deployCompletion(relayerAddress, feeRecipient);
        vm.stopBroadcast();

        console.log("Deployment completed successfully!");
    }
}
