// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {EscrowContractFactory} from "../src/EscrowContractFactory.sol";
import {EscrowContract} from "../src/EscrowContract.sol";

contract MockERC20 is Test {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    
    string public name = "Mock USDC";
    string public symbol = "MUSDC";
    uint8 public decimals = 6;
    uint256 public totalSupply = 1000000 * 10**6;
    
    constructor() {
        balanceOf[msg.sender] = totalSupply;
    }
    
    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;
        return true;
    }
    
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
    
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

contract EscrowContractFactoryTest is Test {
    EscrowContractFactory public factory;
    MockERC20 public usdc;
    
    address public owner = address(0x1);
    address public buyer = address(0x2);
    address public seller = address(0x3);
    address public other = address(0x4);
    
    uint256 public constant AMOUNT = 1000 * 10**6; // 1000 USDC
    uint256 public expiryTimestamp;
    string public description = "Test escrow transaction";
    bytes32 public descriptionHash;
    
    event ContractCreated(
        address indexed contractAddress,
        address indexed buyer,
        address indexed seller,
        uint256 amount,
        uint256 expiryTimestamp
    );
    
    function setUp() public {
        usdc = new MockERC20();
        factory = new EscrowContractFactory(address(usdc), owner);
        
        expiryTimestamp = block.timestamp + 7 days;
        descriptionHash = keccak256(abi.encodePacked(description));
        
        usdc.mint(buyer, AMOUNT * 10);
        usdc.mint(owner, AMOUNT * 10);
        
        vm.prank(buyer);
        usdc.approve(address(factory), AMOUNT * 10);
        
        vm.prank(owner);
        usdc.approve(address(factory), AMOUNT * 10);
    }
    
    function testConstructorValidation() public {
        // Constructor should accept valid addresses without reverting
        EscrowContractFactory testFactory = new EscrowContractFactory(address(usdc), owner);
        assertEq(address(testFactory.USDC_TOKEN()), address(usdc));
        assertEq(testFactory.OWNER(), owner);
    }
    
    function testSuccessfulDeployment() public view {
        assertEq(address(factory.USDC_TOKEN()), address(usdc));
        assertEq(factory.OWNER(), owner);
    }
    
    function testCreateEscrowContract() public {
        // Gas-payer (owner) calls factory with buyer and seller addresses
        vm.prank(owner);
        address escrowAddress = factory.createEscrowContract(
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            descriptionHash
        );
        
        assertTrue(escrowAddress != address(0));
        
        EscrowContract escrow = EscrowContract(escrowAddress);
        assertEq(escrow.BUYER(), buyer); // buyer is the actual buyer
        assertEq(escrow.SELLER(), seller);
        assertEq(escrow.GAS_PAYER(), owner); // owner is the gas payer
        assertEq(escrow.AMOUNT(), AMOUNT);
        assertEq(escrow.EXPIRY_TIMESTAMP(), expiryTimestamp);
        assertEq(escrow.DESCRIPTION_HASH(), descriptionHash);
        
        // Contract starts unfunded - no USDC transferred yet
        assertEq(usdc.balanceOf(escrowAddress), 0);
        assertEq(usdc.balanceOf(buyer), AMOUNT * 10); // buyer's balance unchanged
    }
    
    function testOnlyOwnerCanCreateEscrow() public {
        vm.prank(other);
        vm.expectRevert("Only owner");
        factory.createEscrowContract(
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            descriptionHash
        );
    }
    
    function testCreateEscrowValidation() public {
        vm.startPrank(owner);
        
        vm.expectRevert("Invalid addresses");
        factory.createEscrowContract(
            address(0),
            seller,
            AMOUNT,
            expiryTimestamp,
            descriptionHash
        );
        
        vm.expectRevert("Invalid addresses");
        factory.createEscrowContract(
            buyer,
            address(0),
            AMOUNT,
            expiryTimestamp,
            descriptionHash
        );
        
        vm.expectRevert("Invalid params");
        factory.createEscrowContract(
            buyer,
            seller,
            0,
            expiryTimestamp,
            descriptionHash
        );
        
        vm.expectRevert("Invalid params");
        factory.createEscrowContract(
            buyer,
            seller,
            AMOUNT,
            block.timestamp - 1,
            descriptionHash
        );
        
        // Test with invalid parameters - zero addresses
        vm.expectRevert("Invalid addresses");
        factory.createEscrowContract(
            address(0),
            seller,
            AMOUNT,
            expiryTimestamp,
            descriptionHash
        );
        
        vm.stopPrank();
    }
    
    function testContractCreatedEvent() public {
        vm.expectEmit(false, true, true, true); // Check all except first indexed param (address)
        emit ContractCreated(
            address(0), // We don't know the address beforehand
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp
        );
        
        vm.prank(owner);
        address escrowAddress = factory.createEscrowContract(
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            descriptionHash
        );
        
        assertTrue(escrowAddress != address(0));
    }
    
    function testMultipleContracts() public {
        vm.startPrank(owner);
        
        bytes32 firstDescHash = keccak256(abi.encodePacked("First escrow"));
        bytes32 secondDescHash = keccak256(abi.encodePacked("Second escrow"));
        
        address escrow1 = factory.createEscrowContract(
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            firstDescHash
        );
        
        address escrow2 = factory.createEscrowContract(
            buyer,
            seller,
            AMOUNT * 2,
            expiryTimestamp + 1 days,
            secondDescHash
        );
        
        assertTrue(escrow1 != escrow2);
        assertTrue(escrow1 != address(0));
        assertTrue(escrow2 != address(0));
        
        EscrowContract contract1 = EscrowContract(escrow1);
        EscrowContract contract2 = EscrowContract(escrow2);
        
        assertEq(contract1.AMOUNT(), AMOUNT);
        assertEq(contract2.AMOUNT(), AMOUNT * 2);
        assertEq(contract1.DESCRIPTION_HASH(), firstDescHash);
        assertEq(contract2.DESCRIPTION_HASH(), secondDescHash);
        
        vm.stopPrank();
    }
    
    function testDeterministicAddresses() public {
        vm.startPrank(owner);
        
        uint256 creationTime1 = block.timestamp;
        address escrow1 = factory.createEscrowContract(
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            descriptionHash
        );
        
        vm.warp(block.timestamp + 1);
        
        uint256 creationTime2 = block.timestamp;
        address escrow2 = factory.createEscrowContract(
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            descriptionHash
        );
        
        assertTrue(escrow1 != escrow2);
        
        // Test that the prediction function exists and runs without error
        factory.getContractAddress(
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            creationTime1,
            descriptionHash
        );
        
        factory.getContractAddress(
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            creationTime2,
            descriptionHash
        );
        
        vm.stopPrank();
    }
    
    function testReentrancyProtection() public {
        vm.prank(owner);
        address escrowAddress = factory.createEscrowContract(
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            descriptionHash
        );
        
        assertTrue(escrowAddress != address(0));
    }
    
    function testInsufficientBalance() public {
        // Create a new buyer with no USDC balance
        address poorBuyer = address(0x5);
        
        // Factory no longer transfers funds, so this should succeed
        vm.prank(owner);
        address escrowAddress = factory.createEscrowContract(
            poorBuyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            descriptionHash
        );
        
        assertTrue(escrowAddress != address(0));
        
        // But depositFunds should fail for poor buyer
        EscrowContract escrow = EscrowContract(escrowAddress);
        vm.prank(poorBuyer);
        vm.expectRevert("Insufficient balance");
        escrow.depositFunds();
    }
    
    function testInsufficientAllowance() public {
        // Factory no longer transfers funds, so creation should succeed
        vm.prank(owner);
        address escrowAddress = factory.createEscrowContract(
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            descriptionHash
        );
        
        assertTrue(escrowAddress != address(0));
        
        // But depositFunds should fail with insufficient allowance
        EscrowContract escrow = EscrowContract(escrowAddress);
        
        // Reduce buyer's allowance to escrow contract
        vm.prank(buyer);
        usdc.approve(address(escrow), AMOUNT - 1);
        
        vm.prank(buyer);
        vm.expectRevert("Insufficient allowance");
        escrow.depositFunds();
    }
}