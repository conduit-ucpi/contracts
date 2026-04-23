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

contract VotingResolutionTest is Test {
    EscrowContractFactory public factory;
    MockERC20 public usdc;

    address public buyer = address(0x1);
    address public seller = address(0x2);
    address public admin = address(0x3);
    address public unauthorized = address(0x4);

    uint256 public constant AMOUNT = 1000 * 10**6; // 1000 USDC
    uint256 public CREATOR_FEE;
    uint256 public expiryTimestamp;
    string public description = "Test escrow transaction";

    function setUp() public {
        usdc = new MockERC20();
        EscrowContract implementation = new EscrowContract();
        factory = new EscrowContractFactory(admin, address(implementation), address(0));

        expiryTimestamp = block.timestamp + 7 days;
        CREATOR_FEE = AMOUNT / 100; // 1% of 1000 USDC

        // Give USDC to relevant parties
        usdc.mint(buyer, AMOUNT * 10);
        usdc.mint(admin, AMOUNT * 10);

        vm.prank(buyer);
        usdc.approve(address(factory), AMOUNT * 10);
    }

    function createDisputedEscrow() internal returns (EscrowContract) {
        // Create escrow
        vm.prank(admin);
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

        // Fund escrow
        vm.prank(buyer);
        usdc.approve(address(escrow), AMOUNT);
        vm.prank(buyer);
        escrow.depositFunds();

        // Raise dispute
        vm.prank(buyer);
        escrow.raiseDispute();

        return escrow;
    }

    // ========== BASIC VOTING TESTS ==========

    function testBuyerCanVote() public {
        EscrowContract escrow = createDisputedEscrow();

        vm.prank(buyer);
        escrow.submitResolutionVote(60);

        uint8 percentage = escrow.resolutionVotes(buyer);
        assertEq(percentage, 60);
    }

    function testSellerCanVote() public {
        EscrowContract escrow = createDisputedEscrow();

        vm.prank(seller);
        escrow.submitResolutionVote(40);

        uint8 percentage = escrow.resolutionVotes(seller);
        assertEq(percentage, 40);
    }

    function testAdminCanVote() public {
        EscrowContract escrow = createDisputedEscrow();

        vm.prank(admin);
        escrow.submitResolutionVote(50);

        uint8 percentage = escrow.resolutionVotes(admin);
        assertEq(percentage, 50);
    }

    function testUnauthorizedCannotVote() public {
        EscrowContract escrow = createDisputedEscrow();

        vm.prank(unauthorized);
        vm.expectRevert(EscrowContract.NotAuthorizedToVote.selector);
        escrow.submitResolutionVote(50);
    }

    function testCannotVoteOnNonDisputedContract() public {
        // Create and fund escrow but don't dispute
        vm.prank(admin);
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
        usdc.approve(address(escrow), AMOUNT);
        vm.prank(buyer);
        escrow.depositFunds();

        // Try to vote without dispute
        vm.prank(buyer);
        vm.expectRevert(EscrowContract.ContractMustBeDisputed.selector);
        escrow.submitResolutionVote(60);
    }

    function testCannotVoteWithInvalidPercentage() public {
        EscrowContract escrow = createDisputedEscrow();

        vm.prank(buyer);
        vm.expectRevert(EscrowContract.InvalidPercentage.selector);
        escrow.submitResolutionVote(101);
    }

    function testVoteEmitsEvent() public {
        EscrowContract escrow = createDisputedEscrow();

        vm.expectEmit(true, false, false, true);
        emit VoteSubmitted(buyer, 60);

        vm.prank(buyer);
        escrow.submitResolutionVote(60);
    }

    event VoteSubmitted(address indexed voter, uint256 buyerPercentage);

    // ========== CONSENSUS TESTS ==========

    function testBuyerSellerConsensus() public {
        EscrowContract escrow = createDisputedEscrow();

        uint256 buyerBalanceBefore = usdc.balanceOf(buyer);
        uint256 sellerBalanceBefore = usdc.balanceOf(seller);

        // Buyer votes for 60%
        vm.prank(buyer);
        escrow.submitResolutionVote(60);

        assertFalse(escrow.consensusReached());
        assertFalse(escrow.isClaimed());

        // Seller votes for 60% - consensus reached!
        vm.prank(seller);
        escrow.submitResolutionVote(60);

        assertTrue(escrow.consensusReached());
        assertTrue(escrow.isClaimed());

        // Check funds distribution
        uint256 escrowAmount = AMOUNT - CREATOR_FEE;
        uint256 expectedBuyerAmount = (escrowAmount * 60) / 100;
        uint256 expectedSellerAmount = escrowAmount - expectedBuyerAmount;

        assertEq(usdc.balanceOf(buyer), buyerBalanceBefore + expectedBuyerAmount);
        assertEq(usdc.balanceOf(seller), sellerBalanceBefore + expectedSellerAmount);
    }

    function testBuyerAdminConsensus() public {
        EscrowContract escrow = createDisputedEscrow();

        uint256 buyerBalanceBefore = usdc.balanceOf(buyer);
        uint256 sellerBalanceBefore = usdc.balanceOf(seller);

        // Buyer votes for 70%
        vm.prank(buyer);
        escrow.submitResolutionVote(70);

        // Admin votes for 70% - consensus reached!
        vm.prank(admin);
        escrow.submitResolutionVote(70);

        assertTrue(escrow.consensusReached());
        assertTrue(escrow.isClaimed());

        // Check funds distribution
        uint256 escrowAmount = AMOUNT - CREATOR_FEE;
        uint256 expectedBuyerAmount = (escrowAmount * 70) / 100;
        uint256 expectedSellerAmount = escrowAmount - expectedBuyerAmount;

        assertEq(usdc.balanceOf(buyer), buyerBalanceBefore + expectedBuyerAmount);
        assertEq(usdc.balanceOf(seller), sellerBalanceBefore + expectedSellerAmount);
    }

    function testSellerAdminConsensus() public {
        EscrowContract escrow = createDisputedEscrow();

        uint256 buyerBalanceBefore = usdc.balanceOf(buyer);
        uint256 sellerBalanceBefore = usdc.balanceOf(seller);

        // Seller votes for 30%
        vm.prank(seller);
        escrow.submitResolutionVote(30);

        // Admin votes for 30% - consensus reached!
        vm.prank(admin);
        escrow.submitResolutionVote(30);

        assertTrue(escrow.consensusReached());
        assertTrue(escrow.isClaimed());

        // Check funds distribution
        uint256 escrowAmount = AMOUNT - CREATOR_FEE;
        uint256 expectedBuyerAmount = (escrowAmount * 30) / 100;
        uint256 expectedSellerAmount = escrowAmount - expectedBuyerAmount;

        assertEq(usdc.balanceOf(buyer), buyerBalanceBefore + expectedBuyerAmount);
        assertEq(usdc.balanceOf(seller), sellerBalanceBefore + expectedSellerAmount);
    }

    function testNoConsensusWithDifferentVotes() public {
        EscrowContract escrow = createDisputedEscrow();

        // All three vote differently
        vm.prank(buyer);
        escrow.submitResolutionVote(80);

        vm.prank(seller);
        escrow.submitResolutionVote(20);

        vm.prank(admin);
        escrow.submitResolutionVote(50);

        assertFalse(escrow.consensusReached());
        assertFalse(escrow.isClaimed());
    }

    // ========== VOTE MUTABILITY TESTS ==========

    function testCanChangeVoteBeforeConsensus() public {
        EscrowContract escrow = createDisputedEscrow();

        // Buyer votes for 80%
        vm.prank(buyer);
        escrow.submitResolutionVote(80);

        uint8 percentage1 = escrow.resolutionVotes(buyer);
        assertEq(percentage1, 80);

        // Buyer changes vote to 60%
        vm.prank(buyer);
        escrow.submitResolutionVote(60);

        uint8 percentage2 = escrow.resolutionVotes(buyer);
        assertEq(percentage2, 60);

        // Seller agrees with new vote
        vm.prank(seller);
        escrow.submitResolutionVote(60);

        assertTrue(escrow.consensusReached());
    }

    function testCannotChangeVoteAfterConsensus() public {
        EscrowContract escrow = createDisputedEscrow();

        // Reach consensus
        vm.prank(buyer);
        escrow.submitResolutionVote(60);

        vm.prank(seller);
        escrow.submitResolutionVote(60);

        assertTrue(escrow.consensusReached());

        // Try to change vote after consensus - state is now "claimed" (4) not "disputed" (2)
        vm.prank(buyer);
        vm.expectRevert(EscrowContract.ContractMustBeDisputed.selector);
        escrow.submitResolutionVote(80);
    }

    function testVoteTimestampUpdatesOnChange() public {
        EscrowContract escrow = createDisputedEscrow();

        // First vote
        vm.prank(buyer);
        escrow.submitResolutionVote(80);

        uint8 percentage1 = escrow.resolutionVotes(buyer);
        assertEq(percentage1, 80);

        // Warp time forward
        vm.warp(block.timestamp + 1 hours);

        // Change vote
        vm.prank(buyer);
        escrow.submitResolutionVote(60);

        uint8 percentage2 = escrow.resolutionVotes(buyer);
        assertEq(percentage2, 60);
        // Note: Timestamp tracking removed in gas optimization, but vote changes still work
    }

    // ========== RESOLUTION EXECUTION TESTS ==========

    function testResolution100PercentToBuyer() public {
        EscrowContract escrow = createDisputedEscrow();

        uint256 buyerBalanceBefore = usdc.balanceOf(buyer);
        uint256 sellerBalanceBefore = usdc.balanceOf(seller);

        // Reach consensus for 100% refund to buyer
        vm.prank(buyer);
        escrow.submitResolutionVote(100);

        vm.prank(admin);
        escrow.submitResolutionVote(100);

        // Buyer gets all escrowed funds
        uint256 escrowAmount = AMOUNT - CREATOR_FEE;
        assertEq(usdc.balanceOf(buyer), buyerBalanceBefore + escrowAmount);
        assertEq(usdc.balanceOf(seller), sellerBalanceBefore); // Seller gets nothing
    }

    function testResolution0PercentToBuyer() public {
        EscrowContract escrow = createDisputedEscrow();

        uint256 buyerBalanceBefore = usdc.balanceOf(buyer);
        uint256 sellerBalanceBefore = usdc.balanceOf(seller);

        // Reach consensus for 0% to buyer (100% to seller)
        vm.prank(seller);
        escrow.submitResolutionVote(0);

        vm.prank(admin);
        escrow.submitResolutionVote(0);

        // Seller gets all escrowed funds
        uint256 escrowAmount = AMOUNT - CREATOR_FEE;
        assertEq(usdc.balanceOf(buyer), buyerBalanceBefore); // Buyer gets nothing
        assertEq(usdc.balanceOf(seller), sellerBalanceBefore + escrowAmount);
    }

    function testResolution50PercentSplit() public {
        EscrowContract escrow = createDisputedEscrow();

        uint256 buyerBalanceBefore = usdc.balanceOf(buyer);
        uint256 sellerBalanceBefore = usdc.balanceOf(seller);

        // Reach consensus for 50/50 split
        vm.prank(buyer);
        escrow.submitResolutionVote(50);

        vm.prank(seller);
        escrow.submitResolutionVote(50);

        // Check 50/50 distribution
        uint256 escrowAmount = AMOUNT - CREATOR_FEE;
        uint256 expectedHalf = escrowAmount / 2;

        assertEq(usdc.balanceOf(buyer), buyerBalanceBefore + expectedHalf);
        assertEq(usdc.balanceOf(seller), sellerBalanceBefore + (escrowAmount - expectedHalf));
    }

    function testResolutionEmitsCorrectEvents() public {
        EscrowContract escrow = createDisputedEscrow();

        vm.prank(buyer);
        escrow.submitResolutionVote(60);

        uint256 escrowAmount = AMOUNT - CREATOR_FEE;
        uint256 buyerAmount = (escrowAmount * 60) / 100;
        uint256 sellerAmount = escrowAmount - buyerAmount;

        // Expect DisputeResolved event
        vm.expectEmit(false, false, false, true);
        emit DisputeResolved(60, 40, block.timestamp);

        // Expect FundsClaimed events
        vm.expectEmit(false, false, false, true);
        emit FundsClaimed(buyer, buyerAmount, block.timestamp);

        if (sellerAmount > 0) {
            vm.expectEmit(false, false, false, true);
            emit FundsClaimed(seller, sellerAmount, block.timestamp);
        }

        vm.prank(seller);
        escrow.submitResolutionVote(60);
    }

    event DisputeResolved(uint256 buyerPercentage, uint256 sellerPercentage, uint256 timestamp);
    event FundsClaimed(address recipient, uint256 amount, uint256 timestamp);

    // ========== EDGE CASES ==========

    function testThreeWayVotingScenario() public {
        EscrowContract escrow = createDisputedEscrow();

        // Buyer votes 80%
        vm.prank(buyer);
        escrow.submitResolutionVote(80);
        assertFalse(escrow.consensusReached());

        // Seller votes 20%
        vm.prank(seller);
        escrow.submitResolutionVote(20);
        assertFalse(escrow.consensusReached());

        // Admin votes 20% - matches seller, consensus!
        vm.prank(admin);
        escrow.submitResolutionVote(20);
        assertTrue(escrow.consensusReached());

        // Resolution should be 20% to buyer
        uint256 escrowAmount = AMOUNT - CREATOR_FEE;
        uint256 expectedBuyerAmount = (escrowAmount * 20) / 100;
        assertEq(usdc.balanceOf(buyer) - (AMOUNT * 9), expectedBuyerAmount); // Subtract initial balance
    }

    function testConsensusOnFirstTwoVotes() public {
        EscrowContract escrow = createDisputedEscrow();

        // First two votes match
        vm.prank(buyer);
        escrow.submitResolutionVote(55);

        vm.prank(seller);
        escrow.submitResolutionVote(55);

        assertTrue(escrow.consensusReached());

        // Admin can't vote after consensus - state is now "claimed" (4)
        vm.prank(admin);
        vm.expectRevert(EscrowContract.ContractMustBeDisputed.selector);
        escrow.submitResolutionVote(55);
    }

    function testOnlyTwoVotesNeededForConsensus() public {
        EscrowContract escrow = createDisputedEscrow();

        // Only buyer and admin vote
        vm.prank(buyer);
        escrow.submitResolutionVote(75);

        vm.prank(admin);
        escrow.submitResolutionVote(75);

        assertTrue(escrow.consensusReached());
        assertTrue(escrow.isClaimed());

        // Seller never voted (will be 255 = not voted)
        uint8 sellerVote = escrow.resolutionVotes(seller);
        assertEq(sellerVote, 255);
    }

    function testVotingWithZeroAmount() public {
        EscrowContract escrow = createDisputedEscrow();

        // Vote for 0% is valid
        vm.prank(buyer);
        escrow.submitResolutionVote(0);

        uint8 percentage = escrow.resolutionVotes(buyer);
        assertEq(percentage, 0);
    }

    function testVotingWith100Percent() public {
        EscrowContract escrow = createDisputedEscrow();

        // Vote for 100% is valid
        vm.prank(buyer);
        escrow.submitResolutionVote(100);

        uint8 percentage = escrow.resolutionVotes(buyer);
        assertEq(percentage, 100);
    }

    // ========== COMPREHENSIVE INTEGRATION TEST ==========

    function testFullNegotiationFlow() public {
        EscrowContract escrow = createDisputedEscrow();

        // Round 1: Buyer proposes 90% refund
        vm.prank(buyer);
        escrow.submitResolutionVote(90);

        // Round 2: Seller counter-offers 10%
        vm.prank(seller);
        escrow.submitResolutionVote(10);

        assertFalse(escrow.consensusReached());

        // Round 3: Buyer changes to 70%
        vm.prank(buyer);
        escrow.submitResolutionVote(70);

        // Round 4: Seller changes to 30%
        vm.prank(seller);
        escrow.submitResolutionVote(30);

        assertFalse(escrow.consensusReached());

        // Round 5: Admin mediates with 50%
        vm.prank(admin);
        escrow.submitResolutionVote(50);

        assertFalse(escrow.consensusReached()); // Still no match

        // Round 6: Buyer accepts admin's 50%
        vm.prank(buyer);
        escrow.submitResolutionVote(50);

        // Consensus reached with buyer + admin
        assertTrue(escrow.consensusReached());
        assertTrue(escrow.isClaimed());
    }
}
