// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {CompletionEscrowContractFactory} from "../src/CompletionEscrowContractFactory.sol";
import {CompletionEscrowContract} from "../src/CompletionEscrowContract.sol";

/**
 * Deploys the COMPLETION (fan-out) escrow pair: the implementation and the
 * recipient-split factory that clones it. This is the sibling of the LEGACY
 * single-recipient EscrowContract pair — the two factories are independent and
 * both can live on the same chain.
 *
 * The deployment itself lives in the internal [deployCompletion] helper, which
 * manages NO broadcast or env of its own, so it can be called two ways:
 *   - standalone via [run] below (deploy ONLY the completion pair), or
 *   - from DeploymentScript, inside that script's broadcast, so one run
 *     deploys the legacy and completion pairs together.
 *
 * The relayer/owner passed in becomes the factory OWNER (and each escrow's
 * GAS_PAYER); only the OWNER may call createChildEscrowContract, so fee-exempt
 * child nodes can only be created by the platform relayer.
 */
contract DeployCompletionEscrow is Script {
    /**
     * Deploys the completion implementation + factory. Assumes the caller has
     * already opened a broadcast. Logs the env vars fanOutChainService needs.
     */
    function deployCompletion(address owner, address feeRecipient)
        internal
        returns (CompletionEscrowContractFactory factory, CompletionEscrowContract implementation)
    {
        implementation = new CompletionEscrowContract();
        console.log("Completion implementation deployed at:", address(implementation));

        factory = new CompletionEscrowContractFactory(owner, address(implementation), feeRecipient);

        console.log("=================================================");
        console.log("Completion factory deployed at:", address(factory));
        console.log("Factory owner:", factory.OWNER());
        console.log("Fee recipient:", factory.FEE_RECIPIENT());
        console.log("Set these env vars on fanOutChainService:");
        console.log("  FANOUT_CONTRACT_FACTORY_ADDRESS =", address(factory));
        console.log("  FANOUT_ESCROW_IMPLEMENTATION_ADDRESS =", address(implementation));
        console.log("=================================================");
    }

    /**
     * Standalone entry point: deploy ONLY the completion pair.
     *
     * Env (same names as DeploymentScript):
     *   RELAYER_WALLET_PRIVATE_KEY  deployer; becomes factory OWNER
     *   CHAIN_ID                    must match the connected chain
     *   NETWORK                     label only (e.g. base, base-sepolia)
     *   FEE_RECIPIENT_ADDRESS       optional; defaults to OWNER when unset
     */
    function run() external virtual {
        uint256 deployerPrivateKey = vm.envUint("RELAYER_WALLET_PRIVATE_KEY");
        address relayerAddress = vm.addr(deployerPrivateKey);
        uint256 chainId = vm.envUint("CHAIN_ID");
        string memory network = vm.envString("NETWORK");
        address feeRecipient = _readFeeRecipient();

        console.log("Deploying COMPLETION (fan-out) escrow only:");
        console.log("Network:", network);
        console.log("Chain ID:", chainId);
        console.log("Relayer Address (Owner):", relayerAddress);
        require(block.chainid == chainId, "Chain ID mismatch");

        vm.startBroadcast(deployerPrivateKey);
        deployCompletion(relayerAddress, feeRecipient);
        vm.stopBroadcast();

        console.log("Completion deployment completed successfully!");
    }

    /** Reads the optional FEE_RECIPIENT_ADDRESS, defaulting to address(0) (= owner). */
    function _readFeeRecipient() internal view returns (address feeRecipient) {
        try vm.envAddress("FEE_RECIPIENT_ADDRESS") returns (address _feeRecipient) {
            feeRecipient = _feeRecipient;
            console.log("Using custom fee recipient:", feeRecipient);
        } catch {
            feeRecipient = address(0);
            console.log("No FEE_RECIPIENT_ADDRESS set, will default to owner");
        }
    }
}
