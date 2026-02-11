// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {EscrowContractFactory} from "../src/EscrowContractFactory.sol";
import {EscrowContract} from "../src/EscrowContract.sol";

contract DeploymentScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("RELAYER_WALLET_PRIVATE_KEY");
        address relayerAddress = vm.addr(deployerPrivateKey);
        uint256 chainId = vm.envUint("CHAIN_ID");
        string memory network = vm.envString("NETWORK");

        // Try to read FEE_RECIPIENT_ADDRESS, default to address(0) if not set
        address feeRecipient;
        try vm.envAddress("FEE_RECIPIENT_ADDRESS") returns (address _feeRecipient) {
            feeRecipient = _feeRecipient;
            console.log("Using custom fee recipient:", feeRecipient);
        } catch {
            feeRecipient = address(0);
            console.log("No FEE_RECIPIENT_ADDRESS set, will default to owner");
        }

        console.log("Deploying with the following parameters:");
        console.log("Network:", network);
        console.log("Chain ID:", chainId);
        console.log("Relayer Address (Owner):", relayerAddress);
        console.log("Deployer Address:", vm.addr(deployerPrivateKey));
        
        // Verify we're on the expected chain
        require(block.chainid == chainId, "Chain ID mismatch");
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy implementation as separate transaction
        EscrowContract implementation = new EscrowContract();
        console.log("Implementation deployed at:", address(implementation));
        
        // Deploy factory with implementation address
        // feeRecipient uses environment variable or defaults to owner if not set
        EscrowContractFactory factory = new EscrowContractFactory(
            relayerAddress,
            address(implementation),
            feeRecipient
        );
        
        console.log("=================================================");
        console.log("Factory deployed at:", address(factory));
        console.log("=================================================");
        
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
    }
}