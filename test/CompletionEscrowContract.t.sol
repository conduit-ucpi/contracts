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
    address public leadSupplier = address(0x2);
    address public arbiter = address(0x3);
    address public payee1 = address(0x11);
    address public payee2 = address(0x12);
    address public other = address(0x4);

    uint256 public constant AMOUNT = 1000 * 10**6; // 1000 USDC
    uint256 public CREATOR_FEE; // 1% of AMOUNT
    uint256 public ESCROW;      // AMOUNT - CREATOR_FEE
    string public description = "Test completion escrow";

    function setUp() public {
        usdc = new MockERC20();
        CompletionEscrowContract implementation = new CompletionEscrowContract();
        factory = new CompletionEscrowContractFactory(arbiter, address(implementation), address(0));

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
        r[0] = payee1;
        b[0] = 10000;
    }

    function _two(uint256 bps1) internal view returns (address[] memory r, uint256[] memory b) {
        r = new address[](2);
        b = new uint256[](2);
        r[0] = payee1;
        r[1] = payee2;
        b[0] = bps1;
        b[1] = 10000 - bps1;
    }

    // ── create / fund helpers ────────────────────────────────────────────────

    function _create(address[] memory r, uint256[] memory b) internal returns (CompletionEscrowContract) {
        vm.prank(buyer);
        address addr = factory.createEscrowContract(
            address(usdc), buyer, leadSupplier, AMOUNT, r, b, address(0), description
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

    function testCreateSinglePayee() public {
        CompletionEscrowContract escrow = _createSingle();
        (address[] memory r, uint256[] memory b) = escrow.getPayees();
        assertEq(r.length, 1);
        assertEq(r[0], payee1);
        assertEq(b[0], 10000);
        assertEq(escrow.BUYER(), buyer);
        assertEq(escrow.LEAD_SUPPLIER(), leadSupplier);
        assertEq(escrow.ARBITER(), arbiter);
        assertTrue(escrow.canDeposit());
    }

    function testCreateTwoPayees() public {
        (address[] memory r, uint256[] memory b) = _two(6000);
        CompletionEscrowContract escrow = _create(r, b);
        (address[] memory gr, uint256[] memory gb) = escrow.getPayees();
        assertEq(gr.length, 2);
        assertEq(gr[0], payee1);
        assertEq(gr[1], payee2);
        assertEq(gb[0], 6000);
        assertEq(gb[1], 4000);
    }

    function testCreateRevertsBpsSumTooLow() public {
        (address[] memory r, uint256[] memory b) = _two(5000);
        b[1] = 4000; // sum 9000
        vm.prank(buyer);
        vm.expectRevert(CompletionEscrowContract.PayeeBpsSumNot10000.selector);
        factory.createEscrowContract(
            address(usdc), buyer, leadSupplier, AMOUNT, r, b, address(0), description
        );
    }

    function testCreateRevertsBpsSumTooHigh() public {
        (address[] memory r, uint256[] memory b) = _two(5000);
        b[1] = 6000; // sum 11000
        vm.prank(buyer);
        vm.expectRevert(CompletionEscrowContract.PayeeBpsSumNot10000.selector);
        factory.createEscrowContract(
            address(usdc), buyer, leadSupplier, AMOUNT, r, b, address(0), description
        );
    }

    function testCreateRevertsZeroBps() public {
        address[] memory r = new address[](2);
        uint256[] memory b = new uint256[](2);
        r[0] = payee1; r[1] = payee2;
        b[0] = 10000; b[1] = 0; // a zero share is not allowed
        vm.prank(buyer);
        vm.expectRevert(CompletionEscrowContract.InvalidPayeeBps.selector);
        factory.createEscrowContract(
            address(usdc), buyer, leadSupplier, AMOUNT, r, b, address(0), description
        );
    }

    function testCreateRevertsZeroPayeeAddress() public {
        address[] memory r = new address[](2);
        uint256[] memory b = new uint256[](2);
        r[0] = payee1; r[1] = address(0);
        b[0] = 5000; b[1] = 5000;
        vm.prank(buyer);
        vm.expectRevert(CompletionEscrowContract.InvalidPayeeAddress.selector);
        factory.createEscrowContract(
            address(usdc), buyer, leadSupplier, AMOUNT, r, b, address(0), description
        );
    }

    function testCreateRevertsNoPayees() public {
        address[] memory r = new address[](0);
        uint256[] memory b = new uint256[](0);
        vm.prank(buyer);
        vm.expectRevert(CompletionEscrowContract.NoPayees.selector);
        factory.createEscrowContract(
            address(usdc), buyer, leadSupplier, AMOUNT, r, b, address(0), description
        );
    }

    function testCreateRevertsArrayLengthMismatch() public {
        address[] memory r = new address[](2);
        uint256[] memory b = new uint256[](1);
        r[0] = payee1; r[1] = payee2;
        b[0] = 10000;
        vm.prank(buyer);
        vm.expectRevert(CompletionEscrowContract.PayeeArrayLengthMismatch.selector);
        factory.createEscrowContract(
            address(usdc), buyer, leadSupplier, AMOUNT, r, b, address(0), description
        );
    }

    function testCreateRevertsTooManyPayees() public {
        uint256 n = 11; // MAX_PAYEES is 10
        address[] memory r = new address[](n);
        uint256[] memory b = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            r[i] = address(uint160(0x100 + i));
            b[i] = (i == n - 1) ? 10000 - (1000 * (n - 1)) : 1000;
        }
        vm.prank(buyer);
        vm.expectRevert(CompletionEscrowContract.TooManyPayees.selector);
        factory.createEscrowContract(
            address(usdc), buyer, leadSupplier, AMOUNT, r, b, address(0), description
        );
    }

    function testImplementationCannotBeInitialized() public {
        CompletionEscrowContract impl = new CompletionEscrowContract();
        vm.expectRevert(CompletionEscrowContract.NotInitialized.selector);
        impl.isFunded();
    }

    // ── fee schedule (flat 1%, no minimum, no thresholds) ───────────────────

    function testFeeIsFlatOnePercent() public {
        CompletionEscrowContract escrow = _createSingle();
        assertEq(escrow.CREATOR_FEE(), AMOUNT / 100);
    }

    function testFeeFloorsToZeroForTinyAmounts() public {
        // Any amount below 100 base units floors to a zero fee - and, unlike the
        // legacy schedule, small amounts never revert creation.
        (address[] memory r, uint256[] memory b) = _single();
        vm.prank(buyer);
        address addr = factory.createEscrowContract(
            address(usdc), buyer, leadSupplier, 99, r, b, address(0), description
        );
        assertEq(CompletionEscrowContract(addr).CREATOR_FEE(), 0);
    }

    function testFeeSmallAmountsDoNotRevert() public {
        // The legacy factory reverted between the dust threshold and the minimum
        // fee (AmountTooSmallForMinFee). The flat schedule accepts every amount.
        (address[] memory r, uint256[] memory b) = _single();
        uint256 amount = 200_000; // 0.20 USDC - inside the legacy revert band
        vm.prank(buyer);
        address addr = factory.createEscrowContract(
            address(usdc), buyer, leadSupplier, amount, r, b, address(0), description
        );
        assertEq(CompletionEscrowContract(addr).CREATOR_FEE(), amount / 100);
    }

    // ── child creation (fee-exempt, owner only) ─────────────────────────────

    function _createChild() internal returns (CompletionEscrowContract) {
        (address[] memory r, uint256[] memory b) = _single();
        vm.prank(arbiter); // arbiter is the factory OWNER in setUp
        address addr = factory.createChildEscrowContract(
            address(usdc), buyer, leadSupplier, AMOUNT, r, b, address(0), description
        );
        return CompletionEscrowContract(addr);
    }

    function testChildCreateHasZeroFee() public {
        CompletionEscrowContract child = _createChild();
        assertEq(child.CREATOR_FEE(), 0);
        assertEq(child.AMOUNT(), AMOUNT);
    }

    function testChildCreateRevertsForNonOwner() public {
        (address[] memory r, uint256[] memory b) = _single();
        vm.prank(buyer);
        vm.expectRevert(CompletionEscrowContractFactory.OnlyOwner.selector);
        factory.createChildEscrowContract(
            address(usdc), buyer, leadSupplier, AMOUNT, r, b, address(0), description
        );
    }

    function testChildDepositPaysNoFee() public {
        CompletionEscrowContract child = _createChild();
        vm.prank(buyer);
        usdc.approve(address(child), AMOUNT);
        vm.prank(buyer);
        child.depositFunds();
        // The full amount stays in escrow; the fee payee gets nothing.
        assertEq(usdc.balanceOf(address(child)), AMOUNT);
        assertEq(usdc.balanceOf(arbiter), 0);
    }

    function testChildFullAmountPaidToPayeeOnCompletion() public {
        CompletionEscrowContract child = _createChild();
        vm.prank(buyer);
        usdc.approve(address(child), AMOUNT);
        vm.prank(buyer);
        child.depositFunds();
        vm.prank(leadSupplier);
        child.markComplete();
        vm.prank(buyer);
        child.verifyComplete();
        assertEq(usdc.balanceOf(payee1), AMOUNT);
    }

    function testChildCreateStillValidates() public {
        // The fee-exempt path shares the root path's validation.
        (address[] memory r, uint256[] memory b) = _single();
        vm.prank(arbiter);
        vm.expectRevert(CompletionEscrowContractFactory.BuyerAndLeadSupplierMustDiffer.selector);
        factory.createChildEscrowContract(
            address(usdc), buyer, buyer, AMOUNT, r, b, address(0), description
        );
    }

    // ── deposit ─────────────────────────────────────────────────────────────

    function testDeposit() public {
        CompletionEscrowContract escrow = _createAndFundSingle();
        assertTrue(escrow.isFunded());
        assertEq(usdc.balanceOf(address(escrow)), ESCROW);
        assertEq(usdc.balanceOf(arbiter), CREATOR_FEE);
    }

    function testDepositRevertsTwice() public {
        CompletionEscrowContract escrow = _createAndFundSingle();
        vm.prank(buyer);
        usdc.approve(address(escrow), AMOUNT);
        vm.prank(buyer);
        vm.expectRevert(CompletionEscrowContract.AlreadyFundedOrClaimed.selector);
        escrow.depositFunds();
    }

    function testDepositOnlyBuyerOrArbiter() public {
        CompletionEscrowContract escrow = _createSingle();
        vm.prank(other);
        vm.expectRevert(CompletionEscrowContract.OnlyBuyerOrArbiter.selector);
        escrow.depositFunds();
    }

    // ── self-fund from balance (tree fan-out) ────────────────────────────────

    function testCheckAndActivateFromBalance() public {
        CompletionEscrowContract escrow = _createSingle();
        assertFalse(escrow.canActivateFromBalance());

        usdc.mint(address(escrow), AMOUNT);
        assertTrue(escrow.canActivateFromBalance());
        assertEq(escrow.tokenBalance(), AMOUNT);

        vm.prank(arbiter);
        escrow.checkAndActivate();

        assertTrue(escrow.isFunded());
        assertEq(escrow.tokenBalance(), ESCROW);
        assertEq(usdc.balanceOf(arbiter), CREATOR_FEE);
    }

    function testCheckAndActivateRevertsInsufficientBalance() public {
        CompletionEscrowContract escrow = _createSingle();
        usdc.mint(address(escrow), AMOUNT - 1);
        vm.prank(arbiter);
        vm.expectRevert(CompletionEscrowContract.InsufficientBalanceToActivate.selector);
        escrow.checkAndActivate();
    }

    function testCheckAndActivateRevertsIfAlreadyFunded() public {
        CompletionEscrowContract escrow = _createAndFundSingle();
        usdc.mint(address(escrow), AMOUNT);
        vm.prank(arbiter);
        vm.expectRevert(CompletionEscrowContract.AlreadyFundedOrClaimed.selector);
        escrow.checkAndActivate();
    }

    function testCheckAndActivateOnlyBuyerOrArbiter() public {
        CompletionEscrowContract escrow = _createSingle();
        usdc.mint(address(escrow), AMOUNT);
        vm.prank(other);
        vm.expectRevert(CompletionEscrowContract.OnlyBuyerOrArbiter.selector);
        escrow.checkAndActivate();
    }

    /// Full tree: a parent node pays a child node, the child self-funds, then completes.
    function testTreeFanOutChildSelfFunds() public {
        address finalPayee = address(0x21);
        address otherPayee = address(0x22);

        uint256 parentAmount = 2000 * 10**6;
        uint256 childAmount = 990 * 10**6;

        (address[] memory childR, uint256[] memory childB) = _single();
        childR[0] = finalPayee;

        vm.prank(buyer);
        address childAddr = factory.createEscrowContract(
            address(usdc), buyer, leadSupplier, childAmount, childR, childB, address(0), "child"
        );
        CompletionEscrowContract child = CompletionEscrowContract(childAddr);

        // Parent: 2000 USDC, 50/50 between the child and another payee
        address[] memory parentR = new address[](2);
        uint256[] memory parentB = new uint256[](2);
        parentR[0] = childAddr; parentR[1] = otherPayee;
        parentB[0] = 5000; parentB[1] = 5000;

        vm.prank(buyer);
        address parentAddr = factory.createEscrowContract(
            address(usdc), buyer, leadSupplier, parentAmount, parentR, parentB, address(0), "parent"
        );
        CompletionEscrowContract parent = CompletionEscrowContract(parentAddr);

        vm.prank(buyer);
        usdc.approve(parentAddr, parentAmount);
        vm.prank(buyer);
        parent.depositFunds();
        vm.prank(leadSupplier);
        parent.markComplete();
        vm.prank(buyer);
        parent.verifyComplete();

        // Parent ESCROW = 1980; child (50%) receives exactly its AMOUNT of 990
        assertEq(usdc.balanceOf(childAddr), childAmount);
        assertTrue(child.canActivateFromBalance());

        vm.prank(arbiter);
        child.checkAndActivate();
        assertTrue(child.isFunded());

        uint256 childEscrow = childAmount - (childAmount / 100);
        assertEq(usdc.balanceOf(childAddr), childEscrow);

        vm.prank(leadSupplier);
        child.markComplete();
        vm.prank(buyer);
        child.verifyComplete();

        assertEq(usdc.balanceOf(finalPayee), childEscrow);
        assertEq(usdc.balanceOf(childAddr), 0);
    }

    // ── happy path: dual verify ─────────────────────────────────────────────

    function testHappyPathSinglePayee() public {
        CompletionEscrowContract escrow = _createAndFundSingle();

        vm.prank(leadSupplier);
        escrow.markComplete();
        assertTrue(escrow.isAwaitingVerification());

        vm.prank(buyer);
        escrow.verifyComplete();

        assertTrue(escrow.isClaimed());
        assertEq(usdc.balanceOf(payee1), ESCROW);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function testHappyPathTwoPayeesEvenSplit() public {
        CompletionEscrowContract escrow = _createAndFundTwo(5000);

        vm.prank(leadSupplier);
        escrow.markComplete();
        vm.prank(buyer);
        escrow.verifyComplete();

        uint256 expected1 = (ESCROW * 5000) / 10000;
        assertEq(usdc.balanceOf(payee1), expected1);
        assertEq(usdc.balanceOf(payee2), ESCROW - expected1);
        assertEq(usdc.balanceOf(payee1) + usdc.balanceOf(payee2), ESCROW);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function testHappyPathTwoPayeesUnevenSplit() public {
        // 33.33% split produces rounding dust; the last payee absorbs it, nothing stuck
        CompletionEscrowContract escrow = _createAndFundTwo(3333);

        vm.prank(leadSupplier);
        escrow.markComplete();
        vm.prank(buyer);
        escrow.verifyComplete();

        uint256 expected1 = (ESCROW * 3333) / 10000;
        assertEq(usdc.balanceOf(payee1), expected1);
        assertEq(usdc.balanceOf(payee2), ESCROW - expected1);
        assertEq(usdc.balanceOf(payee1) + usdc.balanceOf(payee2), ESCROW);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function testHappyPathManyPayeesNoDust() public {
        // Ten payees with deliberately uneven, prime-ish shares to force rounding dust
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
        vm.prank(leadSupplier);
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

    function testMarkCompleteOnlyLeadSupplier() public {
        CompletionEscrowContract escrow = _createAndFundSingle();
        vm.prank(buyer);
        vm.expectRevert(CompletionEscrowContract.OnlyLeadSupplier.selector);
        escrow.markComplete();
    }

    function testMarkCompleteRequiresFunded() public {
        CompletionEscrowContract escrow = _createSingle();
        vm.prank(leadSupplier);
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
        vm.prank(leadSupplier);
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
            address(usdc), buyer, leadSupplier, AMOUNT, r, b, verifier, description
        );
        CompletionEscrowContract escrow = CompletionEscrowContract(addr);
        assertEq(escrow.VERIFIER(), verifier);
        _fund(escrow);

        vm.prank(leadSupplier);
        escrow.markComplete();

        // The buyer can no longer verify - only the nominated verifier can
        vm.prank(buyer);
        vm.expectRevert(CompletionEscrowContract.OnlyVerifier.selector);
        escrow.verifyComplete();

        vm.prank(verifier);
        escrow.verifyComplete();
        assertTrue(escrow.isClaimed());
        assertEq(usdc.balanceOf(payee1), ESCROW);
    }

    function testNominatedVerifierStillLetsBuyerDispute() public {
        address verifier = address(0x31);
        (address[] memory r, uint256[] memory b) = _single();
        vm.prank(buyer);
        address addr = factory.createEscrowContract(
            address(usdc), buyer, leadSupplier, AMOUNT, r, b, verifier, description
        );
        CompletionEscrowContract escrow = CompletionEscrowContract(addr);
        _fund(escrow);

        vm.prank(buyer);
        escrow.raiseDispute();
        assertTrue(escrow.isDisputed());
    }

    function testCreateRevertsVerifierIsLeadSupplier() public {
        (address[] memory r, uint256[] memory b) = _single();
        vm.prank(buyer);
        vm.expectRevert(CompletionEscrowContractFactory.VerifierCannotBeLeadSupplier.selector);
        factory.createEscrowContract(
            address(usdc), buyer, leadSupplier, AMOUNT, r, b, leadSupplier, description
        );
    }

    // ── no deadline: time alone changes nothing ─────────────────────────────

    /// Time never moves money. Funds sit until an affirmative act, however long that takes.
    function testTimePassingNeverReleasesFunds() public {
        CompletionEscrowContract escrow = _createAndFundSingle();
        vm.warp(block.timestamp + 3650 days);

        assertEq(usdc.balanceOf(address(escrow)), ESCROW);
        assertEq(usdc.balanceOf(payee1), 0);

        // ...and the dual-verify path still works, a decade later
        vm.prank(leadSupplier);
        escrow.markComplete();
        vm.prank(buyer);
        escrow.verifyComplete();
        assertEq(usdc.balanceOf(payee1), ESCROW);
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
        vm.prank(leadSupplier);
        escrow.markComplete();
        vm.prank(buyer);
        escrow.raiseDispute();
        assertTrue(escrow.isDisputed());
    }

    function testDisputeOnlyBuyer() public {
        CompletionEscrowContract escrow = _createAndFundSingle();
        vm.prank(leadSupplier);
        vm.expectRevert(CompletionEscrowContract.OnlyBuyer.selector);
        escrow.raiseDispute();
    }

    /// The buyer's dispute right has no deadline - it survives arbitrary delay.
    function testDisputeStillAllowedAfterYears() public {
        CompletionEscrowContract escrow = _createAndFundSingle();
        vm.warp(block.timestamp + 3650 days);

        assertTrue(escrow.canDispute());
        vm.prank(buyer);
        escrow.raiseDispute();
        assertTrue(escrow.isDisputed());
    }

    /// Same, once the lead supplier has marked complete but nobody has verified.
    function testDisputeStillAllowedAfterYearsWhenAwaitingVerification() public {
        CompletionEscrowContract escrow = _createAndFundSingle();
        vm.prank(leadSupplier);
        escrow.markComplete();
        vm.warp(block.timestamp + 3650 days);

        assertTrue(escrow.canDispute());
        vm.prank(buyer);
        escrow.raiseDispute();
        assertTrue(escrow.isDisputed());
    }

    /// The dispute right ends when the money moves, not on a date.
    function testDisputeRevertsAfterPayout() public {
        CompletionEscrowContract escrow = _createAndFundSingle();
        vm.prank(leadSupplier);
        escrow.markComplete();
        vm.prank(buyer);
        escrow.verifyComplete();

        assertFalse(escrow.canDispute());
        vm.prank(buyer);
        vm.expectRevert(CompletionEscrowContract.CannotDisputeNow.selector);
        escrow.raiseDispute();
    }

    function testDisputeRevertsWrongState() public {
        CompletionEscrowContract escrow = _createSingle();
        vm.prank(buyer);
        vm.expectRevert(CompletionEscrowContract.CannotDisputeNow.selector);
        escrow.raiseDispute();
    }

    function testDisputeResolutionBuyerLeadSupplierConsensus() public {
        CompletionEscrowContract escrow = _createAndFundTwo(6000);
        vm.prank(buyer);
        escrow.raiseDispute();

        // buyer gets 40% refund, supplier side (60%) split between payees
        vm.prank(buyer);
        escrow.submitResolutionVote(40);
        vm.prank(leadSupplier);
        escrow.submitResolutionVote(40);

        assertTrue(escrow.consensusReached());
        assertTrue(escrow.isClaimed());

        uint256 buyerAmount = (ESCROW * 40) / 100;
        uint256 supplierAmount = ESCROW - buyerAmount;
        uint256 expected1 = (supplierAmount * 6000) / 10000;

        assertEq(usdc.balanceOf(buyer), buyerAmount + (AMOUNT * 10 - AMOUNT)); // refund + leftover mint
        assertEq(usdc.balanceOf(payee1), expected1);
        assertEq(usdc.balanceOf(payee2), supplierAmount - expected1);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function testDisputeResolutionAdminBreaksTie() public {
        CompletionEscrowContract escrow = _createAndFundSingle();
        vm.prank(buyer);
        escrow.raiseDispute();

        vm.prank(leadSupplier);
        escrow.submitResolutionVote(0); // supplier wants 0% to buyer
        vm.prank(arbiter);
        escrow.submitResolutionVote(0); // admin agrees -> consensus

        assertTrue(escrow.isClaimed());
        assertEq(usdc.balanceOf(payee1), ESCROW);
    }

    function testDisputeFullRefundToBuyer() public {
        CompletionEscrowContract escrow = _createAndFundTwo(5000);
        uint256 buyerBefore = usdc.balanceOf(buyer);
        vm.prank(buyer);
        escrow.raiseDispute();

        vm.prank(buyer);
        escrow.submitResolutionVote(100);
        vm.prank(arbiter);
        escrow.submitResolutionVote(100);

        assertEq(usdc.balanceOf(buyer), buyerBefore + ESCROW);
        assertEq(usdc.balanceOf(payee1), 0);
        assertEq(usdc.balanceOf(payee2), 0);
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

        vm.prank(leadSupplier);
        escrow.markComplete();
        vm.prank(buyer);
        escrow.verifyComplete();

        uint256 expected1 = (ESCROW * bps) / 10000;
        assertEq(usdc.balanceOf(payee1), expected1);
        assertEq(usdc.balanceOf(payee2), ESCROW - expected1);
        assertEq(usdc.balanceOf(payee1) + usdc.balanceOf(payee2), ESCROW);
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
        vm.prank(arbiter);
        escrow.submitResolutionVote(pct);

        uint256 buyerAmount = (ESCROW * pct) / 100;
        uint256 supplierAmount = ESCROW - buyerAmount;
        uint256 expected1 = (supplierAmount * bps) / 10000;

        assertEq(usdc.balanceOf(payee1), expected1);
        assertEq(usdc.balanceOf(payee2), supplierAmount - expected1);
        assertEq(
            buyerAmount + usdc.balanceOf(payee1) + usdc.balanceOf(payee2),
            ESCROW
        );
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    /// Fuzz an N-way split (3..10 payees) and assert every microUSDC is distributed.
    function testFuzzManyPayeesNoDust(uint256 nSeed, uint256 salt) public {
        uint256 n = bound(nSeed, 3, 10);
        address[] memory r = new address[](n);
        uint256[] memory b = new uint256[](n);

        // Build n-1 positive shares each < the running remainder, last gets the rest
        uint256 remaining = 10000;
        for (uint256 i = 0; i < n - 1; i++) {
            uint256 maxShare = remaining - (n - 1 - i); // leave >=1 for each later payee
            uint256 share = (uint256(keccak256(abi.encode(salt, i))) % maxShare) + 1;
            b[i] = share;
            remaining -= share;
            r[i] = address(uint160(0x300 + i));
        }
        b[n - 1] = remaining; // > 0 by construction
        r[n - 1] = address(uint160(0x300 + (n - 1)));

        CompletionEscrowContract escrow = _createAndFund(r, b);
        vm.prank(leadSupplier);
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
