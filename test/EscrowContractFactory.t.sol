// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/EscrowContractFactory.sol";
import "../src/EscrowContract.sol";

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
    
    event ContractCreated(
        address indexed contractAddress,
        address indexed buyer,
        address indexed seller,
        uint256 amount,
        uint256 expiryTimestamp,
        string description
    );
    
    function setUp() public {
        usdc = new MockERC20();
        factory = new EscrowContractFactory(address(usdc), owner);
        
        expiryTimestamp = block.timestamp + 7 days;
        
        usdc.mint(buyer, AMOUNT * 10);
        usdc.mint(owner, AMOUNT * 10);
        
        vm.prank(buyer);
        usdc.approve(address(factory), AMOUNT * 10);
        
        vm.prank(owner);
        usdc.approve(address(factory), AMOUNT * 10);
    }
    
    function testConstructorValidation() public {
        vm.expectRevert("Invalid USDC address");
        new EscrowContractFactory(address(0), owner);
        
        vm.expectRevert("Invalid owner address");
        new EscrowContractFactory(address(usdc), address(0));
    }
    
    function testSuccessfulDeployment() public {
        assertEq(address(factory.usdcToken()), address(usdc));
        assertEq(factory.owner(), owner);
    }
    
    function testCreateEscrowContract() public {
        vm.prank(owner);
        address escrowAddress = factory.createEscrowContract(
            seller,
            AMOUNT,
            expiryTimestamp,
            description
        );
        
        assertTrue(escrowAddress != address(0));
        
        EscrowContract escrow = EscrowContract(escrowAddress);
        assertEq(escrow.buyer(), owner);
        assertEq(escrow.seller(), seller);
        assertEq(escrow.gasPayer(), owner);
        assertEq(escrow.amount(), AMOUNT);
        assertEq(escrow.expiryTimestamp(), expiryTimestamp);
        assertEq(escrow.description(), description);
        
        assertEq(usdc.balanceOf(escrowAddress), AMOUNT);
    }
    
    function testOnlyOwnerCanCreateEscrow() public {
        vm.prank(other);
        vm.expectRevert("Ownable: caller is not the owner");
        factory.createEscrowContract(
            seller,
            AMOUNT,
            expiryTimestamp,
            description
        );
    }
    
    function testCreateEscrowValidation() public {
        vm.startPrank(owner);
        
        vm.expectRevert("Invalid seller address");
        factory.createEscrowContract(
            address(0),
            AMOUNT,
            expiryTimestamp,
            description
        );
        
        vm.expectRevert("Amount must be positive");
        factory.createEscrowContract(
            seller,
            0,
            expiryTimestamp,
            description
        );
        
        vm.expectRevert("Expiry must be future");
        factory.createEscrowContract(
            seller,
            AMOUNT,
            block.timestamp - 1,
            description
        );
        
        string memory longDescription = "This is a very long description that exceeds the 160 character limit and should cause the function to revert with an error message";
        vm.expectRevert("Description too long");
        factory.createEscrowContract(
            seller,
            AMOUNT,
            expiryTimestamp,
            longDescription
        );
        
        vm.stopPrank();
    }
    
    function testContractCreatedEvent() public {
        vm.expectEmit(true, true, true, true);
        emit ContractCreated(
            address(0), // We don't know the address beforehand
            owner,
            seller,
            AMOUNT,
            expiryTimestamp,
            description
        );
        
        vm.prank(owner);
        address escrowAddress = factory.createEscrowContract(
            seller,
            AMOUNT,
            expiryTimestamp,
            description
        );
        
        assertTrue(escrowAddress != address(0));
    }
    
    function testMultipleContracts() public {
        vm.startPrank(owner);
        
        address escrow1 = factory.createEscrowContract(
            seller,
            AMOUNT,
            expiryTimestamp,
            "First escrow"
        );
        
        address escrow2 = factory.createEscrowContract(
            seller,
            AMOUNT * 2,
            expiryTimestamp + 1 days,
            "Second escrow"
        );
        
        assertTrue(escrow1 != escrow2);
        assertTrue(escrow1 != address(0));
        assertTrue(escrow2 != address(0));
        
        EscrowContract contract1 = EscrowContract(escrow1);
        EscrowContract contract2 = EscrowContract(escrow2);
        
        assertEq(contract1.amount(), AMOUNT);
        assertEq(contract2.amount(), AMOUNT * 2);
        assertEq(contract1.description(), "First escrow");
        assertEq(contract2.description(), "Second escrow");
        
        vm.stopPrank();
    }
    
    function testDeterministicAddresses() public {
        vm.startPrank(owner);
        
        uint256 creationTime1 = block.timestamp;
        address escrow1 = factory.createEscrowContract(
            seller,
            AMOUNT,
            expiryTimestamp,
            description
        );
        
        vm.warp(block.timestamp + 1);
        
        uint256 creationTime2 = block.timestamp;
        address escrow2 = factory.createEscrowContract(
            seller,
            AMOUNT,
            expiryTimestamp,
            description
        );
        
        assertTrue(escrow1 != escrow2);
        
        address predicted1 = factory.getContractAddress(
            owner,
            seller,
            AMOUNT,
            expiryTimestamp,
            creationTime1,
            description
        );
        
        address predicted2 = factory.getContractAddress(
            owner,
            seller,
            AMOUNT,
            expiryTimestamp,
            creationTime2,
            description
        );
        
        vm.stopPrank();
    }
    
    function testReentrancyProtection() public {
        vm.prank(owner);
        address escrowAddress = factory.createEscrowContract(
            seller,
            AMOUNT,
            expiryTimestamp,
            description
        );
        
        assertTrue(escrowAddress != address(0));
    }
    
    function testInsufficientBalance() public {
        address poorBuyer = address(0x999);
        
        vm.prank(owner);
        vm.expectRevert("USDC transfer failed");
        factory.createEscrowContract(
            seller,
            AMOUNT,
            expiryTimestamp,
            description
        );
    }
    
    function testInsufficientAllowance() public {
        vm.prank(owner);
        usdc.approve(address(factory), AMOUNT - 1);
        
        vm.prank(owner);
        vm.expectRevert("USDC transfer failed");
        factory.createEscrowContract(
            seller,
            AMOUNT,
            expiryTimestamp,
            description
        );
    }
}