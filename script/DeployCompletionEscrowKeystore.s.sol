// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console} from "forge-std/Script.sol";
import {DeployCompletionEscrow} from "./DeployCompletionEscrow.s.sol";

/**
 * Keystore variant of DeployCompletionEscrow. Identical deployment, but the
 * signer comes from the CLI `--account <name>` keystore rather than a raw
 * private key in the env. Use this locally with `cast wallet import`-style
 * keystores; the base DeployCompletionEscrow keeps the RELAYER_WALLET_PRIVATE_KEY
 * env path for CI, which cannot do interactive password entry.
 *
 * Env:
 *   RELAYER_ADDRESS   deployer address; MUST equal the --account keystore
 *                     address, and becomes the factory OWNER
 *   CHAIN_ID          must match the connected chain
 *   NETWORK           label only (e.g. base, base-sepolia)
 *   FEE_RECIPIENT_ADDRESS  optional; defaults to OWNER when unset
 *
 * Because the signer is supplied by `--account`, we open an unkeyed broadcast
 * (`vm.startBroadcast()`), which uses the CLI-provided sender.
 */
contract DeployCompletionEscrowKeystore is DeployCompletionEscrow {
    function run() external override {
        address relayerAddress = vm.envAddress("RELAYER_ADDRESS");
        uint256 chainId = vm.envUint("CHAIN_ID");
        string memory network = vm.envString("NETWORK");
        address feeRecipient = _readFeeRecipient();

        console.log("Deploying COMPLETION (fan-out) escrow only (keystore):");
        console.log("Network:", network);
        console.log("Chain ID:", chainId);
        console.log("Relayer Address (Owner):", relayerAddress);
        require(block.chainid == chainId, "Chain ID mismatch");

        vm.startBroadcast();
        deployCompletion(relayerAddress, feeRecipient);
        vm.stopBroadcast();

        console.log("Completion deployment completed successfully!");
    }
}
