// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {EscrowContractFactory} from "../src/EscrowContractFactory.sol";

contract DeploymentScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("RELAYER_WALLET_PRIVATE_KEY");
        address usdcAddress = vm.envAddress("USDC_CONTRACT_ADDRESS");
        address relayerAddress = vm.addr(deployerPrivateKey);
        uint256 chainId = vm.envUint("CHAIN_ID");
        string memory network = vm.envString("NETWORK");
        
        console.log("Deploying with the following parameters:");
        console.log("Network:", network);
        console.log("Chain ID:", chainId);
        console.log("USDC Contract Address:", usdcAddress);
        console.log("Relayer Address (Owner):", relayerAddress);
        console.log("Deployer Address:", vm.addr(deployerPrivateKey));
        
        // Verify we're on the expected chain
        require(block.chainid == chainId, "Chain ID mismatch");
        
        vm.startBroadcast(deployerPrivateKey);
        
        EscrowContractFactory factory = new EscrowContractFactory(
            usdcAddress,
            relayerAddress
        );
        
        console.log("=================================================");
        console.log("Factory deployed at:", address(factory));
        console.log("=================================================");
        
        vm.stopBroadcast();
        
        console.log("Deployment completed successfully!");
        console.log("Factory contract address:", address(factory));
        console.log("Implementation contract address:", factory.IMPLEMENTATION());
        console.log("USDC token address:", address(factory.USDC_TOKEN()));
        console.log("Factory owner:", factory.OWNER());
        
        console.log("=================================================");
        console.log("CLONE DEPLOYMENT SUCCESSFUL!");
        console.log("Each escrow will be cloned from implementation:");
        console.log("Implementation:", factory.IMPLEMENTATION());
        console.log("Gas per escrow: ~188k (vs ~856k before cloning)");
        console.log("=================================================");
    }
}