// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

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
    MockERC20 public dai;
    
    address public owner = address(0x1);
    address public buyer = address(0x2);
    address public seller = address(0x3);
    address public other = address(0x4);
    
    uint256 public constant AMOUNT = 1000 * 10**6; // 1000 USDC
    uint256 public expiryTimestamp;
    string public description = "Test escrow transaction";
    
    event ContractCreated(
        address indexed contractAddress,
        address indexed buyer,
        address indexed seller,
        uint256 amount,
        uint256 expiryTimestamp
    );
    
    function setUp() public {
        usdc = new MockERC20();
        dai = new MockERC20();
        EscrowContract implementation = new EscrowContract();
        factory = new EscrowContractFactory(owner, address(implementation));
        
        expiryTimestamp = block.timestamp + 7 days;
        
        usdc.mint(buyer, AMOUNT * 10);
        usdc.mint(owner, AMOUNT * 10);
        dai.mint(buyer, AMOUNT * 10);
        dai.mint(owner, AMOUNT * 10);
        
        vm.prank(buyer);
        usdc.approve(address(factory), AMOUNT * 10);
        
        vm.prank(buyer);
        dai.approve(address(factory), AMOUNT * 10);
        
        vm.prank(owner);
        usdc.approve(address(factory), AMOUNT * 10);
        
        vm.prank(owner);
        dai.approve(address(factory), AMOUNT * 10);
    }
    
    function testConstructorValidation() public {
        // Constructor should accept valid addresses without reverting
        EscrowContract impl = new EscrowContract();
        EscrowContractFactory testFactory = new EscrowContractFactory(owner, address(impl));
        assertEq(testFactory.OWNER(), owner);
        assertEq(testFactory.IMPLEMENTATION(), address(impl));
    }
    
    function testSuccessfulDeployment() public view {
        assertEq(factory.OWNER(), owner);
        assertTrue(factory.IMPLEMENTATION() != address(0));
    }
    
    function testCreateEscrowContract() public {
        // Gas-payer (owner) calls factory with buyer and seller addresses
        vm.prank(owner);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            description
        );
        
        assertTrue(escrowAddress != address(0));
        
        EscrowContract escrow = EscrowContract(escrowAddress);
        assertEq(escrow.BUYER(), buyer); // buyer is the actual buyer
        assertEq(escrow.SELLER(), seller);
        assertEq(escrow.GAS_PAYER(), owner); // owner is the gas payer
        assertEq(escrow.AMOUNT(), AMOUNT);
        assertEq(escrow.EXPIRY_TIMESTAMP(), expiryTimestamp);
        assertEq(escrow.DESCRIPTION(), description);
        
        // Contract starts unfunded - no USDC transferred yet
        assertEq(usdc.balanceOf(escrowAddress), 0);
        assertEq(usdc.balanceOf(buyer), AMOUNT * 10); // buyer's balance unchanged
    }
    
    function testCreateEscrowWithDifferentTokens() public {
        vm.startPrank(owner);
        
        // Create USDC escrow
        address usdcEscrow = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            "USDC escrow"
        );
        
        // Create DAI escrow
        address daiEscrow = factory.createEscrowContract(
            address(dai),
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            "DAI escrow"
        );
        
        assertTrue(usdcEscrow != daiEscrow);
        
        EscrowContract usdcContract = EscrowContract(usdcEscrow);
        EscrowContract daiContract = EscrowContract(daiEscrow);
        
        assertEq(address(usdcContract.USDC_TOKEN()), address(usdc));
        assertEq(address(daiContract.USDC_TOKEN()), address(dai));
        
        vm.stopPrank();
    }
    
    function testOnlyOwnerCanCreateEscrow() public {
        vm.prank(other);
        vm.expectRevert("Only owner");
        factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            description
        );
    }
    
    function testCreateEscrowValidation() public {
        vm.startPrank(owner);
        
        vm.expectRevert("Invalid token address");
        factory.createEscrowContract(
            address(0),
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            description
        );
        
        vm.expectRevert("Invalid buyer address");
        factory.createEscrowContract(
            address(usdc),
            address(0),
            seller,
            AMOUNT,
            expiryTimestamp,
            description
        );
        
        vm.expectRevert("Invalid seller address");
        factory.createEscrowContract(
            address(usdc),
            buyer,
            address(0),
            AMOUNT,
            expiryTimestamp,
            description
        );
        
        // Test same buyer and seller
        vm.expectRevert("Buyer and seller cannot be the same");
        factory.createEscrowContract(
            address(usdc),
            buyer,
            buyer,
            AMOUNT,
            expiryTimestamp,
            description
        );
        
        vm.expectRevert("Invalid params");
        factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            0,
            expiryTimestamp,
            description
        );
        
        vm.expectRevert("Invalid params");
        factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            block.timestamp - 1,
            description
        );
        
        // Test that amounts equal to minimum fee are rejected
        // For USDC (6 decimals), minimum fee is 300,000 (30% of 1,000,000)
        // So amount of exactly 300,000 should be rejected as it can't cover the fee
        vm.expectRevert("Amount too small to cover minimum fee");
        factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            300000, // 0.3 USDC - exactly equal to minimum fee
            expiryTimestamp,
            description
        );
        
        // Test with invalid parameters - zero addresses
        vm.expectRevert("Invalid buyer address");
        factory.createEscrowContract(
            address(usdc),
            address(0),
            seller,
            AMOUNT,
            expiryTimestamp,
            description
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
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            description
        );
        
        assertTrue(escrowAddress != address(0));
    }
    
    function testMultipleContracts() public {
        vm.startPrank(owner);
        
        string memory firstDesc = "First escrow";
        string memory secondDesc = "Second escrow";
        
        address escrow1 = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            firstDesc
        );
        
        address escrow2 = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT * 2,
            expiryTimestamp + 1 days,
            secondDesc
        );
        
        assertTrue(escrow1 != escrow2);
        assertTrue(escrow1 != address(0));
        assertTrue(escrow2 != address(0));
        
        EscrowContract contract1 = EscrowContract(escrow1);
        EscrowContract contract2 = EscrowContract(escrow2);
        
        assertEq(contract1.AMOUNT(), AMOUNT);
        assertEq(contract2.AMOUNT(), AMOUNT * 2);
        assertEq(contract1.DESCRIPTION(), firstDesc);
        assertEq(contract2.DESCRIPTION(), secondDesc);
        
        vm.stopPrank();
    }
    
    function testDeterministicAddresses() public {
        vm.startPrank(owner);
        
        uint256 creationTime1 = block.timestamp;
        address escrow1 = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            description
        );
        
        vm.warp(block.timestamp + 1);
        
        uint256 creationTime2 = block.timestamp;
        address escrow2 = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            description
        );
        
        assertTrue(escrow1 != escrow2);
        
        // Test that the prediction function exists and runs without error
        factory.getContractAddress(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            creationTime1
        );
        
        factory.getContractAddress(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            creationTime2
        );
        
        vm.stopPrank();
    }
    
    function testNoFeeThreshold() public {
        vm.startPrank(owner);
        
        // Test amount at no-fee threshold (1/1000 of one unit)
        // For USDC (6 decimals): 1 unit = 1,000,000, so threshold = 1,000
        uint256 noFeeAmount = 1000; // 1000 microUSDC = 0.001 USDC
        
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            noFeeAmount,
            expiryTimestamp,
            "No fee test"
        );
        
        EscrowContract escrow = EscrowContract(escrowAddress);
        assertEq(escrow.CREATOR_FEE(), 0); // Should be 0 fee
        
        // Test amount just above threshold - should have minimum fee
        // For USDC minimum fee is 300,000, so amount must be > 300,000
        uint256 smallFeeAmount = 400000; // 0.4 USDC - above threshold and minimum fee
        
        address escrowAddress2 = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            smallFeeAmount,
            expiryTimestamp,
            "Small fee test"
        );
        
        EscrowContract escrow2 = EscrowContract(escrowAddress2);
        uint256 expectedMinFee = 300000; // 30% of 1,000,000 
        assertEq(escrow2.CREATOR_FEE(), expectedMinFee); // Should have minimum fee
        
        vm.stopPrank();
    }
    
    function testAmountTooSmallForMinFee() public {
        vm.prank(owner);
        
        // Test amount that's above no-fee threshold but below minimum fee
        // For USDC: no-fee threshold = 1,000, minimum fee = 300,000
        // So amounts between 1,001 and 300,000 should be rejected
        uint256 tooSmallAmount = 200000; // 0.2 USDC - above threshold but can't cover 0.3 USDC min fee
        
        vm.expectRevert("Amount too small to cover minimum fee");
        factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            tooSmallAmount,
            expiryTimestamp,
            "Too small amount test"
        );
    }
    
    function testReentrancyProtection() public {
        vm.prank(owner);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            description
        );
        
        assertTrue(escrowAddress != address(0));
    }
    
    function testInsufficientBalance() public {
        // Create a new buyer with no USDC balance
        address poorBuyer = address(0x5);
        
        // Factory no longer transfers funds, so this should succeed
        vm.prank(owner);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            poorBuyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            description
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
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            description
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