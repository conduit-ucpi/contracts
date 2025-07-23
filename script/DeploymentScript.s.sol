// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "../src/EscrowContractFactory.sol";

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
        console.log("USDC token address:", address(factory.usdcToken()));
        console.log("Factory owner:", factory.owner());
    }
}