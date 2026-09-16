// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {EscrowContract} from "../src/EscrowContract.sol";
import {EscrowContractFactory} from "../src/EscrowContractFactory.sol";

/**
 * Emits a test vector for the off-chain address predictors (chainservice and the browser).
 * They must reproduce these numbers exactly; a disagreement sends funds to an address
 * nothing can deploy to.
 */
contract PredictVectorTest is Test {
    function testEmitVector() public {
        EscrowContract implementation = new EscrowContract(address(0xDEFA17));
        EscrowContractFactory factory = new EscrowContractFactory(address(0x1), address(implementation), address(0));

        address token = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
        address buyer = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
        address seller = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
        uint256 amount = 1000000000;
        uint256 expiry = 1793500000;
        address arbiter = 0x9bB8e809EA6F5A74f46027D8016641D9cE9A149C;
        bytes32 externalId = keccak256(bytes("507f1f77bcf86cd799439011"));

        console.log("factory        ", address(factory));
        console.log("implementation ", address(implementation));
        console.logBytes32(externalId);
        console.log("predicted      ", factory.getContractAddress(token, buyer, seller, amount, expiry, arbiter, externalId));
    }
}
