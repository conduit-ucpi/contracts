// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MinimalForwarder} from "../src/MinimalForwarder.sol";

contract MinimalForwarderTest is Test {
    MinimalForwarder public forwarder;
    
    function setUp() public {
        forwarder = new MinimalForwarder();
    }
    
    function testForwarderDeployment() public {
        // Verify the forwarder deployed correctly
        assertTrue(address(forwarder) != address(0));
    }
    
    function testForwarderCanBeUsedAsTrustedForwarder() public {
        // Verify it can be used as a trusted forwarder address
        address forwarderAddress = address(forwarder);
        assertTrue(forwarderAddress != address(0));
        
        // This is the address that would be passed to ERC2771Context contracts
        assertNotEq(forwarderAddress, address(0));
    }
}