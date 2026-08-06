// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {EscrowContractFactory} from "../src/EscrowContractFactory.sol";
import {EscrowContract} from "../src/EscrowContract.sol";
import {DeployCompletionEscrow} from "./DeployCompletionEscrow.s.sol";

/**
 * Main deployment: deploys the LEGACY escrow pair and then, in the same
 * broadcast, the COMPLETION (fan-out) pair via the inherited
 * [deployCompletion] helper. Run DeployCompletionEscrow directly instead if you
 * only need the completion pair.
 */
contract DeploymentScript is DeployCompletionEscrow {
    function run() external override {
        uint256 deployerPrivateKey = vm.envUint("RELAYER_WALLET_PRIVATE_KEY");
        address relayerAddress = vm.addr(deployerPrivateKey);
        uint256 chainId = vm.envUint("CHAIN_ID");
        string memory network = vm.envString("NETWORK");

        // Try to read FEE_RECIPIENT_ADDRESS, default to address(0) if not set
        address feeRecipient = _readFeeRecipient();

        // ⚠️ DEFAULT_ARBITER — THE ONE PARAMETER THAT CAN NEVER BE CHANGED.
        //
        // It is baked into the implementation's bytecode, so rotating it means deploying a
        // NEW implementation, which changes the ERC-1167 codehash and therefore requires a
        // new factory AND a new marketplace. There is deliberately NO default and no
        // fallback: vm.envAddress reverts if the variable is unset, which is exactly what we
        // want. Never substitute a placeholder here — the test suites use their own throwaway
        // address, so a hardcoded one would pass every test and still poison a real deploy.
        address defaultArbiter = vm.envAddress("DEFAULT_ARBITER_ADDRESS");
        require(defaultArbiter != address(0), "DEFAULT_ARBITER_ADDRESS must not be zero");

        // It MUST be a multisig (spec §3.3A1a/§13.8): it is the fallback adjudicator for
        // every contested dispute platform-wide, and its address is unchangeable. Requiring
        // deployed code is a cheap guard against pasting an EOA or a typo'd address - a Safe
        // always has code, an EOA never does.
        require(defaultArbiter.code.length > 0, "DEFAULT_ARBITER_ADDRESS has no code - must be a deployed Safe");

        // It must also be distinct from the deployer/owner: one key that both operates the
        // platform and arbitrates disputes is a total-compromise target (§3.3E).
        require(defaultArbiter != relayerAddress, "DEFAULT_ARBITER_ADDRESS must differ from the relayer/owner");

        console.log("Deploying with the following parameters:");
        console.log("Network:", network);
        console.log("Chain ID:", chainId);
        console.log("Relayer Address (Owner):", relayerAddress);
        console.log("Deployer Address:", vm.addr(deployerPrivateKey));
        console.log("Default arbiter (Safe):", defaultArbiter);

        // Verify we're on the expected chain
        require(block.chainid == chainId, "Chain ID mismatch");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy implementation as separate transaction
        EscrowContract implementation = new EscrowContract(defaultArbiter);
        console.log("Implementation deployed at:", address(implementation));
        
        // Deploy factory with implementation address
        // feeRecipient uses environment variable or defaults to owner if not set
        EscrowContractFactory factory = new EscrowContractFactory(
            relayerAddress,
            address(implementation),
            feeRecipient
        );
        
        console.log("=================================================");
        console.log("Legacy factory deployed at:", address(factory));
        console.log("=================================================");

        // Deploy the completion (fan-out) pair in the same broadcast.
        deployCompletion(relayerAddress, feeRecipient);

        vm.stopBroadcast();
        
        console.log("Deployment completed successfully!");
        console.log("Factory contract address:", address(factory));
        console.log("Implementation contract address:", factory.IMPLEMENTATION());
        console.log("Factory owner:", factory.OWNER());
        
        console.log("=================================================");
        console.log("CLONE DEPLOYMENT SUCCESSFUL!");
        console.log("Each escrow will be cloned from implementation:");
        console.log("Implementation:", factory.IMPLEMENTATION());
        console.log("Gas per escrow: ~188k (vs ~856k before cloning)");
        console.log("=================================================");

        // Read the value back OFF THE DEPLOYED CONTRACT rather than echoing the input, so
        // the log proves what was actually baked into the bytecode.
        console.log("Default arbiter deployed as:", implementation.DEFAULT_ARBITER());
        console.log("Nomination window (seconds):", implementation.NOMINATION_WINDOW());
        console.log("=================================================");
        console.log("MARKETPLACE PRECONDITION (spec 3.4):");
        console.log("  Deploy MarketplaceEscrow with TRUSTED_IMPLEMENTATION =", address(implementation));
        console.log("  Marketplace inventory accrues only from escrows created AFTER this factory.");
        console.log("=================================================");
    }
}