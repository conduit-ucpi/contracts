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
    address public trustedForwarder = address(0x5);
    
    uint256 public constant AMOUNT = 1000 * 10**6; // 1000 USDC
    uint256 public expiryTimestamp;
    string public description = "Test escrow transaction";
    
    function setUp() public {
        usdc = new MockERC20();
        factory = new EscrowContractFactory(address(usdc), gasPayer, trustedForwarder);
        
        expiryTimestamp = block.timestamp + 7 days;
        
        // Give USDC to gasPayer so they can create escrow contracts
        usdc.mint(gasPayer, AMOUNT * 10);
        usdc.mint(buyer, AMOUNT * 10);
        
        vm.prank(gasPayer);
        usdc.approve(address(factory), AMOUNT * 10);
        
        vm.prank(buyer);
        usdc.approve(address(factory), AMOUNT * 10);
    }
    
    function createAndFundEscrow() internal returns (EscrowContract) {
        vm.prank(gasPayer);
        address escrowAddress = factory.createEscrowContract(
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            description
        );
        
        EscrowContract escrow = EscrowContract(escrowAddress);
        
        // Buyer approves and funds the escrow
        vm.prank(buyer);
        usdc.approve(address(escrow), AMOUNT);
        
        vm.prank(buyer);
        escrow.depositFunds();
        
        return escrow;
    }
    
    function testConstructorValidation() public {
        // Test implementation contract constructor
        EscrowContract implementation = new EscrowContract();
        
        // Implementation should be disabled (state 255)
        vm.expectRevert("Not initialized");
        implementation.isFunded();
        
        // Test cloned contract initialization
        EscrowContract testEscrow = createAndFundEscrow();
        
        // Verify all parameters were set correctly
        assertEq(address(testEscrow.USDC_TOKEN()), address(usdc));
        assertEq(testEscrow.BUYER(), buyer);
        assertEq(testEscrow.SELLER(), seller);
        assertEq(testEscrow.GAS_PAYER(), gasPayer);
        assertEq(testEscrow.AMOUNT(), AMOUNT);
        assertEq(testEscrow.EXPIRY_TIMESTAMP(), expiryTimestamp);
        assertEq(testEscrow.DESCRIPTION(), description);
    }
    
    function testSuccessfulDeployment() public {
        vm.prank(gasPayer);
        address escrowAddress = factory.createEscrowContract(
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            description
        );
        
        EscrowContract escrow = EscrowContract(escrowAddress);
        
        assertEq(address(escrow.USDC_TOKEN()), address(usdc));
        assertEq(escrow.BUYER(), buyer);
        assertEq(escrow.SELLER(), seller);
        assertEq(escrow.GAS_PAYER(), gasPayer);
        assertEq(escrow.AMOUNT(), AMOUNT);
        assertEq(escrow.EXPIRY_TIMESTAMP(), expiryTimestamp);
        assertEq(escrow.DESCRIPTION(), description);
        assertFalse(escrow.isDisputed());
        assertFalse(escrow.isClaimed());
        
        // Contract starts unfunded
        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertFalse(escrow.isFunded());
    }
    
    function testRaiseDispute() public {
        EscrowContract escrow = createAndFundEscrow();
        
        vm.prank(buyer);
        escrow.raiseDispute();
        
        assertTrue(escrow.isDisputed());
        assertFalse(escrow.canClaim());
        assertFalse(escrow.canDispute());
    }
    
    function testOnlyBuyerCanRaiseDispute() public {
        EscrowContract escrow = createAndFundEscrow();
        
        vm.prank(seller);
        vm.expectRevert("Only buyer can call");
        escrow.raiseDispute();
        
        vm.prank(gasPayer);
        vm.expectRevert("Only buyer can call");
        escrow.raiseDispute();
    }
    
    function testCannotRaiseDisputeTwice() public {
        EscrowContract escrow = createAndFundEscrow();
        
        vm.prank(buyer);
        escrow.raiseDispute();
        
        vm.prank(buyer);
        vm.expectRevert("Not funded or already processed");
        escrow.raiseDispute();
    }
    
    function testResolveDispute() public {
        EscrowContract escrow = createAndFundEscrow();
        
        vm.prank(buyer);
        escrow.raiseDispute();
        
        uint256 buyerBalanceBefore = usdc.balanceOf(buyer);
        
        vm.prank(gasPayer);
        escrow.resolveDispute(buyer);
        
        assertTrue(escrow.isClaimed());
        assertTrue(escrow.isClaimed());
        assertEq(usdc.balanceOf(buyer), buyerBalanceBefore + AMOUNT);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }
    
    function testOnlyGasPayerCanResolveDispute() public {
        EscrowContract escrow = createAndFundEscrow();
        
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
        EscrowContract escrow = createAndFundEscrow();
        
        vm.warp(expiryTimestamp + 1);
        
        uint256 sellerBalanceBefore = usdc.balanceOf(seller);
        
        vm.prank(seller);
        escrow.claimFunds();
        
        assertTrue(escrow.isClaimed());
        assertEq(usdc.balanceOf(seller), sellerBalanceBefore + AMOUNT);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }
    
    function testGasPayerCanClaimFunds() public {
        EscrowContract escrow = createAndFundEscrow();
        
        vm.warp(expiryTimestamp + 1);
        
        uint256 sellerBalanceBefore = usdc.balanceOf(seller);
        
        vm.prank(gasPayer);
        escrow.claimFunds();
        
        assertTrue(escrow.isClaimed());
        assertEq(usdc.balanceOf(seller), sellerBalanceBefore + AMOUNT);
    }
    
    function testCannotClaimBeforeExpiry() public {
        EscrowContract escrow = createAndFundEscrow();
        
        vm.prank(seller);
        vm.expectRevert("Not expired yet");
        escrow.claimFunds();
    }
    
    function testCannotClaimIfDisputed() public {
        EscrowContract escrow = createAndFundEscrow();
        
        vm.prank(buyer);
        escrow.raiseDispute();
        
        vm.warp(expiryTimestamp + 1);
        
        vm.prank(seller);
        vm.expectRevert("Not funded or already processed");
        escrow.claimFunds();
    }
    
    function testViewFunctions() public {
        EscrowContract escrow = createAndFundEscrow();
        
        (
            address _buyer,
            address _seller,
            uint256 _amount,
            uint256 _expiryTimestamp,
            string memory _description,
            uint8 _currentState,
            uint256 _currentTimestamp
        ) = escrow.getContractInfo();
        
        assertEq(_buyer, buyer);
        assertEq(_seller, seller);
        assertEq(_amount, AMOUNT);
        assertEq(_expiryTimestamp, expiryTimestamp);
        assertEq(keccak256(abi.encodePacked(_description)), keccak256(abi.encodePacked(description)));
        assertEq(_currentState, 1); // funded state
        assertEq(_currentTimestamp, block.timestamp);
        
        assertFalse(escrow.isExpired());
        assertTrue(escrow.canDispute());
        assertFalse(escrow.canClaim());
        
        vm.warp(expiryTimestamp + 1);
        assertTrue(escrow.isExpired());
        assertTrue(escrow.canClaim());
    }
    
    function testDepositFunds() public {
        vm.prank(gasPayer);
        address escrowAddress = factory.createEscrowContract(
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            description
        );
        EscrowContract escrow = EscrowContract(escrowAddress);
        
        assertFalse(escrow.isFunded());
        assertEq(usdc.balanceOf(address(escrow)), 0);
        
        uint256 buyerBalanceBefore = usdc.balanceOf(buyer);
        
        vm.prank(buyer);
        usdc.approve(address(escrow), AMOUNT);
        
        vm.prank(buyer);
        escrow.depositFunds();
        
        assertTrue(escrow.isFunded());
        assertEq(usdc.balanceOf(address(escrow)), AMOUNT);
        assertEq(usdc.balanceOf(buyer), buyerBalanceBefore - AMOUNT);
    }
    
    function testCannotDepositTwice() public {
        EscrowContract escrow = createAndFundEscrow();
        
        vm.prank(buyer);
        usdc.approve(address(escrow), AMOUNT);
        
        vm.prank(buyer);
        vm.expectRevert("Already funded or claimed");
        escrow.depositFunds();
    }
    
    function testOnlyBuyerCanDeposit() public {
        vm.prank(gasPayer);
        address escrowAddress = factory.createEscrowContract(
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            description
        );
        EscrowContract escrow = EscrowContract(escrowAddress);
        
        vm.prank(seller);
        vm.expectRevert("Only buyer can call");
        escrow.depositFunds();
        
        vm.prank(gasPayer);
        vm.expectRevert("Only buyer can call");
        escrow.depositFunds();
    }
    
    function testCannotUseUnfundedContract() public {
        vm.prank(gasPayer);
        address escrowAddress = factory.createEscrowContract(
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            description
        );
        EscrowContract escrow = EscrowContract(escrowAddress);
        
        vm.prank(buyer);
        vm.expectRevert("Not funded or already processed");
        escrow.raiseDispute();
        
        vm.warp(expiryTimestamp + 1);
        
        vm.prank(seller);
        vm.expectRevert("Not funded or already processed");
        escrow.claimFunds();
        
        vm.prank(gasPayer);
        vm.expectRevert("Not disputed");
        escrow.resolveDispute(buyer);
    }
    
    function testTrustedForwarderConfiguration() public {
        vm.prank(gasPayer);
        address escrowAddress = factory.createEscrowContract(
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            description
        );
        EscrowContract escrow = EscrowContract(escrowAddress);
        
        assertEq(escrow.trustedForwarder(), trustedForwarder);
        assertTrue(escrow.isTrustedForwarder(trustedForwarder));
        assertFalse(escrow.isTrustedForwarder(other));
    }
    
    function testFactoryTrustedForwarderConfiguration() public {
        assertEq(factory.trustedForwarder(), trustedForwarder);
        assertTrue(factory.isTrustedForwarder(trustedForwarder));
        assertFalse(factory.isTrustedForwarder(other));
    }
    
    // Mock test for meta-transaction functionality
    // In a real implementation, you would use a proper forwarder contract
    function testMetaTransactionMocking() public {
        EscrowContract escrow = createAndFundEscrow();
        
        // This test validates that the contract is configured to accept
        // meta-transactions from the trusted forwarder
        assertTrue(escrow.isTrustedForwarder(trustedForwarder));
        
        // In a real scenario, the trusted forwarder would call functions
        // on behalf of users by appending the user's address to calldata
        assertEq(escrow.trustedForwarder(), trustedForwarder);
    }
}