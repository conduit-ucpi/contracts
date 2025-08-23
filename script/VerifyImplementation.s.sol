// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {EscrowContractFactory} from "../src/EscrowContractFactory.sol";

contract VerifyImplementation is Script {
    function run() external {
        // Get the factory address from environment or command line
        address factoryAddress = vm.envAddress("FACTORY_ADDRESS");
        
        console.log("Getting implementation address from factory:", factoryAddress);
        
        EscrowContractFactory factory = EscrowContractFactory(factoryAddress);
        address implementation = factory.IMPLEMENTATION();
        
        console.log("Implementation address:", implementation);
        console.log("=================================================");
        console.log("To verify the implementation contract manually, run:");
        console.log("");
        console.log("forge verify-contract \\");
        console.log("    ", implementation, " \\");
        console.log("    src/EscrowContract.sol:EscrowContract \\");
        console.log("    --verifier blockscout \\");
        console.log("    --verifier-url $VERIFIER_URL \\");
        console.log("    --compiler-version 0.8.26 \\");
        console.log("    --num-of-optimizations 200 \\");
        console.log("    --evm-version cancun \\");
        console.log("    --watch");
        console.log("=================================================");
    }
}