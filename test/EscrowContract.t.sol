// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
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

// Delivers 1% less than requested on transfer/transferFrom, simulating a
// fee-on-transfer / deflationary token. Used to prove deposits reject such tokens.
contract FeeOnTransferERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint8 public decimals = 6;

    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount - (amount / 100); // 1% fee vanishes
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "allowance");
        require(balanceOf[from] >= amount, "balance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - (amount / 100); // recipient receives less than `amount`
        return true;
    }
}

// A minimal ERC20 that intentionally omits the optional decimals() function, to
// prove the factory tolerates it via a fallback rather than reverting.
contract NoDecimalsERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "allowance");
        require(balanceOf[from] >= amount, "balance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    // no decimals()
}

contract EscrowContractTest is Test {
    EscrowContractFactory public factory;
    MockERC20 public usdc;
    
    address public buyer = address(0x1);
    address public seller = address(0x2);
    address public arbiter = address(0x3);
    address public other = address(0x4);
    
    uint256 public constant AMOUNT = 1000 * 10**6; // 1000 USDC
    uint256 public CREATOR_FEE; // Will be calculated as 1% of AMOUNT
    uint256 public expiryTimestamp;
    string public description = "Test escrow transaction";
    
    function setUp() public {
        usdc = new MockERC20();
        EscrowContract implementation = new EscrowContract();
        factory = new EscrowContractFactory(arbiter, address(implementation), address(0));
        
        expiryTimestamp = block.timestamp + 7 days;
        
        // Calculate expected fee: 1% of AMOUNT (since 1% > minimum of 300,000)
        CREATOR_FEE = AMOUNT / 100; // 10 USDC (1% of 1000 USDC)
        
        // Give USDC to arbiter so they can create escrow contracts
        usdc.mint(arbiter, AMOUNT * 10);
        usdc.mint(buyer, AMOUNT * 10);
        
        vm.prank(arbiter);
        usdc.approve(address(factory), AMOUNT * 10);
        
        vm.prank(buyer);
        usdc.approve(address(factory), AMOUNT * 10);
    }
    
    function createAndFundEscrow() internal returns (EscrowContract) {
        vm.prank(arbiter);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            description,
            address(0)
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
        vm.expectRevert(EscrowContract.NotInitialized.selector);
        implementation.isFunded();
        
        // Test cloned contract initialization
        EscrowContract testEscrow = createAndFundEscrow();
        
        // Verify all parameters were set correctly
        assertEq(address(testEscrow.tokenAddress()), address(usdc));
        assertEq(testEscrow.BUYER(), buyer);
        assertEq(testEscrow.SELLER(), seller);
        assertEq(testEscrow.ARBITER(), arbiter);
        assertEq(testEscrow.AMOUNT(), AMOUNT);
        assertEq(testEscrow.EXPIRY_TIMESTAMP(), expiryTimestamp);
        // Description no longer stored in contract (emitted in events only to save gas)
    }
    
    function testSuccessfulDeployment() public {
        uint256 deploymentTime = block.timestamp;
        
        vm.prank(arbiter);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            description,
            address(0)
        );
        
        EscrowContract escrow = EscrowContract(escrowAddress);
        
        assertEq(address(escrow.tokenAddress()), address(usdc));
        assertEq(escrow.BUYER(), buyer);
        assertEq(escrow.SELLER(), seller);
        assertEq(escrow.ARBITER(), arbiter);
        assertEq(escrow.AMOUNT(), AMOUNT);
        assertEq(escrow.EXPIRY_TIMESTAMP(), expiryTimestamp);
        // Description no longer stored in contract (emitted in events only to save gas)
        assertEq(escrow.createdAt(), deploymentTime); // Verify createdAt is set to deployment time
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
        vm.expectRevert(EscrowContract.OnlyBuyer.selector);
        escrow.raiseDispute();
        
        vm.prank(arbiter);
        vm.expectRevert(EscrowContract.OnlyBuyer.selector);
        escrow.raiseDispute();
    }
    
    function testCannotRaiseDisputeTwice() public {
        EscrowContract escrow = createAndFundEscrow();
        
        vm.prank(buyer);
        escrow.raiseDispute();
        
        vm.prank(buyer);
        vm.expectRevert(EscrowContract.NotFundedOrAlreadyProcessed.selector);
        escrow.raiseDispute();
    }
    
    function testResolveDisputeViaVoting() public {
        EscrowContract escrow = createAndFundEscrow();

        vm.prank(buyer);
        escrow.raiseDispute();

        uint256 buyerBalanceBefore = usdc.balanceOf(buyer);

        // Buyer and admin vote for 100% to buyer
        vm.prank(buyer);
        escrow.submitResolutionVote(100);

        vm.prank(arbiter);
        escrow.submitResolutionVote(100);

        assertTrue(escrow.isClaimed());
        assertTrue(escrow.consensusReached());
        assertEq(usdc.balanceOf(buyer), buyerBalanceBefore + (AMOUNT - CREATOR_FEE));
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function testAllPartiesCanVote() public {
        EscrowContract escrow = createAndFundEscrow();

        vm.prank(buyer);
        escrow.raiseDispute();

        // All parties can vote
        vm.prank(buyer);
        escrow.submitResolutionVote(60);

        vm.prank(seller);
        escrow.submitResolutionVote(40);

        vm.prank(arbiter);
        escrow.submitResolutionVote(50);

        // No consensus yet since all votes differ
        assertFalse(escrow.consensusReached());
    }
    
    function testClaimFundsAfterExpiry() public {
        EscrowContract escrow = createAndFundEscrow();
        
        vm.warp(expiryTimestamp + 1);
        
        uint256 sellerBalanceBefore = usdc.balanceOf(seller);
        
        vm.prank(seller);
        escrow.claimFunds();
        
        assertTrue(escrow.isClaimed());
        assertEq(usdc.balanceOf(seller), sellerBalanceBefore + (AMOUNT - CREATOR_FEE));
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }
    
    function testAnyoneCanClaimFunds() public {
        EscrowContract escrow = createAndFundEscrow();

        vm.warp(expiryTimestamp + 1);

        uint256 sellerBalanceBefore = usdc.balanceOf(seller);

        // Random address triggers claim; funds still go to seller
        vm.prank(other);
        escrow.claimFunds();

        assertTrue(escrow.isClaimed());
        assertEq(usdc.balanceOf(seller), sellerBalanceBefore + (AMOUNT - CREATOR_FEE));
    }
    
    function testCannotClaimBeforeExpiry() public {
        EscrowContract escrow = createAndFundEscrow();
        
        vm.prank(seller);
        vm.expectRevert(EscrowContract.NotExpiredYet.selector);
        escrow.claimFunds();
    }
    
    function testCannotClaimIfDisputed() public {
        EscrowContract escrow = createAndFundEscrow();
        
        vm.prank(buyer);
        escrow.raiseDispute();
        
        vm.warp(expiryTimestamp + 1);
        
        vm.prank(seller);
        vm.expectRevert(EscrowContract.NotFundedOrAlreadyProcessed.selector);
        escrow.claimFunds();
    }
    
    function testViewFunctions() public {
        uint256 creationTime = block.timestamp;
        EscrowContract escrow = createAndFundEscrow();

        (
            address _buyer,
            address _seller,
            uint256 _amount,
            uint256 _expiryTimestamp,
            uint8 _currentState,
            uint256 _currentTimestamp,
            uint256 _creatorFee,
            uint256 _createdAt,
            address _tokenAddress
        ) = escrow.getContractInfo();

        assertEq(_buyer, buyer);
        assertEq(_seller, seller);
        assertEq(_amount, AMOUNT);
        assertEq(_expiryTimestamp, expiryTimestamp);
        // Description no longer stored in contract (emitted in events only to save gas)
        assertEq(_currentState, 1); // funded state
        assertEq(_currentTimestamp, block.timestamp);
        assertEq(_creatorFee, CREATOR_FEE);
        assertEq(_createdAt, creationTime); // Contract created at creation time
        assertEq(_tokenAddress, address(usdc)); // Verify token address
        
        assertFalse(escrow.isExpired());
        assertTrue(escrow.canDispute());
        assertFalse(escrow.canClaim());
        
        vm.warp(expiryTimestamp + 1);
        assertTrue(escrow.isExpired());
        assertFalse(escrow.canDispute()); // Cannot dispute after expiry
        assertTrue(escrow.canClaim());
    }
    
    function testCreatedAtPersistsThroughTime() public {
        uint256 creationTime = block.timestamp;
        
        vm.prank(arbiter);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            description,
            address(0)
        );
        
        EscrowContract escrow = EscrowContract(escrowAddress);
        
        // Check createdAt immediately after deployment
        assertEq(escrow.createdAt(), creationTime);
        
        // Warp time forward and check createdAt hasn't changed
        vm.warp(block.timestamp + 1 days);
        assertEq(escrow.createdAt(), creationTime);
        
        // Fund the contract
        vm.prank(buyer);
        usdc.approve(address(escrow), AMOUNT);
        vm.prank(buyer);
        escrow.depositFunds();
        
        // Check createdAt still hasn't changed after funding
        assertEq(escrow.createdAt(), creationTime);
        
        // Warp to expiry and check createdAt still hasn't changed
        vm.warp(expiryTimestamp + 1);
        assertEq(escrow.createdAt(), creationTime);
        
        // Claim funds and verify createdAt still hasn't changed
        vm.prank(seller);
        escrow.claimFunds();
        assertEq(escrow.createdAt(), creationTime);
    }
    
    function testDepositFunds() public {
        vm.prank(arbiter);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            description,
            address(0)
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
        assertEq(usdc.balanceOf(address(escrow)), AMOUNT - CREATOR_FEE);
        assertEq(usdc.balanceOf(buyer), buyerBalanceBefore - AMOUNT);
    }
    
    function testCannotDepositTwice() public {
        EscrowContract escrow = createAndFundEscrow();
        
        vm.prank(buyer);
        usdc.approve(address(escrow), AMOUNT);
        
        vm.prank(buyer);
        vm.expectRevert(EscrowContract.AlreadyFundedOrClaimed.selector);
        escrow.depositFunds();
    }
    
    function testAnyoneCanDeposit() public {
        vm.prank(arbiter);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            description,
            address(0)
        );
        EscrowContract escrow = EscrowContract(escrowAddress);

        // Buyer approves the contract to spend tokens
        vm.prank(buyer);
        usdc.approve(address(escrow), AMOUNT);

        // Anyone can call depositFunds (seller in this case)
        // The tokens still come from the BUYER who approved them
        vm.prank(seller);
        escrow.depositFunds(); // This should succeed

        // Verify contract is now funded
        (,,,,uint8 state,,,,) = escrow.getContractInfo();
        assertEq(state, 1, "Contract should be ACTIVE");
    }
    
    function testCannotUseUnfundedContract() public {
        vm.prank(arbiter);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            description,
            address(0)
        );
        EscrowContract escrow = EscrowContract(escrowAddress);
        
        vm.prank(buyer);
        vm.expectRevert(EscrowContract.NotFundedOrAlreadyProcessed.selector);
        escrow.raiseDispute();
        
        vm.warp(expiryTimestamp + 1);
        
        vm.prank(seller);
        vm.expectRevert(EscrowContract.NotFundedOrAlreadyProcessed.selector);
        escrow.claimFunds();
        
        vm.prank(arbiter);
        vm.expectRevert(EscrowContract.ContractMustBeDisputed.selector);
        escrow.submitResolutionVote(100);
    }
    
    
    
    
    function testCreatorFeeTransferOnDeposit() public {
        vm.prank(arbiter);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            description,
            address(0)
        );
        
        EscrowContract escrow = EscrowContract(escrowAddress);
        
        // Record initial balances
        uint256 initialArbiterBalance = usdc.balanceOf(arbiter);
        uint256 initialBuyerBalance = usdc.balanceOf(buyer);
        
        // Buyer approves and funds the escrow
        vm.prank(buyer);
        usdc.approve(address(escrow), AMOUNT);
        
        vm.prank(buyer);
        escrow.depositFunds();
        
        // Check that creator fee was transferred to gas payer
        assertEq(usdc.balanceOf(arbiter), initialArbiterBalance + CREATOR_FEE);
        assertEq(usdc.balanceOf(buyer), initialBuyerBalance - AMOUNT);
        assertEq(usdc.balanceOf(address(escrow)), AMOUNT - CREATOR_FEE);
    }
    
    function testClaimFundsWithCreatorFee() public {
        EscrowContract escrow = createAndFundEscrow();
        
        // Record initial seller balance
        uint256 initialSellerBalance = usdc.balanceOf(seller);
        
        // Fast forward past expiry
        vm.warp(expiryTimestamp + 1);
        
        vm.prank(seller);
        escrow.claimFunds();
        
        // Seller should receive amount minus creator fee
        assertEq(usdc.balanceOf(seller), initialSellerBalance + (AMOUNT - CREATOR_FEE));
        assertTrue(escrow.isClaimed());
    }
    
    function testResolveDisputeWithCreatorFee() public {
        EscrowContract escrow = createAndFundEscrow();

        // Buyer raises dispute
        vm.prank(buyer);
        escrow.raiseDispute();

        // Record initial buyer balance
        uint256 initialBuyerBalance = usdc.balanceOf(buyer);

        // Resolve dispute via voting (buyer and admin vote for 100% to buyer)
        vm.prank(buyer);
        escrow.submitResolutionVote(100);

        vm.prank(arbiter);
        escrow.submitResolutionVote(100);

        // Buyer should receive amount minus creator fee
        assertEq(usdc.balanceOf(buyer), initialBuyerBalance + (AMOUNT - CREATOR_FEE));
        assertTrue(escrow.isClaimed());
    }
    
    function testResolveDisputeWithSplit() public {
        EscrowContract escrow = createAndFundEscrow();

        // Buyer raises dispute
        vm.prank(buyer);
        escrow.raiseDispute();

        // Record initial balances
        uint256 initialBuyerBalance = usdc.balanceOf(buyer);
        uint256 initialSellerBalance = usdc.balanceOf(seller);

        // Resolve via voting with 60/40 split (buyer and seller agree)
        vm.prank(buyer);
        escrow.submitResolutionVote(60);

        vm.prank(seller);
        escrow.submitResolutionVote(60);

        uint256 escrowAmount = AMOUNT - CREATOR_FEE;
        uint256 expectedBuyerAmount = (escrowAmount * 60) / 100;
        uint256 expectedSellerAmount = escrowAmount - expectedBuyerAmount;

        // Check balances
        assertEq(usdc.balanceOf(buyer), initialBuyerBalance + expectedBuyerAmount);
        assertEq(usdc.balanceOf(seller), initialSellerBalance + expectedSellerAmount);
        assertTrue(escrow.isClaimed());
    }

    function testResolveDisputeFullySeller() public {
        EscrowContract escrow = createAndFundEscrow();

        // Buyer raises dispute
        vm.prank(buyer);
        escrow.raiseDispute();

        // Record initial balances
        uint256 initialBuyerBalance = usdc.balanceOf(buyer);
        uint256 initialSellerBalance = usdc.balanceOf(seller);

        // Resolve via voting 0% to buyer (100% to seller)
        vm.prank(seller);
        escrow.submitResolutionVote(0);

        vm.prank(arbiter);
        escrow.submitResolutionVote(0);

        // Check balances - buyer should get nothing, seller gets all
        assertEq(usdc.balanceOf(buyer), initialBuyerBalance);
        assertEq(usdc.balanceOf(seller), initialSellerBalance + (AMOUNT - CREATOR_FEE));
        assertTrue(escrow.isClaimed());
    }

    function testVoteInvalidPercentage() public {
        EscrowContract escrow = createAndFundEscrow();

        // Buyer raises dispute
        vm.prank(buyer);
        escrow.raiseDispute();

        // Test invalid percentage > 100
        vm.prank(buyer);
        vm.expectRevert(EscrowContract.InvalidPercentage.selector);
        escrow.submitResolutionVote(101);
    }
    
    function testCannotDisputeAfterExpiry() public {
        EscrowContract escrow = createAndFundEscrow();
        
        // Fast forward past expiry
        vm.warp(expiryTimestamp + 1);
        
        // Verify canDispute returns false
        assertFalse(escrow.canDispute());
        
        // Attempt to raise dispute should fail
        vm.prank(buyer);
        vm.expectRevert(EscrowContract.CannotDisputeAfterExpiry.selector);
        escrow.raiseDispute();
    }
    
    function testCanDisputeBeforeExpiry() public {
        EscrowContract escrow = createAndFundEscrow();
        
        // Right before expiry
        vm.warp(expiryTimestamp - 1);
        
        // Should still be able to dispute
        assertTrue(escrow.canDispute());
        
        vm.prank(buyer);
        escrow.raiseDispute();
        
        assertTrue(escrow.isDisputed());
    }
    
    function testCannotDisputeAtExactExpiry() public {
        EscrowContract escrow = createAndFundEscrow();
        
        // At exact expiry timestamp
        vm.warp(expiryTimestamp);
        
        // Should not be able to dispute anymore
        assertFalse(escrow.canDispute());
        
        vm.prank(buyer);
        vm.expectRevert(EscrowContract.CannotDisputeAfterExpiry.selector);
        escrow.raiseDispute();
    }
    
    function testDisputeTimingTransition() public {
        EscrowContract escrow = createAndFundEscrow();

        // Just before expiry - should work
        vm.warp(expiryTimestamp - 1);
        assertTrue(escrow.canDispute());

        // At expiry - should not work
        vm.warp(expiryTimestamp);
        assertFalse(escrow.canDispute());

        // After expiry - should not work
        vm.warp(expiryTimestamp + 1);
        assertFalse(escrow.canDispute());
    }

    // ========== INSTANT TRANSFER TESTS (EXPIRY TIMESTAMP = 0) ==========

    function testInstantTransferHappyPath() public {
        // Create instant transfer escrow with expiryTimestamp = 0
        vm.prank(arbiter);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            0, // Instant transfer - expiry = 0
            description,
            address(0)
        );

        EscrowContract escrow = EscrowContract(escrowAddress);

        // Record initial balances
        uint256 buyerBalanceBefore = usdc.balanceOf(buyer);
        uint256 sellerBalanceBefore = usdc.balanceOf(seller);
        uint256 arbiterBalanceBefore = usdc.balanceOf(arbiter);

        // Buyer deposits funds
        vm.prank(buyer);
        usdc.approve(address(escrow), AMOUNT);
        vm.prank(buyer);
        escrow.depositFunds();

        // Verify funds went directly to seller (minus fee)
        assertEq(usdc.balanceOf(seller), sellerBalanceBefore + (AMOUNT - CREATOR_FEE));

        // Verify platform got fee
        assertEq(usdc.balanceOf(arbiter), arbiterBalanceBefore + CREATOR_FEE);

        // Verify buyer paid full amount
        assertEq(usdc.balanceOf(buyer), buyerBalanceBefore - AMOUNT);

        // Verify no funds left in escrow
        assertEq(usdc.balanceOf(address(escrow)), 0);

        // Verify state is claimed (4)
        assertTrue(escrow.isClaimed());
        assertTrue(escrow.isFunded()); // State >= 1
    }

    function testInstantTransferCannotDispute() public {
        // Create instant transfer escrow
        vm.prank(arbiter);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            0, // Instant transfer
            description,
            address(0)
        );

        EscrowContract escrow = EscrowContract(escrowAddress);

        // Fund the escrow
        vm.prank(buyer);
        usdc.approve(address(escrow), AMOUNT);
        vm.prank(buyer);
        escrow.depositFunds();

        // Verify cannot dispute
        assertFalse(escrow.canDispute());

        vm.prank(buyer);
        vm.expectRevert(EscrowContract.NotFundedOrAlreadyProcessed.selector);
        escrow.raiseDispute();
    }

    function testInstantTransferCannotDisputeBeforeDeposit() public {
        // Create instant transfer escrow
        vm.prank(arbiter);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            0, // Instant transfer
            description,
            address(0)
        );

        EscrowContract escrow = EscrowContract(escrowAddress);

        // Verify canDispute returns false even before deposit
        assertFalse(escrow.canDispute());

        // Attempt to dispute before deposit should fail
        vm.prank(buyer);
        vm.expectRevert(EscrowContract.NotFundedOrAlreadyProcessed.selector);
        escrow.raiseDispute();
    }

    function testInstantTransferCannotClaim() public {
        // Create instant transfer escrow
        vm.prank(arbiter);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            0, // Instant transfer
            description,
            address(0)
        );

        EscrowContract escrow = EscrowContract(escrowAddress);

        // Fund the escrow
        vm.prank(buyer);
        usdc.approve(address(escrow), AMOUNT);
        vm.prank(buyer);
        escrow.depositFunds();

        // Verify cannot claim (already transferred)
        assertFalse(escrow.canClaim());

        vm.prank(seller);
        vm.expectRevert(EscrowContract.NotFundedOrAlreadyProcessed.selector);
        escrow.claimFunds();
    }

    function testInstantTransferViewFunctions() public {
        // Create instant transfer escrow
        vm.prank(arbiter);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            0, // Instant transfer
            description,
            address(0)
        );

        EscrowContract escrow = EscrowContract(escrowAddress);

        // Before deposit
        assertFalse(escrow.isFunded());
        assertFalse(escrow.isDisputed());
        assertFalse(escrow.isClaimed());
        assertTrue(escrow.canDeposit());
        assertFalse(escrow.canDispute());
        assertFalse(escrow.canClaim());

        // Fund the escrow
        vm.prank(buyer);
        usdc.approve(address(escrow), AMOUNT);
        vm.prank(buyer);
        escrow.depositFunds();

        // After instant transfer
        assertTrue(escrow.isFunded());
        assertFalse(escrow.isDisputed());
        assertTrue(escrow.isClaimed());
        assertFalse(escrow.canDeposit());
        assertFalse(escrow.canDispute());
        assertFalse(escrow.canClaim());
    }

    function testInstantTransferGetContractInfo() public {
        // Create instant transfer escrow
        uint256 creationTime = block.timestamp;
        vm.prank(arbiter);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            0, // Instant transfer
            description,
            address(0)
        );

        EscrowContract escrow = EscrowContract(escrowAddress);

        (
            address _buyer,
            address _seller,
            uint256 _amount,
            uint256 _expiryTimestamp,
            uint8 _currentState,
            uint256 _currentTimestamp,
            uint256 _creatorFee,
            uint256 _createdAt,
            address _tokenAddress
        ) = escrow.getContractInfo();

        // Verify expiry is 0
        assertEq(_expiryTimestamp, 0);

        // Verify other fields
        assertEq(_buyer, buyer);
        assertEq(_seller, seller);
        assertEq(_amount, AMOUNT);
        assertEq(_currentState, 0); // unfunded state
        assertEq(_creatorFee, CREATOR_FEE);
        assertEq(_createdAt, creationTime);

        // Fund the escrow
        vm.prank(buyer);
        usdc.approve(address(escrow), AMOUNT);
        vm.prank(buyer);
        escrow.depositFunds();

        // Check state after deposit
        (, , , , _currentState, , , , ) = escrow.getContractInfo();
        assertEq(_currentState, 4); // claimed state after instant transfer
    }

    function testInstantTransferStateTransitions() public {
        // Create instant transfer escrow
        vm.prank(arbiter);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            0, // Instant transfer
            description,
            address(0)
        );

        EscrowContract escrow = EscrowContract(escrowAddress);

        // Before deposit - state should be 0 (unfunded)
        (, , , , uint8 stateBefore, , , , ) = escrow.getContractInfo();
        assertEq(stateBefore, 0);

        // Fund the escrow
        vm.prank(buyer);
        usdc.approve(address(escrow), AMOUNT);
        vm.prank(buyer);
        escrow.depositFunds();

        // After deposit - state should be 4 (claimed) for instant transfer
        (, , , , uint8 stateAfter, , , , ) = escrow.getContractInfo();
        assertEq(stateAfter, 4);

        // Verify contract is in claimed state
        assertTrue(escrow.isClaimed());
    }

    function testInstantTransferWithZeroFee() public {
        // Create a very small amount contract (below fee threshold)
        uint256 smallAmount = 500; // 0.0005 USDC (below 1/1000 threshold)

        vm.prank(arbiter);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            smallAmount,
            0, // Instant transfer
            description,
            address(0)
        );

        EscrowContract escrow = EscrowContract(escrowAddress);

        // Mint small amount to buyer
        usdc.mint(buyer, smallAmount);

        // Record initial balances
        uint256 sellerBalanceBefore = usdc.balanceOf(seller);

        // Fund the escrow
        vm.prank(buyer);
        usdc.approve(address(escrow), smallAmount);
        vm.prank(buyer);
        escrow.depositFunds();

        // Verify seller got full amount (no fee)
        assertEq(usdc.balanceOf(seller), sellerBalanceBefore + smallAmount);
        assertEq(escrow.CREATOR_FEE(), 0);
    }

    // ========== CHECK AND ACTIVATE TESTS ==========

    function testCheckAndActivateHappyPath() public {
        // Create escrow contract
        vm.prank(arbiter);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            description,
            address(0)
        );
        EscrowContract escrow = EscrowContract(escrowAddress);

        // Buyer transfers USDC directly to the contract address
        vm.prank(buyer);
        usdc.transfer(escrowAddress, AMOUNT);

        // Call checkAndActivate
        escrow.checkAndActivate();

        // Verify state == 1 (funded)
        (,,,,uint8 state,,,,) = escrow.getContractInfo();
        assertEq(state, 1, "Contract should be in funded state");
        assertTrue(escrow.isFunded());
    }

    function testCheckAndActivateInsufficientBalance() public {
        // Create escrow contract
        vm.prank(arbiter);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            description,
            address(0)
        );
        EscrowContract escrow = EscrowContract(escrowAddress);

        // Call checkAndActivate without transferring any tokens
        vm.expectRevert(EscrowContract.InsufficientDirectPayment.selector);
        escrow.checkAndActivate();
    }

    function testCheckAndActivateOverpayment() public {
        // Create escrow contract
        vm.prank(arbiter);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            description,
            address(0)
        );
        EscrowContract escrow = EscrowContract(escrowAddress);

        // Transfer more than AMOUNT to the contract
        uint256 overpayment = AMOUNT + 500 * 10**6; // 500 USDC extra
        usdc.mint(buyer, overpayment);

        vm.prank(buyer);
        usdc.transfer(escrowAddress, overpayment);

        // Call checkAndActivate - should succeed
        escrow.checkAndActivate();

        // Verify state == 1 (funded)
        (,,,,uint8 state,,,,) = escrow.getContractInfo();
        assertEq(state, 1, "Contract should be in funded state");

        // Excess stays in contract (overpayment - CREATOR_FEE = remaining in contract)
        // Contract had overpayment, fee was sent out, so remaining = overpayment - CREATOR_FEE
        assertEq(usdc.balanceOf(escrowAddress), overpayment - CREATOR_FEE);
    }

    function testCheckAndActivateAlreadyFunded() public {
        // Create and fund escrow via normal depositFunds flow
        EscrowContract escrow = createAndFundEscrow();

        // Transfer tokens to contract (even though already funded)
        usdc.mint(buyer, AMOUNT);
        vm.prank(buyer);
        usdc.transfer(address(escrow), AMOUNT);

        // Try checkAndActivate - should revert
        vm.expectRevert(EscrowContract.AlreadyFundedOrClaimed.selector);
        escrow.checkAndActivate();
    }

    function testCheckAndActivateAlreadyActivated() public {
        // Create escrow contract
        vm.prank(arbiter);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            description,
            address(0)
        );
        EscrowContract escrow = EscrowContract(escrowAddress);

        // Transfer tokens and activate
        vm.prank(buyer);
        usdc.transfer(escrowAddress, AMOUNT);
        escrow.checkAndActivate();

        // Mint more tokens and transfer to contract for second attempt
        usdc.mint(buyer, AMOUNT);
        vm.prank(buyer);
        usdc.transfer(escrowAddress, AMOUNT);

        // Try checkAndActivate again - should revert
        vm.expectRevert(EscrowContract.AlreadyFundedOrClaimed.selector);
        escrow.checkAndActivate();
    }

    function testCheckAndActivateInstantTransfer() public {
        // Create instant transfer escrow with expiry=0
        vm.prank(arbiter);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            0, // Instant transfer
            description,
            address(0)
        );
        EscrowContract escrow = EscrowContract(escrowAddress);

        // Record initial balances
        uint256 sellerBalanceBefore = usdc.balanceOf(seller);
        uint256 arbiterBalanceBefore = usdc.balanceOf(arbiter);

        // Transfer tokens directly to contract
        vm.prank(buyer);
        usdc.transfer(escrowAddress, AMOUNT);

        // Call checkAndActivate
        escrow.checkAndActivate();

        // Verify state == 4 (claimed)
        (,,,,uint8 state,,,,) = escrow.getContractInfo();
        assertEq(state, 4, "Contract should be in claimed state for instant transfer");
        assertTrue(escrow.isClaimed());

        // Verify funds went to seller immediately (minus fee)
        assertEq(usdc.balanceOf(seller), sellerBalanceBefore + (AMOUNT - CREATOR_FEE));

        // Verify platform got fee
        assertEq(usdc.balanceOf(arbiter), arbiterBalanceBefore + CREATOR_FEE);

        // Verify no funds left in escrow
        assertEq(usdc.balanceOf(escrowAddress), 0);
    }

    function testCheckAndActivateFeeDistribution() public {
        // Create escrow contract
        vm.prank(arbiter);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            description,
            address(0)
        );
        EscrowContract escrow = EscrowContract(escrowAddress);

        // Record initial balances
        uint256 arbiterBalanceBefore = usdc.balanceOf(arbiter);

        // Transfer tokens directly to contract
        vm.prank(buyer);
        usdc.transfer(escrowAddress, AMOUNT);

        // Call checkAndActivate
        escrow.checkAndActivate();

        // Verify CREATOR_FEE sent to FEE_RECIPIENT (arbiter in this test setup)
        assertEq(usdc.balanceOf(arbiter), arbiterBalanceBefore + CREATOR_FEE);

        // Verify remainder locked in contract
        assertEq(usdc.balanceOf(escrowAddress), AMOUNT - CREATOR_FEE);
    }

    function testCheckAndActivateZeroFee() public {
        // Create a very small amount contract (below fee threshold for no-fee zone)
        uint256 smallAmount = 500; // 0.0005 USDC (below 1/1000 threshold)

        vm.prank(arbiter);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            smallAmount,
            expiryTimestamp,
            description,
            address(0)
        );
        EscrowContract escrow = EscrowContract(escrowAddress);

        // Verify zero fee
        assertEq(escrow.CREATOR_FEE(), 0);

        // Mint and transfer tokens directly to contract
        usdc.mint(buyer, smallAmount);
        vm.prank(buyer);
        usdc.transfer(escrowAddress, smallAmount);

        // Call checkAndActivate
        escrow.checkAndActivate();

        // Verify state == 1 (funded)
        (,,,,uint8 state,,,,) = escrow.getContractInfo();
        assertEq(state, 1, "Contract should be in funded state");

        // Verify all tokens locked in contract (no fee deducted)
        assertEq(usdc.balanceOf(escrowAddress), smallAmount);
    }

    function testCheckAndActivateCallableByAnyone() public {
        // Create escrow contract
        vm.prank(arbiter);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            description,
            address(0)
        );
        EscrowContract escrow = EscrowContract(escrowAddress);

        // Transfer tokens directly to contract
        vm.prank(buyer);
        usdc.transfer(escrowAddress, AMOUNT);

        // Call checkAndActivate from a random address (not buyer, seller, or arbiter)
        address randomCaller = address(0x999);
        vm.prank(randomCaller);
        escrow.checkAndActivate();

        // Verify it succeeded
        (,,,,uint8 state,,,,) = escrow.getContractInfo();
        assertEq(state, 1, "Contract should be in funded state");
        assertTrue(escrow.isFunded());
    }

    function testCheckAndActivateThenDispute() public {
        // Create escrow contract
        vm.prank(arbiter);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            description,
            address(0)
        );
        EscrowContract escrow = EscrowContract(escrowAddress);

        // Transfer tokens and activate
        vm.prank(buyer);
        usdc.transfer(escrowAddress, AMOUNT);
        escrow.checkAndActivate();

        // Verify funded state
        assertTrue(escrow.isFunded());
        assertTrue(escrow.canDispute());

        // Buyer raises dispute
        vm.prank(buyer);
        escrow.raiseDispute();

        // Verify disputed state
        assertTrue(escrow.isDisputed());
        assertFalse(escrow.canClaim());
        assertFalse(escrow.canDispute());
    }

    function testCheckAndActivateThenClaim() public {
        // Create escrow contract
        vm.prank(arbiter);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            description,
            address(0)
        );
        EscrowContract escrow = EscrowContract(escrowAddress);

        // Transfer tokens and activate
        vm.prank(buyer);
        usdc.transfer(escrowAddress, AMOUNT);
        escrow.checkAndActivate();

        // Warp past expiry
        vm.warp(expiryTimestamp + 1);

        // Record seller balance before claim
        uint256 sellerBalanceBefore = usdc.balanceOf(seller);

        // Seller claims funds
        vm.prank(seller);
        escrow.claimFunds();

        // Verify claimed state
        assertTrue(escrow.isClaimed());
        assertEq(usdc.balanceOf(seller), sellerBalanceBefore + (AMOUNT - CREATOR_FEE));
        assertEq(usdc.balanceOf(escrowAddress), 0);
    }

    function testDepositFundsStillWorks() public {
        // Verify existing approve+deposit flow still works unchanged after adding checkAndActivate
        vm.prank(arbiter);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            description,
            address(0)
        );
        EscrowContract escrow = EscrowContract(escrowAddress);

        uint256 buyerBalanceBefore = usdc.balanceOf(buyer);
        uint256 arbiterBalanceBefore = usdc.balanceOf(arbiter);

        // Standard approve+deposit flow
        vm.prank(buyer);
        usdc.approve(address(escrow), AMOUNT);
        vm.prank(buyer);
        escrow.depositFunds();

        // Verify everything works as before
        assertTrue(escrow.isFunded());
        assertEq(usdc.balanceOf(buyer), buyerBalanceBefore - AMOUNT);
        assertEq(usdc.balanceOf(arbiter), arbiterBalanceBefore + CREATOR_FEE);
        assertEq(usdc.balanceOf(escrowAddress), AMOUNT - CREATOR_FEE);

        // Verify full lifecycle still works
        vm.warp(expiryTimestamp + 1);
        uint256 sellerBalanceBefore = usdc.balanceOf(seller);
        vm.prank(seller);
        escrow.claimFunds();
        assertEq(usdc.balanceOf(seller), sellerBalanceBefore + (AMOUNT - CREATOR_FEE));
    }

    function testPartialPaymentThenTopUp() public {
        // Create escrow contract
        vm.prank(arbiter);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            description,
            address(0)
        );
        EscrowContract escrow = EscrowContract(escrowAddress);

        // Send partial amount
        uint256 partialAmount = AMOUNT / 2;
        vm.prank(buyer);
        usdc.transfer(escrowAddress, partialAmount);

        // checkAndActivate should fail with partial payment
        vm.expectRevert(EscrowContract.InsufficientDirectPayment.selector);
        escrow.checkAndActivate();

        // Verify contract is still unfunded
        assertFalse(escrow.isFunded());

        // Send remaining amount to reach full AMOUNT
        uint256 remaining = AMOUNT - partialAmount;
        vm.prank(buyer);
        usdc.transfer(escrowAddress, remaining);

        // checkAndActivate should now succeed
        escrow.checkAndActivate();

        // Verify contract is now funded
        (,,,,uint8 state,,,,) = escrow.getContractInfo();
        assertEq(state, 1, "Contract should be in funded state after top-up");
        assertTrue(escrow.isFunded());
    }

    // ═══════════════════════════════════════════════════════════════
    //  SWEEP TOKEN TESTS
    // ═══════════════════════════════════════════════════════════════

    function createUnfundedEscrow() internal returns (EscrowContract) {
        vm.prank(arbiter);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            description,
            address(0)
        );
        EscrowContract escrow = EscrowContract(escrowAddress);

        // Approve so depositFunds can be called later if needed
        vm.prank(buyer);
        usdc.approve(address(escrow), AMOUNT);

        return escrow;
    }

    function testSweepTokenByBuyer() public {
        EscrowContract escrow = createUnfundedEscrow();

        // Deploy a different token and send it to the escrow by mistake
        MockERC20 wrongToken = new MockERC20();
        uint256 wrongAmount = 500 * 10**6;
        wrongToken.transfer(address(escrow), wrongAmount);

        uint256 buyerBalanceBefore = wrongToken.balanceOf(buyer);

        // Buyer sweeps the wrong token
        vm.prank(buyer);
        escrow.sweepToken(address(wrongToken));

        assertEq(wrongToken.balanceOf(address(escrow)), 0, "Escrow should have 0 wrong tokens");
        assertEq(wrongToken.balanceOf(buyer), buyerBalanceBefore + wrongAmount, "Buyer should receive swept tokens");
    }

    function testSweepTokenByArbiter() public {
        EscrowContract escrow = createUnfundedEscrow();

        MockERC20 wrongToken = new MockERC20();
        uint256 wrongAmount = 500 * 10**6;
        wrongToken.transfer(address(escrow), wrongAmount);

        uint256 buyerBalanceBefore = wrongToken.balanceOf(buyer);

        // Arbiter sweeps the wrong token — funds still go to buyer
        vm.prank(arbiter);
        escrow.sweepToken(address(wrongToken));

        assertEq(wrongToken.balanceOf(address(escrow)), 0);
        assertEq(wrongToken.balanceOf(buyer), buyerBalanceBefore + wrongAmount, "Buyer should receive swept tokens");
    }

    function testSweepTokenCannotSweepEscrowToken() public {
        EscrowContract escrow = createUnfundedEscrow();

        // Fund the escrow normally
        vm.prank(buyer);
        escrow.depositFunds();

        // Try to sweep the escrow token — should revert
        vm.prank(buyer);
        vm.expectRevert(EscrowContract.CannotSweepEscrowToken.selector);
        escrow.sweepToken(address(usdc));
    }

    function testSweepTokenNoTokensToSweep() public {
        EscrowContract escrow = createUnfundedEscrow();

        MockERC20 wrongToken = new MockERC20();

        // Try to sweep when there's nothing there
        vm.prank(buyer);
        vm.expectRevert(EscrowContract.NoTokensToSweep.selector);
        escrow.sweepToken(address(wrongToken));
    }

    function testSweepTokenCallableByAnyone() public {
        EscrowContract escrow = createUnfundedEscrow();

        MockERC20 wrongToken = new MockERC20();
        uint256 wrongAmount = 100;
        wrongToken.transfer(address(escrow), wrongAmount);

        uint256 buyerBalanceBefore = wrongToken.balanceOf(buyer);

        // Random address can sweep; funds still go to buyer
        vm.prank(other);
        escrow.sweepToken(address(wrongToken));

        assertEq(wrongToken.balanceOf(address(escrow)), 0);
        assertEq(wrongToken.balanceOf(buyer), buyerBalanceBefore + wrongAmount);
    }

    function testSweepTokenEmitsEvent() public {
        EscrowContract escrow = createUnfundedEscrow();

        MockERC20 wrongToken = new MockERC20();
        uint256 wrongAmount = 200 * 10**6;
        wrongToken.transfer(address(escrow), wrongAmount);

        vm.prank(buyer);
        vm.expectEmit(true, true, false, true);
        emit EscrowContract.TokensSwept(address(wrongToken), buyer, wrongAmount);
        escrow.sweepToken(address(wrongToken));
    }

    function testSweepTokenWhileEscrowFunded() public {
        EscrowContract escrow = createUnfundedEscrow();

        // Fund the escrow normally
        vm.prank(buyer);
        escrow.depositFunds();

        // Send a wrong token to the funded escrow
        MockERC20 wrongToken = new MockERC20();
        uint256 wrongAmount = 300 * 10**6;
        wrongToken.transfer(address(escrow), wrongAmount);

        // Should still be able to sweep the wrong token
        vm.prank(buyer);
        escrow.sweepToken(address(wrongToken));

        assertEq(wrongToken.balanceOf(address(escrow)), 0);
        assertEq(wrongToken.balanceOf(buyer), wrongAmount);

        // Escrow token should be untouched
        assertTrue(escrow.isFunded());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // changeRecipient — seller reassigns their payout right (state 1 only)
    // ═══════════════════════════════════════════════════════════════════════════

    event RecipientChanged(address indexed previousSeller, address indexed newSeller, uint256 timestamp);

    function testChangeRecipientHappyPath() public {
        EscrowContract escrow = createAndFundEscrow();

        vm.expectEmit(true, true, false, true, address(escrow));
        emit RecipientChanged(seller, other, block.timestamp);

        vm.prank(seller);
        escrow.changeRecipient(other);

        assertEq(escrow.SELLER(), other);
        assertEq(escrow.recipient(), other);
        // State is untouched by the reassignment
        assertTrue(escrow.isFunded());
    }

    function testChangeRecipientOnlySeller() public {
        EscrowContract escrow = createAndFundEscrow();

        vm.prank(buyer);
        vm.expectRevert(EscrowContract.OnlySeller.selector);
        escrow.changeRecipient(other);

        vm.prank(arbiter);
        vm.expectRevert(EscrowContract.OnlySeller.selector);
        escrow.changeRecipient(other);

        vm.prank(other);
        vm.expectRevert(EscrowContract.OnlySeller.selector);
        escrow.changeRecipient(other);

        // Seller remains unchanged after all failed attempts
        assertEq(escrow.SELLER(), seller);
    }

    function testChangeRecipientRejectsZeroAddress() public {
        EscrowContract escrow = createAndFundEscrow();

        vm.prank(seller);
        vm.expectRevert(EscrowContract.InvalidSellerAddress.selector);
        escrow.changeRecipient(address(0));
    }

    function testChangeRecipientRejectsBuyer() public {
        EscrowContract escrow = createAndFundEscrow();

        vm.prank(seller);
        vm.expectRevert(EscrowContract.BuyerSellerMustBeDifferent.selector);
        escrow.changeRecipient(buyer);
    }

    function testChangeRecipientRejectsArbiter() public {
        EscrowContract escrow = createAndFundEscrow();

        // Reassigning to the arbiter would collapse 2-of-3 votes into one address
        vm.prank(seller);
        vm.expectRevert(EscrowContract.ArbiterMustBeDistinct.selector);
        escrow.changeRecipient(arbiter);
    }

    function testChangeRecipientRejectedWhenUnfunded() public {
        EscrowContract escrow = createUnfundedEscrow();

        vm.prank(seller);
        vm.expectRevert(EscrowContract.NotFundedOrAlreadyProcessed.selector);
        escrow.changeRecipient(other);
    }

    function testChangeRecipientRejectedWhenDisputed() public {
        EscrowContract escrow = createAndFundEscrow();

        vm.prank(buyer);
        escrow.raiseDispute();

        vm.prank(seller);
        vm.expectRevert(EscrowContract.NotFundedOrAlreadyProcessed.selector);
        escrow.changeRecipient(other);
    }

    function testChangeRecipientRejectedWhenClaimed() public {
        EscrowContract escrow = createAndFundEscrow();

        vm.warp(expiryTimestamp + 1);
        vm.prank(seller);
        escrow.claimFunds();

        vm.prank(seller);
        vm.expectRevert(EscrowContract.NotFundedOrAlreadyProcessed.selector);
        escrow.changeRecipient(other);
    }

    function testChangeRecipientNewSellerReceivesFundsOnClaim() public {
        EscrowContract escrow = createAndFundEscrow();

        vm.prank(seller);
        escrow.changeRecipient(other);

        vm.warp(expiryTimestamp + 1);

        uint256 oldSellerBefore = usdc.balanceOf(seller);
        uint256 newSellerBefore = usdc.balanceOf(other);

        vm.prank(other);
        escrow.claimFunds();

        // Funds go to the new recipient, not the original seller
        assertEq(usdc.balanceOf(seller), oldSellerBefore);
        assertEq(usdc.balanceOf(other), newSellerBefore + (AMOUNT - CREATOR_FEE));
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function testChangeRecipientTransfersVotingRights() public {
        EscrowContract escrow = createAndFundEscrow();

        vm.prank(seller);
        escrow.changeRecipient(other);

        vm.prank(buyer);
        escrow.raiseDispute();

        // Original seller is no longer an authorized voter
        vm.prank(seller);
        vm.expectRevert(EscrowContract.NotAuthorizedToVote.selector);
        escrow.submitResolutionVote(50);

        // New recipient votes as the seller party; consensus with buyer pays new recipient
        uint256 newSellerBefore = usdc.balanceOf(other);

        vm.prank(buyer);
        escrow.submitResolutionVote(0); // 0% to buyer => 100% to seller party

        vm.prank(other);
        escrow.submitResolutionVote(0);

        assertTrue(escrow.consensusReached());
        assertEq(usdc.balanceOf(other), newSellerBefore + (AMOUNT - CREATOR_FEE));
    }

    // Regression: a reassigned seller must NOT be counted as having voted 0% by
    // default. Without the explicit `= 255` in changeRecipient, the new seller's
    // default mapping value (0) would collude with an arbiter 0-vote to force a
    // false consensus paying the seller 100%.
    function testChangeRecipientNewSellerNotCountedAsVoted() public {
        EscrowContract escrow = createAndFundEscrow();

        vm.prank(seller);
        escrow.changeRecipient(other);

        vm.prank(buyer);
        escrow.raiseDispute();

        // Only the arbiter votes 0. If the new seller defaulted to "voted 0%",
        // this would reach seller+arbiter consensus. It must not.
        vm.prank(arbiter);
        escrow.submitResolutionVote(0);

        assertFalse(escrow.consensusReached());
        assertTrue(escrow.isDisputed());
        assertEq(usdc.balanceOf(address(escrow)), AMOUNT - CREATOR_FEE);

        // New seller can then genuinely vote to complete the 2-of-3
        vm.prank(other);
        escrow.submitResolutionVote(0);
        assertTrue(escrow.consensusReached());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Arbiter must be an independent third party (2-of-3 vote integrity)
    // ═══════════════════════════════════════════════════════════════════════════

    function testFactoryRejectsArbiterEqualsBuyer() public {
        vm.prank(arbiter);
        vm.expectRevert(EscrowContractFactory.ArbiterMustBeDistinct.selector);
        factory.createEscrowContract(
            address(usdc), buyer, seller, AMOUNT, expiryTimestamp, description, buyer
        );
    }

    function testFactoryRejectsArbiterEqualsSeller() public {
        vm.prank(arbiter);
        vm.expectRevert(EscrowContractFactory.ArbiterMustBeDistinct.selector);
        factory.createEscrowContract(
            address(usdc), buyer, seller, AMOUNT, expiryTimestamp, description, seller
        );
    }

    // Pins the initialize-level guard independently of the factory's own check
    // (defense in depth): a raw clone initialized with a colliding arbiter must
    // revert even if the factory guard were ever bypassed or removed.
    function testInitializeRejectsArbiterEqualsBuyerOrSeller() public {
        EscrowContract impl = new EscrowContract();

        address cloneA = Clones.clone(address(impl));
        vm.expectRevert(EscrowContract.ArbiterMustBeDistinct.selector);
        EscrowContract(cloneA).initialize(
            address(usdc), buyer, seller, buyer, AMOUNT, expiryTimestamp, 0, arbiter
        );

        address cloneB = Clones.clone(address(impl));
        vm.expectRevert(EscrowContract.ArbiterMustBeDistinct.selector);
        EscrowContract(cloneB).initialize(
            address(usdc), buyer, seller, seller, AMOUNT, expiryTimestamp, 0, arbiter
        );
    }

    function testInitializeRejectsZeroFeeRecipient() public {
        EscrowContract impl = new EscrowContract();
        address clone = Clones.clone(address(impl));
        vm.expectRevert(EscrowContract.InvalidFeeRecipientAddress.selector);
        EscrowContract(clone).initialize(
            address(usdc), buyer, seller, arbiter, AMOUNT, expiryTimestamp, 0, address(0)
        );
    }

    function testFactoryRejectsCreatorDefaultingSelfAsArbiter() public {
        // Buyer creates their own escrow without specifying an arbiter; the default
        // (msg.sender == buyer) must be rejected rather than granting them 2 votes.
        vm.prank(buyer);
        vm.expectRevert(EscrowContractFactory.ArbiterMustBeDistinct.selector);
        factory.createEscrowContract(
            address(usdc), buyer, seller, AMOUNT, expiryTimestamp, description, address(0)
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Token safety: fee-on-transfer rejection and missing decimals() tolerance
    // ═══════════════════════════════════════════════════════════════════════════

    function testDepositRejectsFeeOnTransferToken() public {
        FeeOnTransferERC20 feeToken = new FeeOnTransferERC20();
        feeToken.mint(buyer, AMOUNT * 10);

        vm.prank(arbiter);
        address esc = factory.createEscrowContract(
            address(feeToken), buyer, seller, AMOUNT, expiryTimestamp, description, arbiter
        );
        EscrowContract escrow = EscrowContract(esc);

        vm.prank(buyer);
        feeToken.approve(esc, AMOUNT);

        // The contract would receive less than AMOUNT; deposit must reject the token
        // rather than under-fund the escrow and lock later payouts.
        vm.prank(buyer);
        vm.expectRevert(EscrowContract.TransferAmountMismatch.selector);
        escrow.depositFunds();
    }

    function testFactoryToleratesTokenWithoutDecimals() public {
        NoDecimalsERC20 noDec = new NoDecimalsERC20();
        // Large enough to clear the 18-decimal fallback minimum fee.
        uint256 bigAmount = 1000 ether;
        noDec.mint(buyer, bigAmount * 2);

        // Creation must not revert just because decimals() is absent.
        vm.prank(arbiter);
        address esc = factory.createEscrowContract(
            address(noDec), buyer, seller, bigAmount, expiryTimestamp, description, arbiter
        );
        assertTrue(esc != address(0));

        // And the resulting escrow is fully usable (funds cleanly).
        vm.prank(buyer);
        noDec.approve(esc, bigAmount);
        vm.prank(buyer);
        EscrowContract(esc).depositFunds();
        assertTrue(EscrowContract(esc).isFunded());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MarketplaceEscrow integration adapter views
    // ═══════════════════════════════════════════════════════════════════════════

    function testAdapterViews() public {
        EscrowContract escrow = createAndFundEscrow();

        assertEq(escrow.recipient(), seller);
        assertEq(escrow.maturity(), expiryTimestamp);
        assertEq(escrow.token(), address(usdc));
        assertEq(escrow.payoutAmount(), AMOUNT - CREATOR_FEE);
        assertFalse(escrow.hasActiveDispute());
    }

    function testAdapterHasActiveDisputeReflectsState() public {
        EscrowContract escrow = createAndFundEscrow();
        assertFalse(escrow.hasActiveDispute());

        vm.prank(buyer);
        escrow.raiseDispute();
        assertTrue(escrow.hasActiveDispute());

        // Resolve and confirm it clears
        vm.prank(buyer);
        escrow.submitResolutionVote(100);
        vm.prank(arbiter);
        escrow.submitResolutionVote(100);
        assertFalse(escrow.hasActiveDispute());
        assertTrue(escrow.isClaimed());
    }

    function testAdapterRecipientReflectsReassignment() public {
        EscrowContract escrow = createAndFundEscrow();
        assertEq(escrow.recipient(), seller);

        vm.prank(seller);
        escrow.changeRecipient(other);
        assertEq(escrow.recipient(), other);
    }

    function testAdapterViewsRevertBeforeInit() public {
        EscrowContract implementation = new EscrowContract();

        vm.expectRevert(EscrowContract.NotInitialized.selector);
        implementation.recipient();

        vm.expectRevert(EscrowContract.NotInitialized.selector);
        implementation.maturity();

        vm.expectRevert(EscrowContract.NotInitialized.selector);
        implementation.hasActiveDispute();

        vm.expectRevert(EscrowContract.NotInitialized.selector);
        implementation.token();

        vm.expectRevert(EscrowContract.NotInitialized.selector);
        implementation.payoutAmount();
    }
}