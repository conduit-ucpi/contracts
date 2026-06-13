// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {CompletionEscrowContract} from "../src/CompletionEscrowContract.sol";
import {CompletionEscrowContractFactory} from "../src/CompletionEscrowContractFactory.sol";

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    string public name = "Mock USDC";
    string public symbol = "MUSDC";
    uint8 public decimals = 6;
    uint256 public totalSupply;

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

contract CompletionEscrowContractTest is Test {
    CompletionEscrowContractFactory public factory;
    MockERC20 public usdc;

    address public buyer = address(0x1);
    address public seller = address(0x2);
    address public gasPayer = address(0x3);
    address public recipient1 = address(0x11);
    address public recipient2 = address(0x12);
    address public other = address(0x4);

    uint256 public constant AMOUNT = 1000 * 10**6; // 1000 USDC
    uint256 public CREATOR_FEE; // 1% of AMOUNT
    uint256 public ESCROW;      // AMOUNT - CREATOR_FEE
    uint256 public expiryTimestamp;
    string public description = "Test completion escrow";

    function setUp() public {
        usdc = new MockERC20();
        CompletionEscrowContract implementation = new CompletionEscrowContract();
        factory = new CompletionEscrowContractFactory(gasPayer, address(implementation), address(0));

        expiryTimestamp = block.timestamp + 7 days;
        CREATOR_FEE = AMOUNT / 100; // 10 USDC
        ESCROW = AMOUNT - CREATOR_FEE;

        usdc.mint(buyer, AMOUNT * 10);
        vm.prank(buyer);
        usdc.approve(address(factory), AMOUNT * 10);
    }

    // ── helpers ─────────────────────────────────────────────────────────────

    function _create(address r1, address r2, uint256 r1Bps) internal returns (CompletionEscrowContract) {
        vm.prank(buyer);
        address addr = factory.createEscrowContract(
            address(usdc), buyer, seller, AMOUNT, expiryTimestamp, r1, r2, r1Bps, description
        );
        return CompletionEscrowContract(addr);
    }

    function _fund(CompletionEscrowContract escrow) internal {
        vm.prank(buyer);
        usdc.approve(address(escrow), AMOUNT);
        vm.prank(buyer);
        escrow.depositFunds();
    }

    function _createAndFund(address r1, address r2, uint256 r1Bps) internal returns (CompletionEscrowContract) {
        CompletionEscrowContract escrow = _create(r1, r2, r1Bps);
        _fund(escrow);
        return escrow;
    }

    // ── creation / validation ───────────────────────────────────────────────

    function testCreateSingleRecipient() public {
        CompletionEscrowContract escrow = _create(recipient1, address(0), 10000);
        (address r1, address r2, uint256 bps) = escrow.getRecipients();
        assertEq(r1, recipient1);
        assertEq(r2, address(0));
        assertEq(bps, 10000);
        assertEq(escrow.BUYER(), buyer);
        assertEq(escrow.SELLER(), seller);
        assertEq(escrow.GAS_PAYER(), gasPayer);
        assertTrue(escrow.canDeposit());
    }

    function testCreateTwoRecipients() public {
        CompletionEscrowContract escrow = _create(recipient1, recipient2, 6000);
        (address r1, address r2, uint256 bps) = escrow.getRecipients();
        assertEq(r1, recipient1);
        assertEq(r2, recipient2);
        assertEq(bps, 6000);
    }

    function testCreateRevertsSingleRecipientWrongBps() public {
        vm.prank(buyer);
        vm.expectRevert(CompletionEscrowContractFactory.InvalidRecipientSplit.selector);
        factory.createEscrowContract(
            address(usdc), buyer, seller, AMOUNT, expiryTimestamp, recipient1, address(0), 9999, description
        );
    }

    function testCreateRevertsTwoRecipientsBpsZero() public {
        vm.prank(buyer);
        vm.expectRevert(CompletionEscrowContractFactory.InvalidRecipientSplit.selector);
        factory.createEscrowContract(
            address(usdc), buyer, seller, AMOUNT, expiryTimestamp, recipient1, recipient2, 0, description
        );
    }

    function testCreateRevertsTwoRecipientsBpsFull() public {
        vm.prank(buyer);
        vm.expectRevert(CompletionEscrowContractFactory.InvalidRecipientSplit.selector);
        factory.createEscrowContract(
            address(usdc), buyer, seller, AMOUNT, expiryTimestamp, recipient1, recipient2, 10000, description
        );
    }

    function testCreateRevertsRecipientsEqual() public {
        vm.prank(buyer);
        vm.expectRevert(CompletionEscrowContractFactory.RecipientsMustBeDifferent.selector);
        factory.createEscrowContract(
            address(usdc), buyer, seller, AMOUNT, expiryTimestamp, recipient1, recipient1, 5000, description
        );
    }

    function testCreateRevertsRecipient1Zero() public {
        vm.prank(buyer);
        vm.expectRevert(CompletionEscrowContractFactory.InvalidRecipientAddress.selector);
        factory.createEscrowContract(
            address(usdc), buyer, seller, AMOUNT, expiryTimestamp, address(0), recipient2, 5000, description
        );
    }

    function testCreateRevertsExpiryInPast() public {
        vm.prank(buyer);
        vm.expectRevert(CompletionEscrowContractFactory.InvalidExpiryTimestamp.selector);
        factory.createEscrowContract(
            address(usdc), buyer, seller, AMOUNT, block.timestamp, recipient1, address(0), 10000, description
        );
    }

    function testImplementationCannotBeInitialized() public {
        CompletionEscrowContract impl = new CompletionEscrowContract();
        vm.expectRevert(CompletionEscrowContract.NotInitialized.selector);
        impl.isFunded();
    }

    // ── deposit ─────────────────────────────────────────────────────────────

    function testDeposit() public {
        CompletionEscrowContract escrow = _createAndFund(recipient1, address(0), 10000);
        assertTrue(escrow.isFunded());
        assertEq(usdc.balanceOf(address(escrow)), ESCROW);
        // fee paid out to FEE_RECIPIENT (defaults to OWNER = gasPayer)
        assertEq(usdc.balanceOf(gasPayer), CREATOR_FEE);
    }

    function testDepositRevertsTwice() public {
        CompletionEscrowContract escrow = _createAndFund(recipient1, address(0), 10000);
        vm.prank(buyer);
        usdc.approve(address(escrow), AMOUNT);
        vm.prank(buyer);
        vm.expectRevert(CompletionEscrowContract.AlreadyFundedOrClaimed.selector);
        escrow.depositFunds();
    }

    function testDepositOnlyBuyerOrGasPayer() public {
        CompletionEscrowContract escrow = _create(recipient1, address(0), 10000);
        vm.prank(other);
        vm.expectRevert(CompletionEscrowContract.OnlyBuyerOrGasPayer.selector);
        escrow.depositFunds();
    }

    // ── happy path: dual verify ─────────────────────────────────────────────

    function testHappyPathSingleRecipient() public {
        CompletionEscrowContract escrow = _createAndFund(recipient1, address(0), 10000);

        vm.prank(seller);
        escrow.markComplete();
        assertTrue(escrow.isAwaitingVerification());

        vm.prank(buyer);
        escrow.verifyComplete();

        assertTrue(escrow.isClaimed());
        assertEq(usdc.balanceOf(recipient1), ESCROW);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function testHappyPathTwoRecipientsEvenSplit() public {
        CompletionEscrowContract escrow = _createAndFund(recipient1, recipient2, 5000);

        vm.prank(seller);
        escrow.markComplete();
        vm.prank(buyer);
        escrow.verifyComplete();

        uint256 expected1 = (ESCROW * 5000) / 10000;
        assertEq(usdc.balanceOf(recipient1), expected1);
        assertEq(usdc.balanceOf(recipient2), ESCROW - expected1);
        assertEq(usdc.balanceOf(recipient1) + usdc.balanceOf(recipient2), ESCROW);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function testHappyPathTwoRecipientsUnevenSplit() public {
        // 33.33% split produces rounding dust; dust must go to recipient2, nothing stuck
        CompletionEscrowContract escrow = _createAndFund(recipient1, recipient2, 3333);

        vm.prank(seller);
        escrow.markComplete();
        vm.prank(buyer);
        escrow.verifyComplete();

        uint256 expected1 = (ESCROW * 3333) / 10000;
        assertEq(usdc.balanceOf(recipient1), expected1);
        assertEq(usdc.balanceOf(recipient2), ESCROW - expected1);
        assertEq(usdc.balanceOf(recipient1) + usdc.balanceOf(recipient2), ESCROW);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function testMarkCompleteOnlySeller() public {
        CompletionEscrowContract escrow = _createAndFund(recipient1, address(0), 10000);
        vm.prank(buyer);
        vm.expectRevert(CompletionEscrowContract.OnlySeller.selector);
        escrow.markComplete();
    }

    function testMarkCompleteRequiresFunded() public {
        CompletionEscrowContract escrow = _create(recipient1, address(0), 10000);
        vm.prank(seller);
        vm.expectRevert(CompletionEscrowContract.NotFunded.selector);
        escrow.markComplete();
    }

    function testVerifyOnlyBuyer() public {
        CompletionEscrowContract escrow = _createAndFund(recipient1, address(0), 10000);
        vm.prank(seller);
        escrow.markComplete();
        vm.prank(other);
        vm.expectRevert(CompletionEscrowContract.OnlyBuyer.selector);
        escrow.verifyComplete();
    }

    function testVerifyRequiresMarkComplete() public {
        CompletionEscrowContract escrow = _createAndFund(recipient1, address(0), 10000);
        vm.prank(buyer);
        vm.expectRevert(CompletionEscrowContract.NotAwaitingVerification.selector);
        escrow.verifyComplete();
    }

    // ── expiry never releases funds ─────────────────────────────────────────

    function testExpiryDoesNotReleaseFunds() public {
        CompletionEscrowContract escrow = _createAndFund(recipient1, address(0), 10000);
        vm.warp(expiryTimestamp + 1 days);

        // No claim function exists; funds stay locked, recipients got nothing
        assertTrue(escrow.isExpired());
        assertEq(usdc.balanceOf(address(escrow)), ESCROW);
        assertEq(usdc.balanceOf(recipient1), 0);

        // Dual-verify still works after expiry (expiry only closes the dispute window)
        vm.prank(seller);
        escrow.markComplete();
        vm.prank(buyer);
        escrow.verifyComplete();
        assertEq(usdc.balanceOf(recipient1), ESCROW);
    }

    // ── disputes ────────────────────────────────────────────────────────────

    function testDisputeFromFunded() public {
        CompletionEscrowContract escrow = _createAndFund(recipient1, address(0), 10000);
        vm.prank(buyer);
        escrow.raiseDispute();
        assertTrue(escrow.isDisputed());
    }

    function testDisputeFromPendingVerify() public {
        CompletionEscrowContract escrow = _createAndFund(recipient1, address(0), 10000);
        vm.prank(seller);
        escrow.markComplete();
        vm.prank(buyer);
        escrow.raiseDispute();
        assertTrue(escrow.isDisputed());
    }

    function testDisputeOnlyBuyer() public {
        CompletionEscrowContract escrow = _createAndFund(recipient1, address(0), 10000);
        vm.prank(seller);
        vm.expectRevert(CompletionEscrowContract.OnlyBuyer.selector);
        escrow.raiseDispute();
    }

    function testDisputeRevertsAfterExpiry() public {
        CompletionEscrowContract escrow = _createAndFund(recipient1, address(0), 10000);
        vm.warp(expiryTimestamp);
        vm.prank(buyer);
        vm.expectRevert(CompletionEscrowContract.CannotDisputeAfterExpiry.selector);
        escrow.raiseDispute();
    }

    function testDisputeRevertsWrongState() public {
        CompletionEscrowContract escrow = _create(recipient1, address(0), 10000);
        vm.prank(buyer);
        vm.expectRevert(CompletionEscrowContract.CannotDisputeNow.selector);
        escrow.raiseDispute();
    }

    function testDisputeResolutionBuyerSellerConsensus() public {
        CompletionEscrowContract escrow = _createAndFund(recipient1, recipient2, 6000);
        vm.prank(buyer);
        escrow.raiseDispute();

        // buyer gets 40% refund, supplier side (60%) split between recipients
        vm.prank(buyer);
        escrow.submitResolutionVote(40);
        vm.prank(seller);
        escrow.submitResolutionVote(40);

        assertTrue(escrow.consensusReached());
        assertTrue(escrow.isClaimed());

        uint256 buyerAmount = (ESCROW * 40) / 100;
        uint256 supplierAmount = ESCROW - buyerAmount;
        uint256 expected1 = (supplierAmount * 6000) / 10000;

        assertEq(usdc.balanceOf(buyer), buyerAmount + (AMOUNT * 10 - AMOUNT)); // refund + leftover mint
        assertEq(usdc.balanceOf(recipient1), expected1);
        assertEq(usdc.balanceOf(recipient2), supplierAmount - expected1);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function testDisputeResolutionAdminBreaksTie() public {
        CompletionEscrowContract escrow = _createAndFund(recipient1, address(0), 10000);
        vm.prank(buyer);
        escrow.raiseDispute();

        vm.prank(seller);
        escrow.submitResolutionVote(0); // supplier wants 0% to buyer
        vm.prank(gasPayer);
        escrow.submitResolutionVote(0); // admin agrees -> consensus

        assertTrue(escrow.isClaimed());
        assertEq(usdc.balanceOf(recipient1), ESCROW);
    }

    function testDisputeFullRefundToBuyer() public {
        CompletionEscrowContract escrow = _createAndFund(recipient1, recipient2, 5000);
        uint256 buyerBefore = usdc.balanceOf(buyer);
        vm.prank(buyer);
        escrow.raiseDispute();

        vm.prank(buyer);
        escrow.submitResolutionVote(100);
        vm.prank(gasPayer);
        escrow.submitResolutionVote(100);

        assertEq(usdc.balanceOf(buyer), buyerBefore + ESCROW);
        assertEq(usdc.balanceOf(recipient1), 0);
        assertEq(usdc.balanceOf(recipient2), 0);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function testVoteRevertsNotDisputed() public {
        CompletionEscrowContract escrow = _createAndFund(recipient1, address(0), 10000);
        vm.prank(buyer);
        vm.expectRevert(CompletionEscrowContract.ContractMustBeDisputed.selector);
        escrow.submitResolutionVote(50);
    }

    function testVoteRevertsUnauthorized() public {
        CompletionEscrowContract escrow = _createAndFund(recipient1, address(0), 10000);
        vm.prank(buyer);
        escrow.raiseDispute();
        vm.prank(other);
        vm.expectRevert(CompletionEscrowContract.NotAuthorizedToVote.selector);
        escrow.submitResolutionVote(50);
    }

    function testVoteRevertsInvalidPercentage() public {
        CompletionEscrowContract escrow = _createAndFund(recipient1, address(0), 10000);
        vm.prank(buyer);
        escrow.raiseDispute();
        vm.prank(buyer);
        vm.expectRevert(CompletionEscrowContract.InvalidPercentage.selector);
        escrow.submitResolutionVote(101);
    }

    // ── fuzz ────────────────────────────────────────────────────────────────

    function testFuzzHappyPathSplitNoDust(uint256 bps) public {
        bps = bound(bps, 1, 9999);
        CompletionEscrowContract escrow = _createAndFund(recipient1, recipient2, bps);

        vm.prank(seller);
        escrow.markComplete();
        vm.prank(buyer);
        escrow.verifyComplete();

        uint256 expected1 = (ESCROW * bps) / 10000;
        assertEq(usdc.balanceOf(recipient1), expected1);
        assertEq(usdc.balanceOf(recipient2), ESCROW - expected1);
        assertEq(usdc.balanceOf(recipient1) + usdc.balanceOf(recipient2), ESCROW);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function testFuzzDisputeSplitNoDust(uint256 bps, uint256 pct) public {
        bps = bound(bps, 1, 9999);
        pct = bound(pct, 0, 100);
        CompletionEscrowContract escrow = _createAndFund(recipient1, recipient2, bps);

        vm.prank(buyer);
        escrow.raiseDispute();
        vm.prank(buyer);
        escrow.submitResolutionVote(pct);
        vm.prank(gasPayer);
        escrow.submitResolutionVote(pct);

        uint256 buyerAmount = (ESCROW * pct) / 100;
        uint256 supplierAmount = ESCROW - buyerAmount;
        uint256 expected1 = (supplierAmount * bps) / 10000;

        assertEq(usdc.balanceOf(recipient1), expected1);
        assertEq(usdc.balanceOf(recipient2), supplierAmount - expected1);
        // every microUSDC accounted for: buyer refund + both recipients == escrow
        assertEq(
            buyerAmount + usdc.balanceOf(recipient1) + usdc.balanceOf(recipient2),
            ESCROW
        );
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }
}
