// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

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
    uint256 public CREATOR_FEE; // Will be calculated as 1% of AMOUNT
    uint256 public expiryTimestamp;
    string public description = "Test escrow transaction";
    
    function setUp() public {
        usdc = new MockERC20();
        EscrowContract implementation = new EscrowContract();
        factory = new EscrowContractFactory(gasPayer, address(implementation), address(0));
        
        expiryTimestamp = block.timestamp + 7 days;
        
        // Calculate expected fee: 1% of AMOUNT (since 1% > minimum of 300,000)
        CREATOR_FEE = AMOUNT / 100; // 10 USDC (1% of 1000 USDC)
        
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
            address(usdc),
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
        vm.expectRevert(EscrowContract.NotInitialized.selector);
        implementation.isFunded();
        
        // Test cloned contract initialization
        EscrowContract testEscrow = createAndFundEscrow();
        
        // Verify all parameters were set correctly
        assertEq(address(testEscrow.tokenAddress()), address(usdc));
        assertEq(testEscrow.BUYER(), buyer);
        assertEq(testEscrow.SELLER(), seller);
        assertEq(testEscrow.GAS_PAYER(), gasPayer);
        assertEq(testEscrow.AMOUNT(), AMOUNT);
        assertEq(testEscrow.EXPIRY_TIMESTAMP(), expiryTimestamp);
        // Description no longer stored in contract (emitted in events only to save gas)
    }
    
    function testSuccessfulDeployment() public {
        uint256 deploymentTime = block.timestamp;
        
        vm.prank(gasPayer);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            description
        );
        
        EscrowContract escrow = EscrowContract(escrowAddress);
        
        assertEq(address(escrow.tokenAddress()), address(usdc));
        assertEq(escrow.BUYER(), buyer);
        assertEq(escrow.SELLER(), seller);
        assertEq(escrow.GAS_PAYER(), gasPayer);
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
        
        vm.prank(gasPayer);
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

        vm.prank(gasPayer);
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

        vm.prank(gasPayer);
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
    
    function testGasPayerCanClaimFunds() public {
        EscrowContract escrow = createAndFundEscrow();
        
        vm.warp(expiryTimestamp + 1);
        
        uint256 sellerBalanceBefore = usdc.balanceOf(seller);
        
        vm.prank(gasPayer);
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
        
        vm.prank(gasPayer);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            description
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
        vm.prank(gasPayer);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
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
        vm.prank(gasPayer);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            description
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
        vm.prank(gasPayer);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            description
        );
        EscrowContract escrow = EscrowContract(escrowAddress);
        
        vm.prank(buyer);
        vm.expectRevert(EscrowContract.NotFundedOrAlreadyProcessed.selector);
        escrow.raiseDispute();
        
        vm.warp(expiryTimestamp + 1);
        
        vm.prank(seller);
        vm.expectRevert(EscrowContract.NotFundedOrAlreadyProcessed.selector);
        escrow.claimFunds();
        
        vm.prank(gasPayer);
        vm.expectRevert(EscrowContract.ContractMustBeDisputed.selector);
        escrow.submitResolutionVote(100);
    }
    
    
    
    
    function testCreatorFeeTransferOnDeposit() public {
        vm.prank(gasPayer);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            description
        );
        
        EscrowContract escrow = EscrowContract(escrowAddress);
        
        // Record initial balances
        uint256 initialGasPayerBalance = usdc.balanceOf(gasPayer);
        uint256 initialBuyerBalance = usdc.balanceOf(buyer);
        
        // Buyer approves and funds the escrow
        vm.prank(buyer);
        usdc.approve(address(escrow), AMOUNT);
        
        vm.prank(buyer);
        escrow.depositFunds();
        
        // Check that creator fee was transferred to gas payer
        assertEq(usdc.balanceOf(gasPayer), initialGasPayerBalance + CREATOR_FEE);
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

        vm.prank(gasPayer);
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

        vm.prank(gasPayer);
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
        vm.prank(gasPayer);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            0, // Instant transfer - expiry = 0
            description
        );

        EscrowContract escrow = EscrowContract(escrowAddress);

        // Record initial balances
        uint256 buyerBalanceBefore = usdc.balanceOf(buyer);
        uint256 sellerBalanceBefore = usdc.balanceOf(seller);
        uint256 gasPayerBalanceBefore = usdc.balanceOf(gasPayer);

        // Buyer deposits funds
        vm.prank(buyer);
        usdc.approve(address(escrow), AMOUNT);
        vm.prank(buyer);
        escrow.depositFunds();

        // Verify funds went directly to seller (minus fee)
        assertEq(usdc.balanceOf(seller), sellerBalanceBefore + (AMOUNT - CREATOR_FEE));

        // Verify platform got fee
        assertEq(usdc.balanceOf(gasPayer), gasPayerBalanceBefore + CREATOR_FEE);

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
        vm.prank(gasPayer);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            0, // Instant transfer
            description
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
        vm.prank(gasPayer);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            0, // Instant transfer
            description
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
        vm.prank(gasPayer);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            0, // Instant transfer
            description
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
        vm.prank(gasPayer);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            0, // Instant transfer
            description
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
        vm.prank(gasPayer);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            0, // Instant transfer
            description
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
        vm.prank(gasPayer);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            0, // Instant transfer
            description
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

        vm.prank(gasPayer);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            smallAmount,
            0, // Instant transfer
            description
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
        vm.prank(gasPayer);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            description
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
        vm.prank(gasPayer);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            description
        );
        EscrowContract escrow = EscrowContract(escrowAddress);

        // Call checkAndActivate without transferring any tokens
        vm.expectRevert(EscrowContract.InsufficientDirectPayment.selector);
        escrow.checkAndActivate();
    }

    function testCheckAndActivateOverpayment() public {
        // Create escrow contract
        vm.prank(gasPayer);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            description
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
        vm.prank(gasPayer);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            description
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
        vm.prank(gasPayer);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            0, // Instant transfer
            description
        );
        EscrowContract escrow = EscrowContract(escrowAddress);

        // Record initial balances
        uint256 sellerBalanceBefore = usdc.balanceOf(seller);
        uint256 gasPayerBalanceBefore = usdc.balanceOf(gasPayer);

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
        assertEq(usdc.balanceOf(gasPayer), gasPayerBalanceBefore + CREATOR_FEE);

        // Verify no funds left in escrow
        assertEq(usdc.balanceOf(escrowAddress), 0);
    }

    function testCheckAndActivateFeeDistribution() public {
        // Create escrow contract
        vm.prank(gasPayer);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            description
        );
        EscrowContract escrow = EscrowContract(escrowAddress);

        // Record initial balances
        uint256 gasPayerBalanceBefore = usdc.balanceOf(gasPayer);

        // Transfer tokens directly to contract
        vm.prank(buyer);
        usdc.transfer(escrowAddress, AMOUNT);

        // Call checkAndActivate
        escrow.checkAndActivate();

        // Verify CREATOR_FEE sent to FEE_RECIPIENT (gasPayer in this test setup)
        assertEq(usdc.balanceOf(gasPayer), gasPayerBalanceBefore + CREATOR_FEE);

        // Verify remainder locked in contract
        assertEq(usdc.balanceOf(escrowAddress), AMOUNT - CREATOR_FEE);
    }

    function testCheckAndActivateZeroFee() public {
        // Create a very small amount contract (below fee threshold for no-fee zone)
        uint256 smallAmount = 500; // 0.0005 USDC (below 1/1000 threshold)

        vm.prank(gasPayer);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            smallAmount,
            expiryTimestamp,
            description
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
        vm.prank(gasPayer);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            description
        );
        EscrowContract escrow = EscrowContract(escrowAddress);

        // Transfer tokens directly to contract
        vm.prank(buyer);
        usdc.transfer(escrowAddress, AMOUNT);

        // Call checkAndActivate from a random address (not buyer, seller, or gasPayer)
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
        vm.prank(gasPayer);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            description
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
        vm.prank(gasPayer);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            description
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
        vm.prank(gasPayer);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            description
        );
        EscrowContract escrow = EscrowContract(escrowAddress);

        uint256 buyerBalanceBefore = usdc.balanceOf(buyer);
        uint256 gasPayerBalanceBefore = usdc.balanceOf(gasPayer);

        // Standard approve+deposit flow
        vm.prank(buyer);
        usdc.approve(address(escrow), AMOUNT);
        vm.prank(buyer);
        escrow.depositFunds();

        // Verify everything works as before
        assertTrue(escrow.isFunded());
        assertEq(usdc.balanceOf(buyer), buyerBalanceBefore - AMOUNT);
        assertEq(usdc.balanceOf(gasPayer), gasPayerBalanceBefore + CREATOR_FEE);
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
        vm.prank(gasPayer);
        address escrowAddress = factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            description
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
}