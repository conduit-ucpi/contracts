// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {EscrowContract} from "../src/EscrowContract.sol";
import {EscrowContractFactory} from "../src/EscrowContractFactory.sol";

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

contract EscrowContractTest is Test {
    EscrowContractFactory public factory;
    MockERC20 public usdc;
    
    address public buyer = address(0x1);
    address public seller = address(0x2);
    address public gasPayer = address(0x3);
    address public other = address(0x4);
    
    uint256 public constant AMOUNT = 1000 * 10**6; // 1000 USDC
    uint256 public expiryTimestamp;
    string public description = "Test escrow transaction";
    
    function setUp() public {
        usdc = new MockERC20();
        factory = new EscrowContractFactory(address(usdc), gasPayer);
        
        expiryTimestamp = block.timestamp + 7 days;
        
        usdc.mint(buyer, AMOUNT * 10);
        
        vm.prank(buyer);
        usdc.approve(address(factory), AMOUNT * 10);
    }
    
    function testConstructorValidation() public {
        vm.expectRevert("Invalid seller");
        new EscrowContract(
            address(usdc),
            buyer,
            address(0),
            gasPayer,
            AMOUNT,
            expiryTimestamp,
            description
        );
        
        vm.expectRevert("Amount must be positive");
        new EscrowContract(
            address(usdc),
            buyer,
            seller,
            gasPayer,
            0,
            expiryTimestamp,
            description
        );
        
        vm.expectRevert("Expiry must be future");
        new EscrowContract(
            address(usdc),
            buyer,
            seller,
            gasPayer,
            AMOUNT,
            block.timestamp - 1,
            description
        );
        
        string memory longDescription = "This is a very long description that exceeds the 160 character limit and should cause the constructor to revert with an error message";
        vm.expectRevert("Description too long");
        new EscrowContract(
            address(usdc),
            buyer,
            seller,
            gasPayer,
            AMOUNT,
            expiryTimestamp,
            longDescription
        );
    }
    
    function testSuccessfulDeployment() public {
        vm.prank(buyer);
        usdc.approve(address(this), AMOUNT);
        
        EscrowContract escrow = new EscrowContract(
            address(usdc),
            buyer,
            seller,
            gasPayer,
            AMOUNT,
            expiryTimestamp,
            description
        );
        
        assertEq(address(escrow.USDC_TOKEN()), address(usdc));
        assertEq(escrow.BUYER(), buyer);
        assertEq(escrow.SELLER(), seller);
        assertEq(escrow.GAS_PAYER(), gasPayer);
        assertEq(escrow.AMOUNT(), AMOUNT);
        assertEq(escrow.EXPIRY_TIMESTAMP(), expiryTimestamp);
        assertEq(escrow.description(), description);
        assertFalse(escrow.disputed());
        assertFalse(escrow.resolved());
        assertFalse(escrow.claimed());
        
        assertEq(usdc.balanceOf(address(escrow)), AMOUNT);
    }
    
    function testRaiseDispute() public {
        vm.prank(gasPayer);
        usdc.approve(address(factory), AMOUNT);
        
        vm.prank(gasPayer);
        address escrowAddress = factory.createEscrowContract(
            seller,
            AMOUNT,
            expiryTimestamp,
            description
        );
        EscrowContract escrow = EscrowContract(escrowAddress);
        
        vm.prank(gasPayer); // gasPayer is the buyer in this test
        escrow.raiseDispute();
        
        assertTrue(escrow.disputed());
        assertFalse(escrow.canClaim());
        assertFalse(escrow.canDispute());
    }
    
    function testOnlyBuyerCanRaiseDispute() public {
        vm.prank(gasPayer);
        address escrowAddress = factory.createEscrowContract(
            seller,
            AMOUNT,
            expiryTimestamp,
            description
        );
        EscrowContract escrow = EscrowContract(escrowAddress);
        
        vm.prank(seller);
        vm.expectRevert("Only buyer can call");
        escrow.raiseDispute();
        
        vm.prank(gasPayer);
        vm.expectRevert("Only buyer can call");
        escrow.raiseDispute();
    }
    
    function testCannotRaiseDisputeTwice() public {
        vm.prank(gasPayer);
        address escrowAddress = factory.createEscrowContract(
            seller,
            AMOUNT,
            expiryTimestamp,
            description
        );
        EscrowContract escrow = EscrowContract(escrowAddress);
        
        vm.prank(buyer);
        escrow.raiseDispute();
        
        vm.prank(buyer);
        vm.expectRevert("Already disputed");
        escrow.raiseDispute();
    }
    
    function testResolveDispute() public {
        vm.prank(gasPayer);
        address escrowAddress = factory.createEscrowContract(
            seller,
            AMOUNT,
            expiryTimestamp,
            description
        );
        EscrowContract escrow = EscrowContract(escrowAddress);
        
        vm.prank(buyer);
        escrow.raiseDispute();
        
        uint256 buyerBalanceBefore = usdc.balanceOf(buyer);
        
        vm.prank(gasPayer);
        escrow.resolveDispute(buyer);
        
        assertTrue(escrow.resolved());
        assertTrue(escrow.claimed());
        assertEq(usdc.balanceOf(buyer), buyerBalanceBefore + AMOUNT);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }
    
    function testOnlyGasPayerCanResolveDispute() public {
        vm.prank(gasPayer);
        address escrowAddress = factory.createEscrowContract(
            seller,
            AMOUNT,
            expiryTimestamp,
            description
        );
        EscrowContract escrow = EscrowContract(escrowAddress);
        
        vm.prank(buyer);
        escrow.raiseDispute();
        
        vm.prank(buyer);
        vm.expectRevert("Only gas payer can call");
        escrow.resolveDispute(buyer);
        
        vm.prank(seller);
        vm.expectRevert("Only gas payer can call");
        escrow.resolveDispute(buyer);
    }
    
    function testClaimFundsAfterExpiry() public {
        vm.prank(gasPayer);
        address escrowAddress = factory.createEscrowContract(
            seller,
            AMOUNT,
            expiryTimestamp,
            description
        );
        EscrowContract escrow = EscrowContract(escrowAddress);
        
        vm.warp(expiryTimestamp + 1);
        
        uint256 sellerBalanceBefore = usdc.balanceOf(seller);
        
        vm.prank(seller);
        escrow.claimFunds();
        
        assertTrue(escrow.claimed());
        assertEq(usdc.balanceOf(seller), sellerBalanceBefore + AMOUNT);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }
    
    function testGasPayerCanClaimFunds() public {
        vm.prank(gasPayer);
        address escrowAddress = factory.createEscrowContract(
            seller,
            AMOUNT,
            expiryTimestamp,
            description
        );
        EscrowContract escrow = EscrowContract(escrowAddress);
        
        vm.warp(expiryTimestamp + 1);
        
        uint256 sellerBalanceBefore = usdc.balanceOf(seller);
        
        vm.prank(gasPayer);
        escrow.claimFunds();
        
        assertTrue(escrow.claimed());
        assertEq(usdc.balanceOf(seller), sellerBalanceBefore + AMOUNT);
    }
    
    function testCannotClaimBeforeExpiry() public {
        vm.prank(gasPayer);
        address escrowAddress = factory.createEscrowContract(
            seller,
            AMOUNT,
            expiryTimestamp,
            description
        );
        EscrowContract escrow = EscrowContract(escrowAddress);
        
        vm.prank(seller);
        vm.expectRevert("Not expired yet");
        escrow.claimFunds();
    }
    
    function testCannotClaimIfDisputed() public {
        vm.prank(gasPayer);
        address escrowAddress = factory.createEscrowContract(
            seller,
            AMOUNT,
            expiryTimestamp,
            description
        );
        EscrowContract escrow = EscrowContract(escrowAddress);
        
        vm.prank(buyer);
        escrow.raiseDispute();
        
        vm.warp(expiryTimestamp + 1);
        
        vm.prank(seller);
        vm.expectRevert("Contract disputed");
        escrow.claimFunds();
    }
    
    function testViewFunctions() public {
        vm.prank(gasPayer);
        address escrowAddress = factory.createEscrowContract(
            seller,
            AMOUNT,
            expiryTimestamp,
            description
        );
        EscrowContract escrow = EscrowContract(escrowAddress);
        
        (
            address _buyer,
            address _seller,
            uint256 _amount,
            uint256 _expiryTimestamp,
            string memory _description,
            bool _disputed,
            bool _resolved,
            bool _claimed,
            uint256 _currentTimestamp
        ) = escrow.getContractInfo();
        
        assertEq(_buyer, buyer);
        assertEq(_seller, seller);
        assertEq(_amount, AMOUNT);
        assertEq(_expiryTimestamp, expiryTimestamp);
        assertEq(_description, description);
        assertFalse(_disputed);
        assertFalse(_resolved);
        assertFalse(_claimed);
        assertEq(_currentTimestamp, block.timestamp);
        
        assertFalse(escrow.isExpired());
        assertTrue(escrow.canDispute());
        assertFalse(escrow.canClaim());
        
        vm.warp(expiryTimestamp + 1);
        assertTrue(escrow.isExpired());
        assertTrue(escrow.canClaim());
    }
}