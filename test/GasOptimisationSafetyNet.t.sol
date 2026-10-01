// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {EscrowContract} from "../src/EscrowContract.sol";
import {EscrowContractFactory} from "../src/EscrowContractFactory.sol";

/**
 * A minimal ERC20 whose decimals are chosen per instance, so the fee formula can be pinned
 * on 6-decimal and 18-decimal tokens alike. Balances are uint256, so it never limits the
 * range tests below: any narrowing that appears will be the escrow's.
 */
contract SafetyNetToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint8 public decimals;

    constructor(uint8 d) {
        decimals = d;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
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

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

/// The same token with no decimals() at all: the factory must fall back to 18.
contract NoDecimalsSafetyNetToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
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

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

/**
 * THE SAFETY NET FOR THE GAS WORK, written before it.
 *
 * Escrow creation costs ~477k gas, and ~331k of that is fifteen fresh storage slots written
 * by `initialize`. The planned savings are:
 *
 *   1. Drop the five "not voted" sentinels (255) written at init         ~110k
 *   2. Move FEE_RECIPIENT off the clone and onto the implementation        ~22k
 *   3. Stop writing createdAt                                              ~22k  ⚠️ see below
 *   4. Pack AMOUNT / CREATOR_FEE / EXPIRY_TIMESTAMP into fewer slots     ~60-90k
 *
 * Every one of those changes the contract's INSIDES. None of them may change what the
 * contract SAYS, because other things read it:
 *
 *   • chainservice reads `createdAt` on every escrow it lists, and uses "does createdAt exist"
 *     to tell a legacy escrow from a current one (ArbiterQueryService). Dropping the getter,
 *     or returning 0, misclassifies every escrow. So lever 3 is only allowed if the getter
 *     still answers the creation timestamp — from an event, from a packed slot, from wherever.
 *   • chainservice reads `resolvedBuyerPercentage` and treats 255 as "never disputed"
 *     (MarketplaceReader.NEVER_DISPUTED). It reads `resolutionVotes` and `FEE_RECIPIENT` and
 *     `FACTORY` too. Whatever the storage becomes, those getters keep their meaning.
 *   • The webapp derives the CREATE2 address from the terms. Packing must not touch the salt.
 *
 * ⚠️ EVERY TEST HERE PASSES TODAY. That is the point: they describe the behaviour that must
 *    survive the optimisation, in terms of what a caller can observe, never in terms of how
 *    the storage is laid out. A test here that fails after the gas work is a regression, not
 *    an outdated test — with one deliberate exception, the gas ceilings at the bottom, which
 *    are meant to be LOWERED once the work lands so the savings cannot quietly erode.
 */
contract GasOptimisationSafetyNetTest is Test {
    EscrowContractFactory internal factory;
    EscrowContract internal implementation;
    SafetyNetToken internal usdc;

    address internal constant DEFAULT_ARBITER = address(0xDEFA17);
    address internal owner = address(0xA11CE);
    address internal feeRecipient = address(0xFEE);
    address internal buyer = address(0xB0B);
    address internal seller = address(0x5E11E2);
    address internal arbiter = address(0xA3B1);
    address internal relayer = address(0x2E1A);
    address internal stranger = address(0x57A9);

    uint256 internal constant AMOUNT = 1_000e6; // 1,000 USDC
    uint256 internal constant CREATION_TIME = 1_800_000_000;
    uint256 internal expiry = CREATION_TIME + 7 days;
    string internal description = "Order #48213 - Blue ceramic mug, 2 units";

    // Redeclared so expectEmit can name them; the signatures must match the contracts'.
    event ContractCreated(
        address indexed contractAddress,
        address indexed buyer,
        address indexed seller,
        uint256 amount,
        uint256 expiryTimestamp,
        string description
    );
    event FundsDeposited(address buyer, uint256 escrowAmount, uint256 timestamp);
    event PlatformFeeCollected(address recipient, uint256 feeAmount, uint256 timestamp);
    event FundsClaimed(address recipient, uint256 amount, uint256 timestamp);
    event DisputeResolved(uint256 buyerPercentage, uint256 sellerPercentage, uint256 timestamp);

    function setUp() public {
        vm.warp(CREATION_TIME);
        usdc = new SafetyNetToken(6);
        implementation = new EscrowContract(DEFAULT_ARBITER, bytes20(0));
        factory = new EscrowContractFactory(owner, address(implementation), feeRecipient, address(0), bytes20(0));
        usdc.mint(buyer, AMOUNT * 1_000);
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    /**
     * The platform fee the factory charges on a 6-decimal token, written out independently.
     */
    function expectedFee6(uint256 amount) internal pure returns (uint256) {
        if (amount <= 1_000) return 0; // ≤ 0.001 USDC: free
        uint256 minFee = 300_000; // 0.30 USDC
        uint256 onePercent = amount / 100;
        return onePercent > minFee ? onePercent : minFee;
    }

    function predicted(uint256 amount, uint256 expiryAt, bytes32 externalId) internal view returns (address) {
        return factory.getContractAddress(address(usdc), buyer, seller, amount, expiryAt, arbiter, externalId);
    }

    /**
     * The production path: the buyer pays the bare address, the relayer deploys onto it.
     */
    function fundAndCreate(uint256 amount, uint256 expiryAt, bytes32 externalId) internal returns (EscrowContract) {
        address at = predicted(amount, expiryAt, externalId);
        vm.prank(buyer);
        usdc.transfer(at, amount);
        vm.prank(relayer);
        address deployed =
            factory.createAndActivate(address(usdc), buyer, seller, amount, expiryAt, description, arbiter, externalId);
        assertEq(deployed, at, "deployed where the money was sent");
        return EscrowContract(deployed);
    }

    function funded() internal returns (EscrowContract) {
        return fundAndCreate(AMOUNT, expiry, keccak256("escrow"));
    }

    function disputed() internal returns (EscrowContract escrow) {
        escrow = funded();
        vm.prank(buyer);
        escrow.raiseDispute();
    }

    function vote(EscrowContract escrow, address who, uint256 pct) internal {
        vm.prank(who);
        escrow.submitResolutionVote(pct);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // A. The public surface other services read. Storage may move; answers may not.
    // ═════════════════════════════════════════════════════════════════════════

    function test_TheGettersServicesReadKeepTheirMeaning() public {
        EscrowContract escrow = funded();

        assertEq(escrow.FACTORY(), address(factory), "FACTORY: the factory that created it");
        assertEq(escrow.FEE_RECIPIENT(), feeRecipient, "FEE_RECIPIENT: where the fee went");
        assertEq(escrow.FEE_RECIPIENT(), factory.FEE_RECIPIENT(), "and it is the factory's recipient");
        assertEq(address(escrow.tokenAddress()), address(usdc));
        assertEq(escrow.BUYER(), buyer);
        assertEq(escrow.SELLER(), seller);
        assertEq(escrow.ARBITER(), arbiter);
        assertEq(escrow.AMOUNT(), AMOUNT);
        assertEq(escrow.EXPIRY_TIMESTAMP(), expiry);
        assertEq(escrow.CREATOR_FEE(), expectedFee6(AMOUNT));
        assertEq(escrow.createdAt(), CREATION_TIME, "createdAt: the creation block's timestamp");
        assertFalse(escrow.consensusReached());
        assertFalse(escrow.hasBeenSold());
    }

    /**
     * ⚠️ 255 IS AN API. chainservice strips `resolvedBuyerPercentage == 255` as "never
     *    disputed" and would show 255% to a user if the sentinel changed. `resolutionVotes`
     *    is read the same way. Re-encode the storage however you like; the getters answer 255.
     */
    function test_TheSentinelGettersAnswer255UntilThereIsSomethingToSay() public {
        EscrowContract escrow = funded();

        assertEq(escrow.resolvedBuyerPercentage(), 255, "never disputed");
        assertEq(escrow.resolutionVotes(buyer), 255, "buyer has not voted");
        assertEq(escrow.resolutionVotes(seller), 255, "seller has not voted");
        assertEq(escrow.resolutionVotes(arbiter), 255, "arbiter has not voted");
        // A stranger's slot is never written and never consulted; its value is not part of the API.

        vm.prank(buyer);
        escrow.raiseDispute();
        assertEq(escrow.resolvedBuyerPercentage(), 255, "disputed but unresolved is still 255");

        vote(escrow, buyer, 40);
        assertEq(escrow.resolutionVotes(buyer), 40);
        assertEq(escrow.resolutionVotes(seller), 255, "one vote does not change the other's answer");
        assertEq(escrow.resolvedBuyerPercentage(), 255);
    }

    function test_ResolvedPercentageStays255ThroughAnUndisputedLifetime() public {
        EscrowContract escrow = funded();
        vm.warp(expiry);
        vm.prank(relayer);
        escrow.claimFunds();

        assertTrue(escrow.isClaimed());
        assertEq(escrow.resolvedBuyerPercentage(), 255, "claimed without a dispute is not resolved at 0% or 100%");
    }

    function test_GetContractInfoKeepsItsShapeAndValues() public {
        EscrowContract escrow = funded();
        vm.warp(CREATION_TIME + 1 days);

        (
            address b,
            address s,
            uint256 amount,
            uint256 expiryAt,
            uint8 state,
            uint256 now_,
            uint256 fee,
            uint256 createdAt,
            address token
        ) = escrow.getContractInfo();

        assertEq(b, buyer);
        assertEq(s, seller);
        assertEq(amount, AMOUNT);
        assertEq(expiryAt, expiry);
        assertEq(state, 1, "funded");
        assertEq(now_, CREATION_TIME + 1 days, "the current block, not the creation block");
        assertEq(fee, expectedFee6(AMOUNT));
        assertEq(createdAt, CREATION_TIME, "the creation block, not the current one");
        assertEq(token, address(usdc));
    }

    /**
     * createdAt is the CREATION time, not the funding time. On the counterfactual path the two
     * coincide, so this uses the legacy path where they can be pulled apart.
     */
    function test_CreatedAtIsWhenTheEscrowWasCreatedNotWhenItWasFunded() public {
        vm.prank(owner);
        address at = factory.createEscrowContract(
            address(usdc), buyer, seller, AMOUNT, expiry, description, arbiter, keccak256("legacy")
        );
        EscrowContract escrow = EscrowContract(at);
        assertEq(escrow.createdAt(), CREATION_TIME);

        vm.warp(CREATION_TIME + 2 days);
        vm.startPrank(buyer);
        usdc.approve(at, AMOUNT);
        escrow.depositFunds();
        vm.stopPrank();

        assertTrue(escrow.isFunded());
        assertEq(escrow.createdAt(), CREATION_TIME, "funding two days later does not move it");
        assertGt(escrow.createdAt(), 0, "chainservice treats a zero or missing createdAt as a legacy escrow");
    }

    function test_TheViewHelpersTrackTheLifecycle() public {
        EscrowContract escrow = funded();
        uint256 fee = expectedFee6(AMOUNT);

        assertTrue(escrow.isFunded());
        assertFalse(escrow.isExpired());
        assertFalse(escrow.canClaim());
        assertTrue(escrow.canDispute());
        assertFalse(escrow.canDeposit());
        assertFalse(escrow.isDisputed());
        assertFalse(escrow.isClaimed());
        assertFalse(escrow.hasActiveDispute());
        assertEq(escrow.maturity(), expiry);
        assertEq(escrow.recipient(), seller);
        assertEq(escrow.token(), address(usdc));
        assertEq(escrow.payoutAmount(), AMOUNT - fee, "what the seller will actually receive");

        vm.warp(expiry);
        assertTrue(escrow.isExpired());
        assertTrue(escrow.canClaim());
        assertFalse(escrow.canDispute(), "the window has closed");

        vm.prank(relayer);
        escrow.claimFunds();
        assertTrue(escrow.isClaimed());
        assertFalse(escrow.canClaim());
        assertTrue(escrow.isFunded(), "isFunded means funded at some point, and stays true after the claim");
        assertFalse(escrow.canDeposit());
    }

    // ═════════════════════════════════════════════════════════════════════════
    // B. Voting. The sentinel is 255 because 0 is a real vote. Any re-encoding must keep
    //    "has not voted" distinct from "voted for zero".
    // ═════════════════════════════════════════════════════════════════════════

    function test_AVoteOfZeroIsAVote() public {
        EscrowContract escrow = disputed();
        uint256 escrowed = AMOUNT - expectedFee6(AMOUNT);

        vote(escrow, buyer, 0);
        assertFalse(escrow.consensusReached(), "one vote is not consensus, even at zero");
        assertEq(escrow.resolutionVotes(buyer), 0, "and it is recorded as zero, not as absent");

        vote(escrow, seller, 0);
        assertTrue(escrow.consensusReached(), "two matching zeros are consensus");
        assertEq(escrow.resolvedBuyerPercentage(), 0);
        assertEq(usdc.balanceOf(buyer), AMOUNT * 1_000 - AMOUNT, "buyer gets nothing back");
        assertEq(usdc.balanceOf(seller), escrowed, "seller gets everything but the fee");
        assertTrue(escrow.isClaimed());
    }

    function test_AVoteOfZeroDoesNotMatchAnUncastVote() public {
        EscrowContract escrow = disputed();

        // If "not voted" were ever stored as 0, this buyer vote would match the seller's
        // untouched slot and refund nothing to the buyer without the seller ever agreeing.
        vote(escrow, buyer, 0);
        assertFalse(escrow.consensusReached());
        assertEq(escrow.resolutionVotes(seller), 255);
        assertEq(escrow.resolutionVotes(arbiter), 255);

        vote(escrow, seller, 50);
        assertFalse(escrow.consensusReached(), "0 and 50 disagree");

        vote(escrow, arbiter, 0);
        assertTrue(escrow.consensusReached(), "buyer and arbiter agree on zero");
        assertEq(escrow.resolvedBuyerPercentage(), 0);
    }

    function test_AVoteOfOneHundredRefundsEverythingButTheFee() public {
        EscrowContract escrow = disputed();
        uint256 escrowed = AMOUNT - expectedFee6(AMOUNT);
        uint256 buyerBefore = usdc.balanceOf(buyer);

        vote(escrow, seller, 100);
        vote(escrow, buyer, 100);

        assertEq(escrow.resolvedBuyerPercentage(), 100);
        assertEq(usdc.balanceOf(buyer), buyerBefore + escrowed);
        assertEq(usdc.balanceOf(seller), 0);
        assertEq(usdc.balanceOf(feeRecipient), expectedFee6(AMOUNT), "the fee was taken at activation and stays taken");
    }

    function test_RevotingOverwritesAndTheLatestVoteCounts() public {
        EscrowContract escrow = disputed();

        vote(escrow, buyer, 30);
        vote(escrow, seller, 40);
        assertFalse(escrow.consensusReached());

        vote(escrow, buyer, 40);
        assertTrue(escrow.consensusReached());
        assertEq(escrow.resolvedBuyerPercentage(), 40);
    }

    function test_AnyPairOfPartiesCanReachConsensus() public {
        // buyer + arbiter, seller silent
        EscrowContract a = fundAndCreate(AMOUNT, expiry, keccak256("a"));
        vm.prank(buyer);
        a.raiseDispute();
        vote(a, buyer, 70);
        vote(a, arbiter, 70);
        assertEq(a.resolvedBuyerPercentage(), 70);

        // seller + arbiter, buyer silent
        EscrowContract b = fundAndCreate(AMOUNT, expiry, keccak256("b"));
        vm.prank(buyer);
        b.raiseDispute();
        vote(b, seller, 10);
        vote(b, arbiter, 10);
        assertEq(b.resolvedBuyerPercentage(), 10);
    }

    function test_AStrangerCannotVote() public {
        EscrowContract escrow = disputed();

        vm.prank(stranger);
        vm.expectRevert(EscrowContract.NotAuthorizedToVote.selector);
        escrow.submitResolutionVote(50);

        vote(escrow, buyer, 50);
        assertFalse(escrow.consensusReached(), "nothing a stranger did can count as the second vote");
    }

    function test_VotesAreOnlyAcceptedWhileDisputedAndUnresolved() public {
        EscrowContract escrow = funded();

        vm.prank(buyer);
        vm.expectRevert(EscrowContract.ContractMustBeDisputed.selector);
        escrow.submitResolutionVote(50);

        vm.prank(buyer);
        escrow.raiseDispute();

        vm.prank(buyer);
        vm.expectRevert(EscrowContract.InvalidPercentage.selector);
        escrow.submitResolutionVote(101);

        vote(escrow, buyer, 50);
        vote(escrow, seller, 50);

        // Resolution moves the escrow to claimed, so a late vote is refused as "not disputed".
        vm.prank(arbiter);
        vm.expectRevert(EscrowContract.ContractMustBeDisputed.selector);
        escrow.submitResolutionVote(50);
    }

    /**
     * ⚠️ WITH NO ARBITER THERE IS NO THIRD VOTE. The arbiter's vote is read from
     *    `resolutionVotes[ARBITER]`, and when ARBITER is address(0) that slot must never be
     *    allowed to "agree" with anybody, whatever value happens to sit in it.
     */
    function test_AnEvictedArbiterLeavesNoVoteBehindAndNoSlotToMatch() public {
        EscrowContract escrow = disputed();

        vote(escrow, arbiter, 40); // the arbiter votes, then goes silent
        vm.warp(block.timestamp + escrow.ARBITER_SILENCE_TIMEOUT() + 1);
        vm.prank(buyer);
        escrow.evictArbiter();
        assertEq(escrow.ARBITER(), address(0));

        vote(escrow, buyer, 40);
        assertFalse(escrow.consensusReached(), "the evicted arbiter's 40 must not count");
        assertEq(escrow.resolutionVotes(address(0)), 255);

        vote(escrow, seller, 40);
        assertTrue(escrow.consensusReached(), "buyer and seller can still agree on their own");
        assertEq(escrow.resolvedBuyerPercentage(), 40);
    }

    /**
     * ⚠️ A RESEATED ARBITER STARTS WITH NO VOTE. `_seatArbiter` resets the seat's vote to
     *    "not voted" precisely so a stale vote from before an eviction cannot resolve a dispute
     *    the moment its author is seated again. Whatever the new encoding, that reset stays.
     */
    function test_AReseatedArbiterStartsWithNoVote() public {
        EscrowContract escrow = disputed();

        vote(escrow, arbiter, 30);
        vm.warp(block.timestamp + escrow.ARBITER_SILENCE_TIMEOUT() + 1);
        vm.prank(seller);
        escrow.evictArbiter();

        vm.prank(buyer);
        escrow.nominateArbiter(arbiter);
        vm.prank(seller);
        escrow.nominateArbiter(arbiter);
        assertEq(escrow.ARBITER(), arbiter, "seated again by agreement");
        assertEq(escrow.resolutionVotes(arbiter), 255, "with the old 30 wiped");

        vote(escrow, buyer, 30);
        assertFalse(escrow.consensusReached(), "the pre-eviction 30 must not resurface");

        vote(escrow, arbiter, 30);
        assertTrue(escrow.consensusReached());
    }

    function test_TheDefaultArbiterSeatedAfterTheWindowStartsWithNoVote() public {
        EscrowContract escrow = disputed();

        vm.warp(block.timestamp + escrow.ARBITER_SILENCE_TIMEOUT() + 1);
        vm.prank(buyer);
        escrow.evictArbiter();

        vm.warp(block.timestamp + escrow.NOMINATION_WINDOW() + 1);
        escrow.seatDefaultArbiter();
        assertEq(escrow.ARBITER(), DEFAULT_ARBITER);
        assertEq(escrow.resolutionVotes(DEFAULT_ARBITER), 255);

        vote(escrow, buyer, 55);
        assertFalse(escrow.consensusReached());
        vote(escrow, DEFAULT_ARBITER, 55);
        assertEq(escrow.resolvedBuyerPercentage(), 55);
    }

    function testFuzz_AnyAgreedPercentageSplitsTheEscrowExactly(uint8 pct) public {
        pct = uint8(bound(pct, 0, 100));
        EscrowContract escrow = disputed();
        uint256 escrowed = AMOUNT - expectedFee6(AMOUNT);
        uint256 buyerBefore = usdc.balanceOf(buyer);

        vote(escrow, seller, pct);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit DisputeResolved(pct, 100 - pct, block.timestamp);
        vote(escrow, buyer, pct);

        uint256 buyerShare = (escrowed * pct) / 100;
        assertEq(usdc.balanceOf(buyer), buyerBefore + buyerShare);
        assertEq(usdc.balanceOf(seller), escrowed - buyerShare);
        assertEq(usdc.balanceOf(address(escrow)), 0, "nothing stranded");
        assertEq(escrow.resolvedBuyerPercentage(), pct);
        assertTrue(escrow.isClaimed());
    }

    // ═════════════════════════════════════════════════════════════════════════
    // C. The fee. Where it goes and how much, pinned from outside. If FEE_RECIPIENT moves
    //    onto the implementation, the factory's answer and the escrow's answer must still agree
    //    and the money must still land there.
    //
    //    ⚠️ Two factories sharing one implementation but wanting different recipients is NOT a
    //       supported deployment: CI ships a fresh implementation + factory pair every release.
    //       These tests do not pin that shape, deliberately.
    // ═════════════════════════════════════════════════════════════════════════

    function test_TheFeeLandsAtTheFactoryRecipientOnActivation() public {
        uint256 fee = expectedFee6(AMOUNT);
        bytes32 id = keccak256("fee");
        address at = predicted(AMOUNT, expiry, id);
        vm.prank(buyer);
        usdc.transfer(at, AMOUNT);

        vm.expectEmit(true, true, true, true, at);
        emit FundsDeposited(buyer, AMOUNT - fee, block.timestamp);
        vm.expectEmit(true, true, true, true, at);
        emit PlatformFeeCollected(feeRecipient, fee, block.timestamp);
        vm.prank(relayer);
        factory.createAndActivate(address(usdc), buyer, seller, AMOUNT, expiry, description, arbiter, id);

        assertEq(usdc.balanceOf(feeRecipient), fee);
        assertEq(usdc.balanceOf(at), AMOUNT - fee, "the escrow holds the rest");
    }

    function test_TheFeeIsPaidExactlyOnceAcrossTheLifecycle() public {
        EscrowContract escrow = funded();
        uint256 fee = expectedFee6(AMOUNT);

        vm.warp(expiry);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit FundsClaimed(seller, AMOUNT - fee, block.timestamp);
        vm.prank(relayer);
        escrow.claimFunds();

        assertEq(usdc.balanceOf(feeRecipient), fee, "once, at activation");
        assertEq(usdc.balanceOf(seller), AMOUNT - fee, "the seller gets the rest at maturity");
        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertEq(
            usdc.balanceOf(seller) + usdc.balanceOf(feeRecipient), AMOUNT, "what the buyer paid, all accounted for"
        );
    }

    function test_AnInstantTransferPaysFeeAndSellerInTheSameTransaction() public {
        uint256 fee = expectedFee6(AMOUNT);
        bytes32 id = keccak256("instant");
        address at = factory.getContractAddress(address(usdc), buyer, seller, AMOUNT, 0, arbiter, id);
        vm.prank(buyer);
        usdc.transfer(at, AMOUNT);

        vm.prank(relayer);
        factory.createAndActivate(address(usdc), buyer, seller, AMOUNT, 0, description, arbiter, id);

        assertEq(usdc.balanceOf(feeRecipient), fee);
        assertEq(usdc.balanceOf(seller), AMOUNT - fee);
        assertEq(usdc.balanceOf(at), 0);
        assertTrue(EscrowContract(at).isClaimed());
        assertFalse(EscrowContract(at).canDispute());
    }

    /**
     * max(1% of amount, 0.30 of one token); free at or below 0.001; refused between.
     */
    function test_TheFeeFormulaOnASixDecimalToken() public {
        assertEq(fundAndCreate(1_000, expiry, keccak256("free")).CREATOR_FEE(), 0, "0.001 USDC is free");
        assertEq(
            fundAndCreate(25e6, expiry, keccak256("min")).CREATOR_FEE(), 300_000, "25 USDC: the 0.30 minimum beats 1%"
        );
        assertEq(fundAndCreate(30e6, expiry, keccak256("tie")).CREATOR_FEE(), 300_000, "30 USDC: 1% equals the minimum");
        assertEq(fundAndCreate(AMOUNT, expiry, keccak256("pct")).CREATOR_FEE(), 10e6, "1,000 USDC: 1%");
        assertEq(fundAndCreate(123_456_789, expiry, keccak256("odd")).CREATOR_FEE(), 1_234_567, "1% rounds down");
        assertEq(
            fundAndCreate(300_001, expiry, keccak256("edge")).CREATOR_FEE(),
            300_000,
            "just above the minimum is allowed"
        );

        // Between free and the minimum fee there is no valid fee, so creation is refused. The
        // address function is pure and cannot know that; the refusal comes at creation.
        vm.prank(relayer);
        vm.expectRevert(EscrowContractFactory.AmountTooSmallForMinFee.selector);
        factory.createAndActivate(
            address(usdc), buyer, seller, 200_000, expiry, description, arbiter, keccak256("small")
        );
        vm.prank(relayer);
        vm.expectRevert(EscrowContractFactory.AmountTooSmallForMinFee.selector);
        factory.createAndActivate(
            address(usdc), buyer, seller, 300_000, expiry, description, arbiter, keccak256("at-min")
        );
    }

    function test_TheFeeFormulaOnAnEighteenDecimalToken() public {
        SafetyNetToken dai = new SafetyNetToken(18);
        dai.mint(buyer, 10_000e18);
        bytes32 id = keccak256("dai");
        address at = factory.getContractAddress(address(dai), buyer, seller, 1_000e18, expiry, arbiter, id);
        vm.prank(buyer);
        dai.transfer(at, 1_000e18);
        vm.prank(relayer);
        factory.createAndActivate(address(dai), buyer, seller, 1_000e18, expiry, description, arbiter, id);

        assertEq(EscrowContract(at).CREATOR_FEE(), 10e18, "1% in the token's own decimals");
        assertEq(dai.balanceOf(feeRecipient), 10e18);

        bytes32 id2 = keccak256("dai-min");
        address at2 = factory.getContractAddress(address(dai), buyer, seller, 25e18, expiry, arbiter, id2);
        vm.prank(buyer);
        dai.transfer(at2, 25e18);
        vm.prank(relayer);
        factory.createAndActivate(address(dai), buyer, seller, 25e18, expiry, description, arbiter, id2);
        assertEq(EscrowContract(at2).CREATOR_FEE(), 0.3e18, "the 0.30 minimum, in 18 decimals");
    }

    function test_ATokenWithoutDecimalsIsTreatedAsEighteen() public {
        NoDecimalsSafetyNetToken odd = new NoDecimalsSafetyNetToken();
        odd.mint(buyer, 1_000e18);
        bytes32 id = keccak256("no-decimals");
        address at = factory.getContractAddress(address(odd), buyer, seller, 1_000e18, expiry, arbiter, id);
        vm.prank(buyer);
        odd.transfer(at, 1_000e18);
        vm.prank(relayer);
        factory.createAndActivate(address(odd), buyer, seller, 1_000e18, expiry, description, arbiter, id);

        assertEq(EscrowContract(at).CREATOR_FEE(), 10e18);
    }

    function test_AnEscrowPaysTheRecipientOfTheFactoryThatMadeIt() public {
        address otherRecipient = address(0xFEE2);
        EscrowContract otherImplementation = new EscrowContract(DEFAULT_ARBITER, bytes20(0));
        EscrowContractFactory otherFactory =
            new EscrowContractFactory(owner, address(otherImplementation), otherRecipient, address(0), bytes20(0));

        bytes32 id = keccak256("other");
        address at = otherFactory.getContractAddress(address(usdc), buyer, seller, AMOUNT, expiry, arbiter, id);
        vm.prank(buyer);
        usdc.transfer(at, AMOUNT);
        vm.prank(relayer);
        otherFactory.createAndActivate(address(usdc), buyer, seller, AMOUNT, expiry, description, arbiter, id);

        assertEq(EscrowContract(at).FEE_RECIPIENT(), otherRecipient);
        assertEq(usdc.balanceOf(otherRecipient), expectedFee6(AMOUNT));
        assertEq(usdc.balanceOf(feeRecipient), 0, "the first factory's recipient got nothing");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // D. Ranges. Packing shrinks the numbers' storage; it must not shrink what they can hold
    //    below what is pinned here, and the arithmetic on them must stay exact.
    // ═════════════════════════════════════════════════════════════════════════

    function test_ABillionUsdcIsExact() public {
        uint256 amount = 1_000_000_000e6;
        usdc.mint(buyer, amount);
        EscrowContract escrow = fundAndCreate(amount, expiry, keccak256("billion"));

        assertEq(escrow.CREATOR_FEE(), 10_000_000e6, "1%");
        vm.warp(expiry);
        vm.prank(relayer);
        escrow.claimFunds();
        assertEq(usdc.balanceOf(seller), amount - 10_000_000e6);
    }

    /**
     * uint96 is the natural width for an amount if it is packed: 2^96 - 1 is seventy-nine
     * trillion USDC. Anything narrower is out of the question; this pins that the top of that
     * range still works exactly, so packing cannot go narrower.
     */
    function test_AnAmountAtTheTopOfUint96IsExact() public {
        uint256 amount = type(uint96).max;
        usdc.mint(buyer, amount);
        EscrowContract escrow = fundAndCreate(amount, expiry, keccak256("uint96"));

        uint256 fee = amount / 100;
        assertEq(escrow.AMOUNT(), amount);
        assertEq(escrow.CREATOR_FEE(), fee);
        assertEq(escrow.payoutAmount(), amount - fee);
        assertEq(usdc.balanceOf(feeRecipient), fee);

        vm.prank(buyer);
        escrow.raiseDispute();
        vote(escrow, buyer, 33);
        vote(escrow, seller, 33);
        uint256 escrowed = amount - fee;
        uint256 buyerShare = (escrowed * 33) / 100;
        assertEq(usdc.balanceOf(seller), escrowed - buyerShare, "resolution arithmetic does not overflow at this size");
    }

    function test_AnExpiryInTheNextCenturyWorks() public {
        uint256 farFuture = 4_102_444_800; // 2100-01-01
        EscrowContract escrow = fundAndCreate(AMOUNT, farFuture, keccak256("2100"));

        assertEq(escrow.EXPIRY_TIMESTAMP(), farFuture);
        assertEq(escrow.maturity(), farFuture);
        assertFalse(escrow.canClaim());
        assertTrue(escrow.canDispute());

        vm.warp(farFuture);
        assertTrue(escrow.canClaim());
        vm.prank(relayer);
        escrow.claimFunds();
        assertTrue(escrow.isClaimed());
    }

    /**
     * uint64 is the natural width for a timestamp if it is packed; the top of it still works.
     */
    function test_AnExpiryAtTheTopOfUint64Works() public {
        uint256 top = type(uint64).max;
        EscrowContract escrow = fundAndCreate(AMOUNT, top, keccak256("uint64"));

        assertEq(escrow.EXPIRY_TIMESTAMP(), top);
        assertFalse(escrow.isExpired());
        assertTrue(escrow.canDispute());
    }

    function testFuzz_TheLifecycleConservesEveryUnit(uint96 rawAmount, uint32 daysAhead) public {
        uint256 amount = bound(uint256(rawAmount), 300_001, type(uint96).max);
        uint256 expiryAt = CREATION_TIME + 1 + uint256(daysAhead) * 1 days;
        usdc.mint(buyer, amount);

        EscrowContract escrow = fundAndCreate(amount, expiryAt, keccak256(abi.encode(rawAmount, daysAhead)));
        uint256 fee = escrow.CREATOR_FEE();
        assertEq(fee, expectedFee6(amount));
        assertLt(fee, amount);

        vm.warp(expiryAt);
        vm.prank(relayer);
        escrow.claimFunds();

        assertEq(usdc.balanceOf(seller) + usdc.balanceOf(feeRecipient), amount);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // E. Creation. The address is a function of the terms and nothing else; the clone can be
    //    initialised once and the implementation never.
    // ═════════════════════════════════════════════════════════════════════════

    function test_TheDescriptionIsEmittedNotStoredAndDoesNotMoveTheAddress() public {
        bytes32 id = keccak256("desc");
        address at = predicted(AMOUNT, expiry, id);
        vm.prank(buyer);
        usdc.transfer(at, AMOUNT);

        vm.expectEmit(true, true, true, true, address(factory));
        emit ContractCreated(at, buyer, seller, AMOUNT, expiry, "a completely different description");
        vm.prank(relayer);
        address deployed = factory.createAndActivate(
            address(usdc), buyer, seller, AMOUNT, expiry, "a completely different description", arbiter, id
        );

        assertEq(deployed, at, "the description is not in the salt");
    }

    function test_EveryTermMovesTheAddress() public {
        bytes32 id = keccak256("terms");
        address base = predicted(AMOUNT, expiry, id);
        assertTrue(base != predicted(AMOUNT + 1, expiry, id), "amount");
        assertTrue(base != predicted(AMOUNT, expiry + 1, id), "expiry");
        assertTrue(base != predicted(AMOUNT, expiry, keccak256("other")), "externalId");
        assertTrue(
            base != factory.getContractAddress(address(usdc), buyer, seller, AMOUNT, expiry, stranger, id), "arbiter"
        );
        assertTrue(
            base != factory.getContractAddress(address(usdc), stranger, seller, AMOUNT, expiry, arbiter, id), "buyer"
        );
        assertTrue(
            base != factory.getContractAddress(address(usdc), buyer, stranger, AMOUNT, expiry, arbiter, id), "seller"
        );
    }

    function test_TheImplementationCanNeverBeInitialised() public {
        // The constructor marks the implementation as already initialised; that guard fires first.
        // Whichever guard a rewrite keeps, the implementation must refuse — pinned by the revert.
        vm.expectRevert(EscrowContract.AlreadyInitialized.selector);
        implementation.initialize(address(usdc), buyer, seller, arbiter, AMOUNT, expiry, 10e6, feeRecipient, address(0), 0);
    }

    function test_ACloneCanBeInitialisedOnlyOnce() public {
        EscrowContract escrow = funded();
        vm.prank(address(factory));
        vm.expectRevert(EscrowContract.AlreadyInitialized.selector);
        escrow.initialize(address(usdc), buyer, seller, arbiter, AMOUNT, expiry, 10e6, feeRecipient, address(0), 0);
    }

    function test_ACloneRecordsWhoeverInitialisedItAsItsFactory() public {
        // initialize is permissionless by design; FACTORY answers "who called it", and the
        // factory is the only thing that should. Pinned so a slot removal does not lose the getter.
        address raw = Clones.clone(address(implementation));
        vm.prank(stranger);
        EscrowContract(raw).initialize(address(usdc), buyer, seller, arbiter, AMOUNT, expiry, 10e6, feeRecipient, address(0), 0);
        assertEq(EscrowContract(raw).FACTORY(), stranger);
    }

    function test_CreateAndActivateIsAllOrNothing() public {
        bytes32 id = keccak256("unfunded");
        address at = predicted(AMOUNT, expiry, id);

        vm.prank(relayer);
        vm.expectRevert(EscrowContract.InsufficientDirectPayment.selector);
        factory.createAndActivate(address(usdc), buyer, seller, AMOUNT, expiry, description, arbiter, id);

        assertEq(at.code.length, 0, "nothing deployed on a failed activation");
    }

    function test_OverpaymentStaysInTheEscrowAndClaimPaysItAllToTheSeller() public {
        bytes32 id = keccak256("over");
        address at = predicted(AMOUNT, expiry, id);
        vm.prank(buyer);
        usdc.transfer(at, AMOUNT + 5e6);
        vm.prank(relayer);
        factory.createAndActivate(address(usdc), buyer, seller, AMOUNT, expiry, description, arbiter, id);

        uint256 fee = expectedFee6(AMOUNT);
        assertEq(usdc.balanceOf(at), AMOUNT + 5e6 - fee);

        vm.warp(expiry);
        vm.prank(relayer);
        EscrowContract(at).claimFunds();
        // Pinned as observed today: the claim pays exactly the escrowed amount and the
        // overpayment is left in the contract. If the gas work changes this, it is a
        // behaviour change to decide on its own, not a side effect to discover.
        assertEq(usdc.balanceOf(seller), AMOUNT - fee);
        assertEq(usdc.balanceOf(at), 5e6);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // F. Gas ceilings. ⚠️ THE ONE PART OF THIS FILE THAT IS MEANT TO CHANGE.
    //
    //    Each ceiling is the figure measured on 2026-09-21 plus a few percent, so a change that
    //    makes creation MORE expensive fails here. When the gas work lands, lower each ceiling to
    //    the new figure plus the same margin, so the saving is locked in and cannot erode.
    //
    //    Measured with gasleft() around the external call. A test is ONE transaction, so slots
    //    touched earlier in it are warm: the claim measures ~28k here against ~54k in the gas
    //    report, where it runs cold. Ceilings are relative guards, not billing figures; compare
    //    like with like, and use `forge test --gas-report` for the cold numbers.
    // ═════════════════════════════════════════════════════════════════════════

    uint256 internal constant CEILING_CREATE_AND_ACTIVATE = 495_000; // measured 471,376
    uint256 internal constant CEILING_CLAIM = 30_000; // measured 27,956 (warm)
    uint256 internal constant CEILING_DISPUTE = 27_000; // measured 24,997
    uint256 internal constant CEILING_RESOLVING_VOTE = 61_000; // measured 57,396
    uint256 internal constant CEILING_TRANSFER_TO_PREDICTED = 33_000; // measured 31,179 on the mock token

    function test_GasCeiling_CreateAndActivate() public {
        bytes32 id = keccak256("gas-create");
        address at = predicted(AMOUNT, expiry, id);

        vm.prank(buyer);
        uint256 before = gasleft();
        usdc.transfer(at, AMOUNT);
        uint256 transferGas = before - gasleft();
        emit log_named_uint("gas: funding transfer to the predicted address", transferGas);
        assertLt(transferGas, CEILING_TRANSFER_TO_PREDICTED);

        vm.prank(relayer);
        before = gasleft();
        factory.createAndActivate(address(usdc), buyer, seller, AMOUNT, expiry, description, arbiter, id);
        uint256 createGas = before - gasleft();
        emit log_named_uint("gas: createAndActivate", createGas);
        assertLt(createGas, CEILING_CREATE_AND_ACTIVATE);
    }

    function test_GasCeiling_ClaimAtMaturity() public {
        EscrowContract escrow = funded();
        vm.warp(expiry);

        vm.prank(relayer);
        uint256 before = gasleft();
        escrow.claimFunds();
        uint256 used = before - gasleft();
        emit log_named_uint("gas: claimFunds", used);
        assertLt(used, CEILING_CLAIM);
    }

    function test_GasCeiling_DisputeAndResolution() public {
        EscrowContract escrow = funded();

        vm.prank(buyer);
        uint256 before = gasleft();
        escrow.raiseDispute();
        uint256 disputeGas = before - gasleft();
        emit log_named_uint("gas: raiseDispute", disputeGas);
        assertLt(disputeGas, CEILING_DISPUTE);

        vote(escrow, buyer, 50);

        vm.prank(seller);
        before = gasleft();
        escrow.submitResolutionVote(50);
        uint256 resolvingVoteGas = before - gasleft();
        emit log_named_uint("gas: the vote that resolves (two transfers)", resolvingVoteGas);
        assertLt(resolvingVoteGas, CEILING_RESOLVING_VOTE);
    }
}
