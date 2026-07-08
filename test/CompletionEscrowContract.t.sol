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

    // ── split builders ───────────────────────────────────────────────────────

    function _single() internal view returns (address[] memory r, uint256[] memory b) {
        r = new address[](1);
        b = new uint256[](1);
        r[0] = recipient1;
        b[0] = 10000;
    }

    function _two(uint256 bps1) internal view returns (address[] memory r, uint256[] memory b) {
        r = new address[](2);
        b = new uint256[](2);
        r[0] = recipient1;
        r[1] = recipient2;
        b[0] = bps1;
        b[1] = 10000 - bps1;
    }

    // ── create / fund helpers ────────────────────────────────────────────────

    function _create(address[] memory r, uint256[] memory b) internal returns (CompletionEscrowContract) {
        vm.prank(buyer);
        address addr = factory.createEscrowContract(
            address(usdc), buyer, seller, AMOUNT, expiryTimestamp, r, b, address(0), description
        );
        return CompletionEscrowContract(addr);
    }

    function _fund(CompletionEscrowContract escrow) internal {
        vm.prank(buyer);
        usdc.approve(address(escrow), AMOUNT);
        vm.prank(buyer);
        escrow.depositFunds();
    }

    function _createAndFund(address[] memory r, uint256[] memory b) internal returns (CompletionEscrowContract) {
        CompletionEscrowContract escrow = _create(r, b);
        _fund(escrow);
        return escrow;
    }

    function _createSingle() internal returns (CompletionEscrowContract) {
        (address[] memory r, uint256[] memory b) = _single();
        return _create(r, b);
    }

    function _createAndFundSingle() internal returns (CompletionEscrowContract) {
        (address[] memory r, uint256[] memory b) = _single();
        return _createAndFund(r, b);
    }

    function _createAndFundTwo(uint256 bps1) internal returns (CompletionEscrowContract) {
        (address[] memory r, uint256[] memory b) = _two(bps1);
        return _createAndFund(r, b);
    }

    // ── creation / validation ───────────────────────────────────────────────

    function testCreateSingleRecipient() public {
        CompletionEscrowContract escrow = _createSingle();
        (address[] memory r, uint256[] memory b) = escrow.getRecipients();
        assertEq(r.length, 1);
        assertEq(r[0], recipient1);
        assertEq(b[0], 10000);
        assertEq(escrow.BUYER(), buyer);
        assertEq(escrow.SELLER(), seller);
        assertEq(escrow.GAS_PAYER(), gasPayer);
        assertTrue(escrow.canDeposit());
    }

    function testCreateTwoRecipients() public {
        (address[] memory r, uint256[] memory b) = _two(6000);
        CompletionEscrowContract escrow = _create(r, b);
        (address[] memory gr, uint256[] memory gb) = escrow.getRecipients();
        assertEq(gr.length, 2);
        assertEq(gr[0], recipient1);
        assertEq(gr[1], recipient2);
        assertEq(gb[0], 6000);
        assertEq(gb[1], 4000);
    }

    function testCreateRevertsBpsSumTooLow() public {
        (address[] memory r, uint256[] memory b) = _two(5000);
        b[1] = 4000; // sum 9000
        vm.prank(buyer);
        vm.expectRevert(CompletionEscrowContract.RecipientBpsSumNot10000.selector);
        factory.createEscrowContract(
            address(usdc), buyer, seller, AMOUNT, expiryTimestamp, r, b, address(0), description
        );
    }

    function testCreateRevertsBpsSumTooHigh() public {
        (address[] memory r, uint256[] memory b) = _two(5000);
        b[1] = 6000; // sum 11000
        vm.prank(buyer);
        vm.expectRevert(CompletionEscrowContract.RecipientBpsSumNot10000.selector);
        factory.createEscrowContract(
            address(usdc), buyer, seller, AMOUNT, expiryTimestamp, r, b, address(0), description
        );
    }

    function testCreateRevertsZeroBps() public {
        address[] memory r = new address[](2);
        uint256[] memory b = new uint256[](2);
        r[0] = recipient1; r[1] = recipient2;
        b[0] = 10000; b[1] = 0; // a zero share is not allowed
        vm.prank(buyer);
        vm.expectRevert(CompletionEscrowContract.InvalidRecipientBps.selector);
        factory.createEscrowContract(
            address(usdc), buyer, seller, AMOUNT, expiryTimestamp, r, b, address(0), description
        );
    }

    function testCreateRevertsZeroRecipientAddress() public {
        address[] memory r = new address[](2);
        uint256[] memory b = new uint256[](2);
        r[0] = recipient1; r[1] = address(0);
        b[0] = 5000; b[1] = 5000;
        vm.prank(buyer);
        vm.expectRevert(CompletionEscrowContract.InvalidRecipientAddress.selector);
        factory.createEscrowContract(
            address(usdc), buyer, seller, AMOUNT, expiryTimestamp, r, b, address(0), description
        );
    }

    function testCreateRevertsNoRecipients() public {
        address[] memory r = new address[](0);
        uint256[] memory b = new uint256[](0);
        vm.prank(buyer);
        vm.expectRevert(CompletionEscrowContract.NoRecipients.selector);
        factory.createEscrowContract(
            address(usdc), buyer, seller, AMOUNT, expiryTimestamp, r, b, address(0), description
        );
    }

    function testCreateRevertsArrayLengthMismatch() public {
        address[] memory r = new address[](2);
        uint256[] memory b = new uint256[](1);
        r[0] = recipient1; r[1] = recipient2;
        b[0] = 10000;
        vm.prank(buyer);
        vm.expectRevert(CompletionEscrowContract.RecipientArrayLengthMismatch.selector);
        factory.createEscrowContract(
            address(usdc), buyer, seller, AMOUNT, expiryTimestamp, r, b, address(0), description
        );
    }

    function testCreateRevertsTooManyRecipients() public {
        uint256 n = 11; // MAX_RECIPIENTS is 10
        address[] memory r = new address[](n);
        uint256[] memory b = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            r[i] = address(uint160(0x100 + i));
            b[i] = (i == n - 1) ? 10000 - (1000 * (n - 1)) : 1000;
        }
        vm.prank(buyer);
        vm.expectRevert(CompletionEscrowContract.TooManyRecipients.selector);
        factory.createEscrowContract(
            address(usdc), buyer, seller, AMOUNT, expiryTimestamp, r, b, address(0), description
        );
    }

    function testCreateRevertsExpiryInPast() public {
        (address[] memory r, uint256[] memory b) = _single();
        vm.prank(buyer);
        vm.expectRevert(CompletionEscrowContractFactory.InvalidExpiryTimestamp.selector);
        factory.createEscrowContract(
            address(usdc), buyer, seller, AMOUNT, block.timestamp, r, b, address(0), description
        );
    }

    function testImplementationCannotBeInitialized() public {
        CompletionEscrowContract impl = new CompletionEscrowContract();
        vm.expectRevert(CompletionEscrowContract.NotInitialized.selector);
        impl.isFunded();
    }

    // ── deposit ─────────────────────────────────────────────────────────────

    function testDeposit() public {
        CompletionEscrowContract escrow = _createAndFundSingle();
        assertTrue(escrow.isFunded());
        assertEq(usdc.balanceOf(address(escrow)), ESCROW);
        assertEq(usdc.balanceOf(gasPayer), CREATOR_FEE);
    }

    function testDepositRevertsTwice() public {
        CompletionEscrowContract escrow = _createAndFundSingle();
        vm.prank(buyer);
        usdc.approve(address(escrow), AMOUNT);
        vm.prank(buyer);
        vm.expectRevert(CompletionEscrowContract.AlreadyFundedOrClaimed.selector);
        escrow.depositFunds();
    }

    function testDepositOnlyBuyerOrGasPayer() public {
        CompletionEscrowContract escrow = _createSingle();
        vm.prank(other);
        vm.expectRevert(CompletionEscrowContract.OnlyBuyerOrGasPayer.selector);
        escrow.depositFunds();
    }

    // ── self-fund from balance (tree fan-out) ────────────────────────────────

    function testCheckAndActivateFromBalance() public {
        CompletionEscrowContract escrow = _createSingle();
        assertFalse(escrow.canActivateFromBalance());

        usdc.mint(address(escrow), AMOUNT);
        assertTrue(escrow.canActivateFromBalance());
        assertEq(escrow.tokenBalance(), AMOUNT);

        vm.prank(gasPayer);
        escrow.checkAndActivate();

        assertTrue(escrow.isFunded());
        assertEq(escrow.tokenBalance(), ESCROW);
        assertEq(usdc.balanceOf(gasPayer), CREATOR_FEE);
    }

    function testCheckAndActivateRevertsInsufficientBalance() public {
        CompletionEscrowContract escrow = _createSingle();
        usdc.mint(address(escrow), AMOUNT - 1);
        vm.prank(gasPayer);
        vm.expectRevert(CompletionEscrowContract.InsufficientBalanceToActivate.selector);
        escrow.checkAndActivate();
    }

    function testCheckAndActivateRevertsIfAlreadyFunded() public {
        CompletionEscrowContract escrow = _createAndFundSingle();
        usdc.mint(address(escrow), AMOUNT);
        vm.prank(gasPayer);
        vm.expectRevert(CompletionEscrowContract.AlreadyFundedOrClaimed.selector);
        escrow.checkAndActivate();
    }

    function testCheckAndActivateOnlyBuyerOrGasPayer() public {
        CompletionEscrowContract escrow = _createSingle();
        usdc.mint(address(escrow), AMOUNT);
        vm.prank(other);
        vm.expectRevert(CompletionEscrowContract.OnlyBuyerOrGasPayer.selector);
        escrow.checkAndActivate();
    }

    /// Full tree: a parent node pays a child node, the child self-funds, then completes.
    function testTreeFanOutChildSelfFunds() public {
        address finalRecipient = address(0x21);
        address otherRecipient = address(0x22);

        uint256 parentAmount = 2000 * 10**6;
        uint256 childAmount = 990 * 10**6;

        (address[] memory childR, uint256[] memory childB) = _single();
        childR[0] = finalRecipient;

        vm.prank(buyer);
        address childAddr = factory.createEscrowContract(
            address(usdc), buyer, seller, childAmount, expiryTimestamp, childR, childB, address(0), "child"
        );
        CompletionEscrowContract child = CompletionEscrowContract(childAddr);

        // Parent: 2000 USDC, 50/50 between the child and another recipient
        address[] memory parentR = new address[](2);
        uint256[] memory parentB = new uint256[](2);
        parentR[0] = childAddr; parentR[1] = otherRecipient;
        parentB[0] = 5000; parentB[1] = 5000;

        vm.prank(buyer);
        address parentAddr = factory.createEscrowContract(
            address(usdc), buyer, seller, parentAmount, expiryTimestamp, parentR, parentB, address(0), "parent"
        );
        CompletionEscrowContract parent = CompletionEscrowContract(parentAddr);

        vm.prank(buyer);
        usdc.approve(parentAddr, parentAmount);
        vm.prank(buyer);
        parent.depositFunds();
        vm.prank(seller);
        parent.markComplete();
        vm.prank(buyer);
        parent.verifyComplete();

        // Parent ESCROW = 1980; child (50%) receives exactly its AMOUNT of 990
        assertEq(usdc.balanceOf(childAddr), childAmount);
        assertTrue(child.canActivateFromBalance());

        vm.prank(gasPayer);
        child.checkAndActivate();
        assertTrue(child.isFunded());

        uint256 childEscrow = childAmount - (childAmount / 100);
        assertEq(usdc.balanceOf(childAddr), childEscrow);

        vm.prank(seller);
        child.markComplete();
        vm.prank(buyer);
        child.verifyComplete();

        assertEq(usdc.balanceOf(finalRecipient), childEscrow);
        assertEq(usdc.balanceOf(childAddr), 0);
    }

    // ── happy path: dual verify ─────────────────────────────────────────────

    function testHappyPathSingleRecipient() public {
        CompletionEscrowContract escrow = _createAndFundSingle();

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
        CompletionEscrowContract escrow = _createAndFundTwo(5000);

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
        // 33.33% split produces rounding dust; the last recipient absorbs it, nothing stuck
        CompletionEscrowContract escrow = _createAndFundTwo(3333);

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

    function testHappyPathManyRecipientsNoDust() public {
        // Ten recipients with deliberately uneven, prime-ish shares to force rounding dust
        uint256 n = 10;
        address[] memory r = new address[](n);
        uint256[] memory b = new uint256[](n);
        uint256[10] memory shares = [uint256(1111), 999, 1234, 777, 1500, 321, 888, 1010, 660, 0];
        uint256 sumSoFar;
        for (uint256 i = 0; i < n - 1; i++) {
            sumSoFar += shares[i];
        }
        for (uint256 i = 0; i < n; i++) {
            r[i] = address(uint160(0x200 + i));
            b[i] = (i == n - 1) ? 10000 - sumSoFar : shares[i];
        }

        CompletionEscrowContract escrow = _createAndFund(r, b);
        vm.prank(seller);
        escrow.markComplete();
        vm.prank(buyer);
        escrow.verifyComplete();

        uint256 total;
        for (uint256 i = 0; i < n; i++) {
            total += usdc.balanceOf(r[i]);
        }
        assertEq(total, ESCROW);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function testMarkCompleteOnlySeller() public {
        CompletionEscrowContract escrow = _createAndFundSingle();
        vm.prank(buyer);
        vm.expectRevert(CompletionEscrowContract.OnlySeller.selector);
        escrow.markComplete();
    }

    function testMarkCompleteRequiresFunded() public {
        CompletionEscrowContract escrow = _createSingle();
        vm.prank(seller);
        vm.expectRevert(CompletionEscrowContract.NotFunded.selector);
        escrow.markComplete();
    }

    function testVerifyRequiresMarkComplete() public {
        CompletionEscrowContract escrow = _createAndFundSingle();
        vm.prank(buyer);
        vm.expectRevert(CompletionEscrowContract.NotAwaitingVerification.selector);
        escrow.verifyComplete();
    }

    // ── verifier role ────────────────────────────────────────────────────────

    function testVerifyOnlyVerifierDefaultsToBuyer() public {
        CompletionEscrowContract escrow = _createAndFundSingle();
        assertEq(escrow.VERIFIER(), buyer);
        vm.prank(seller);
        escrow.markComplete();
        vm.prank(other);
        vm.expectRevert(CompletionEscrowContract.OnlyVerifier.selector);
        escrow.verifyComplete();
    }

    function testNominatedVerifierVerifies() public {
        address verifier = address(0x31);
        (address[] memory r, uint256[] memory b) = _single();
        vm.prank(buyer);
        address addr = factory.createEscrowContract(
            address(usdc), buyer, seller, AMOUNT, expiryTimestamp, r, b, verifier, description
        );
        CompletionEscrowContract escrow = CompletionEscrowContract(addr);
        assertEq(escrow.VERIFIER(), verifier);
        _fund(escrow);

        vm.prank(seller);
        escrow.markComplete();

        // The buyer can no longer verify - only the nominated verifier can
        vm.prank(buyer);
        vm.expectRevert(CompletionEscrowContract.OnlyVerifier.selector);
        escrow.verifyComplete();

        vm.prank(verifier);
        escrow.verifyComplete();
        assertTrue(escrow.isClaimed());
        assertEq(usdc.balanceOf(recipient1), ESCROW);
    }

    function testNominatedVerifierStillLetsBuyerDispute() public {
        address verifier = address(0x31);
        (address[] memory r, uint256[] memory b) = _single();
        vm.prank(buyer);
        address addr = factory.createEscrowContract(
            address(usdc), buyer, seller, AMOUNT, expiryTimestamp, r, b, verifier, description
        );
        CompletionEscrowContract escrow = CompletionEscrowContract(addr);
        _fund(escrow);

        vm.prank(buyer);
        escrow.raiseDispute();
        assertTrue(escrow.isDisputed());
    }

    function testCreateRevertsVerifierIsSeller() public {
        (address[] memory r, uint256[] memory b) = _single();
        vm.prank(buyer);
        vm.expectRevert(CompletionEscrowContractFactory.VerifierCannotBeSeller.selector);
        factory.createEscrowContract(
            address(usdc), buyer, seller, AMOUNT, expiryTimestamp, r, b, seller, description
        );
    }

    // ── expiry never releases funds ─────────────────────────────────────────

    function testExpiryDoesNotReleaseFunds() public {
        CompletionEscrowContract escrow = _createAndFundSingle();
        vm.warp(expiryTimestamp + 1 days);

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
        CompletionEscrowContract escrow = _createAndFundSingle();
        vm.prank(buyer);
        escrow.raiseDispute();
        assertTrue(escrow.isDisputed());
    }

    function testDisputeFromPendingVerify() public {
        CompletionEscrowContract escrow = _createAndFundSingle();
        vm.prank(seller);
        escrow.markComplete();
        vm.prank(buyer);
        escrow.raiseDispute();
        assertTrue(escrow.isDisputed());
    }

    function testDisputeOnlyBuyer() public {
        CompletionEscrowContract escrow = _createAndFundSingle();
        vm.prank(seller);
        vm.expectRevert(CompletionEscrowContract.OnlyBuyer.selector);
        escrow.raiseDispute();
    }

    function testDisputeRevertsAfterExpiry() public {
        CompletionEscrowContract escrow = _createAndFundSingle();
        vm.warp(expiryTimestamp);
        vm.prank(buyer);
        vm.expectRevert(CompletionEscrowContract.CannotDisputeAfterExpiry.selector);
        escrow.raiseDispute();
    }

    function testDisputeRevertsWrongState() public {
        CompletionEscrowContract escrow = _createSingle();
        vm.prank(buyer);
        vm.expectRevert(CompletionEscrowContract.CannotDisputeNow.selector);
        escrow.raiseDispute();
    }

    function testDisputeResolutionBuyerSellerConsensus() public {
        CompletionEscrowContract escrow = _createAndFundTwo(6000);
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
        CompletionEscrowContract escrow = _createAndFundSingle();
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
        CompletionEscrowContract escrow = _createAndFundTwo(5000);
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
        CompletionEscrowContract escrow = _createAndFundSingle();
        vm.prank(buyer);
        vm.expectRevert(CompletionEscrowContract.ContractMustBeDisputed.selector);
        escrow.submitResolutionVote(50);
    }

    function testVoteRevertsUnauthorized() public {
        CompletionEscrowContract escrow = _createAndFundSingle();
        vm.prank(buyer);
        escrow.raiseDispute();
        vm.prank(other);
        vm.expectRevert(CompletionEscrowContract.NotAuthorizedToVote.selector);
        escrow.submitResolutionVote(50);
    }

    function testVoteRevertsInvalidPercentage() public {
        CompletionEscrowContract escrow = _createAndFundSingle();
        vm.prank(buyer);
        escrow.raiseDispute();
        vm.prank(buyer);
        vm.expectRevert(CompletionEscrowContract.InvalidPercentage.selector);
        escrow.submitResolutionVote(101);
    }

    // ── fuzz ────────────────────────────────────────────────────────────────

    function testFuzzHappyPathSplitNoDust(uint256 bps) public {
        bps = bound(bps, 1, 9999);
        CompletionEscrowContract escrow = _createAndFundTwo(bps);

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
        CompletionEscrowContract escrow = _createAndFundTwo(bps);

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
        assertEq(
            buyerAmount + usdc.balanceOf(recipient1) + usdc.balanceOf(recipient2),
            ESCROW
        );
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    /// Fuzz an N-way split (3..10 recipients) and assert every microUSDC is distributed.
    function testFuzzManyRecipientsNoDust(uint256 nSeed, uint256 salt) public {
        uint256 n = bound(nSeed, 3, 10);
        address[] memory r = new address[](n);
        uint256[] memory b = new uint256[](n);

        // Build n-1 positive shares each < the running remainder, last gets the rest
        uint256 remaining = 10000;
        for (uint256 i = 0; i < n - 1; i++) {
            uint256 maxShare = remaining - (n - 1 - i); // leave >=1 for each later recipient
            uint256 share = (uint256(keccak256(abi.encode(salt, i))) % maxShare) + 1;
            b[i] = share;
            remaining -= share;
            r[i] = address(uint160(0x300 + i));
        }
        b[n - 1] = remaining; // > 0 by construction
        r[n - 1] = address(uint160(0x300 + (n - 1)));

        CompletionEscrowContract escrow = _createAndFund(r, b);
        vm.prank(seller);
        escrow.markComplete();
        vm.prank(buyer);
        escrow.verifyComplete();

        uint256 total;
        for (uint256 i = 0; i < n; i++) {
            total += usdc.balanceOf(r[i]);
        }
        assertEq(total, ESCROW);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }
}
