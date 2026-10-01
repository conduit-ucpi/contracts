// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {EscrowContractFactory} from "../src/EscrowContractFactory.sol";
import {EscrowContract} from "../src/EscrowContract.sol";

/**
 * Deploys the LEGACY escrow pair ONLY: EscrowContract (implementation) and
 * EscrowContractFactory. The completion pair and the marketplace are untouched.
 *
 * As with DeployCompletionEscrow, the deployment lives in an internal helper
 * ([deployEscrow]) that opens no broadcast and reads no env, so DeploymentScript
 * can still deploy everything in one run.
 *
 * Env:
 *   RELAYER_WALLET_PRIVATE_KEY  deployer; becomes factory OWNER
 *   CHAIN_ID                    must match the connected chain
 *   NETWORK                     label only (e.g. base, base-sepolia)
 *   DEFAULT_ARBITER_ADDRESS     REQUIRED; fallback-arbitrator Safe, baked into bytecode
 *   GIT_COMMIT                  REQUIRED; 0x-prefixed 40-hex commit being deployed
 *   FEE_RECIPIENT_ADDRESS       optional; defaults to OWNER when unset
 *   FEE_SPLIT_SIGNER_ADDRESS    optional; defaults to OWNER when unset (see below)
 */
contract DeployEscrow is Script {
    /**
     * Deploys the escrow implementation + factory. Assumes the caller has already opened
     * a broadcast. Logs the values READ BACK from the deployed contracts, so the log proves
     * what was baked in rather than echoing the inputs.
     */
    function deployEscrow(
        address owner,
        address defaultArbiter,
        address feeRecipient,
        address feeSplitSigner,
        bytes20 gitCommit
    ) internal returns (EscrowContractFactory factory, EscrowContract implementation) {
        implementation = new EscrowContract(defaultArbiter, gitCommit);
        console.log("Implementation deployed at:", address(implementation));

        factory = new EscrowContractFactory(owner, address(implementation), feeRecipient, feeSplitSigner, gitCommit);

        console.log("=================================================");
        console.log("Legacy factory deployed at:", address(factory));
        console.log("=================================================");
        console.log("Factory owner:", factory.OWNER());
        console.log("Fee recipient:", factory.FEE_RECIPIENT());
        console.log("Fee split signer:", factory.FEE_SPLIT_SIGNER());
        console.log("Factory git commit:");
        console.logBytes20(factory.GIT_COMMIT());
        console.log("Implementation git commit:");
        console.logBytes20(implementation.GIT_COMMIT());
        console.log("Default arbiter deployed as:", implementation.DEFAULT_ARBITER());
        console.log("Nomination window (seconds):", implementation.NOMINATION_WINDOW());
        console.log("=================================================");
        console.log("MARKETPLACE PRECONDITION (spec 3.4):");
        console.log(
            "  Deploy the marketplace (OfferVault + OfferVaultFactory) with TRUSTED_IMPLEMENTATION =",
            address(implementation)
        );
        console.log("  Marketplace inventory accrues only from escrows created AFTER this factory.");
        console.log("=================================================");
    }

    function run() external virtual {
        uint256 deployerPrivateKey = vm.envUint("RELAYER_WALLET_PRIVATE_KEY");
        address relayerAddress = vm.addr(deployerPrivateKey);
        (address defaultArbiter, address feeRecipient, address feeSplitSigner, bytes20 gitCommit) =
            _readEscrowConfig(relayerAddress);

        vm.startBroadcast(deployerPrivateKey);
        deployEscrow(relayerAddress, defaultArbiter, feeRecipient, feeSplitSigner, gitCommit);
        vm.stopBroadcast();

        console.log("Escrow deployment completed successfully!");
    }

    /**
     * Every env read and pre-flight check for the escrow pair, shared by the private-key,
     * keystore and combined entry points so none of them can skip a guard.
     */
    function _readEscrowConfig(address relayerAddress)
        internal
        view
        returns (address defaultArbiter, address feeRecipient, address feeSplitSigner, bytes20 gitCommit)
    {
        uint256 chainId = vm.envUint("CHAIN_ID");
        string memory network = vm.envString("NETWORK");
        console.log("Deploying LEGACY escrow pair:");
        console.log("Network:", network);
        console.log("Chain ID:", chainId);
        console.log("Relayer Address (Owner):", relayerAddress);
        require(block.chainid == chainId, "Chain ID mismatch");

        // ⚠️ DEFAULT_ARBITER — THE ONE PARAMETER THAT CAN NEVER BE CHANGED.
        //
        // It is baked into the implementation's bytecode, so rotating it means deploying a
        // NEW implementation, which changes the ERC-1167 codehash and therefore requires a
        // new factory AND a new marketplace. There is deliberately NO default and no
        // fallback: vm.envAddress reverts if the variable is unset, which is exactly what we
        // want. Never substitute a placeholder here — the test suites use their own throwaway
        // address, so a hardcoded one would pass every test and still poison a real deploy.
        defaultArbiter = vm.envAddress("DEFAULT_ARBITER_ADDRESS");
        require(defaultArbiter != address(0), "DEFAULT_ARBITER_ADDRESS must not be zero");

        // It MUST be a multisig (spec §3.3A1a/§13.8): it is the fallback adjudicator for
        // every contested dispute platform-wide, and its address is unchangeable. Requiring
        // deployed code is a cheap guard against pasting an EOA or a typo'd address - a Safe
        // always has code, an EOA never does.
        require(defaultArbiter.code.length > 0, "DEFAULT_ARBITER_ADDRESS has no code - must be a deployed Safe");

        // It must also be distinct from the deployer/owner: one key that both operates the
        // platform and arbitrates disputes is a total-compromise target (§3.3E).
        require(defaultArbiter != relayerAddress, "DEFAULT_ARBITER_ADDRESS must differ from the relayer/owner");
        console.log("Default arbiter (Safe):", defaultArbiter);

        // GIT_COMMIT has no default either. A contract cannot carry its own commit as a
        // source constant, so this is the only place the value can come from - and a
        // deploy that cannot say what it deployed is the thing this exists to prevent.
        bytes memory commit = vm.envBytes("GIT_COMMIT");
        require(commit.length == 20, "GIT_COMMIT must be a 0x-prefixed 40-hex-char commit SHA");
        gitCommit = bytes20(commit);
        require(gitCommit != bytes20(0), "GIT_COMMIT must not be zero");

        feeRecipient = _envAddressOr("FEE_RECIPIENT_ADDRESS", address(0));

        // Optional, defaulting to OWNER - but OWNER is this relayer's hot key, and the signer
        // is immutable: every signature it issues stays valid for the factory's lifetime.
        feeSplitSigner = _envAddressOr("FEE_SPLIT_SIGNER_ADDRESS", address(0));
        if (feeSplitSigner == address(0)) {
            console.log("WARNING: FEE_SPLIT_SIGNER_ADDRESS unset - partner splits will be signed by the relayer key");
        }
    }

    function _envAddressOr(string memory name, address fallbackValue) internal view returns (address) {
        try vm.envAddress(name) returns (address value) {
            console.log(string.concat("Using ", name, ":"), value);
            return value;
        } catch {
            console.log(string.concat("No ", name, " set, will default to owner"));
            return fallbackValue;
        }
    }
}
