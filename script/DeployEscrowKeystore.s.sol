// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console} from "forge-std/Script.sol";
import {DeployEscrow} from "./DeployEscrow.s.sol";

/**
 * Keystore variant of DeployEscrow. Identical deployment, but the signer comes from
 * the CLI `--account <name>` keystore rather than a raw private key in the env. Run it
 * through script/deploy-escrow-keystore.sh, which also sets GIT_COMMIT from a clean tree.
 *
 * Env: as DeployEscrow, except RELAYER_ADDRESS (which MUST equal the --account keystore
 * address, and becomes the factory OWNER) replaces RELAYER_WALLET_PRIVATE_KEY.
 */
contract DeployEscrowKeystore is DeployEscrow {
    function run() external override {
        address relayerAddress = vm.envAddress("RELAYER_ADDRESS");
        (address defaultArbiter, address feeRecipient, address feeSplitSigner, bytes20 gitCommit) =
            _readEscrowConfig(relayerAddress);

        vm.startBroadcast();
        deployEscrow(relayerAddress, defaultArbiter, feeRecipient, feeSplitSigner, gitCommit);
        vm.stopBroadcast();

        console.log("Escrow deployment completed successfully!");
    }
}
