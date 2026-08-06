// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {EscrowContract} from "../src/EscrowContract.sol";
import {EscrowContractFactory} from "../src/EscrowContractFactory.sol";

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    string public name = "Mock USDC";
    string public symbol = "MUSDC";
    uint8 public decimals = 6;
    uint256 public totalSupply;

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "balance");
        require(allowance[from][msg.sender] >= amount, "allowance");
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

/**
 * §14.1 — EscrowContract §3.3 (sale-triggered arbiter reset).
 *
 * Every test here encodes a specific failure the spec caught on paper. The two that
 * matter most:
 *   - testVoteTrap_* : the §3.3D vote trap. Getting it wrong hands any seller the
 *     entire escrow with no collusion required at all.
 *   - testAttack_SelfDealtEscrowFailsAfterSale : the §8.1a end-to-end attack replay,
 *     which the spec names the single most important test in the suite.
 *
 * Nomination-window liveness coverage lives in ArbiterNominationWindow.t.sol.
 */
contract EscrowArbiterTest is Test {
    EscrowContract internal implementation;
    EscrowContractFactory internal factory;
    MockERC20 internal usdc;

    address internal defaultArbiter = makeAddr("defaultArbiterSafe");
    address internal platform = makeAddr("platform");
    address internal buyer = makeAddr("buyer");
    address internal seller = makeAddr("seller");
    address internal arbiter = makeAddr("arbiter");
    address internal lp = makeAddr("lp");
    address internal marketplace = makeAddr("marketplace");
    address internal outsider = makeAddr("outsider");

    uint256 internal constant AMOUNT = 10_000 * 1e6;
    uint256 internal expiry;

    function setUp() public {
        usdc = new MockERC20();
        implementation = new EscrowContract(defaultArbiter);
        factory = new EscrowContractFactory(platform, address(implementation), platform);
        expiry = block.timestamp + 30 days;
    }

    // ───────────────────────────────────────────────────────────────────────────
    // Helpers
    // ───────────────────────────────────────────────────────────────────────────

    function _createFunded() internal returns (EscrowContract escrow) {
        vm.prank(platform);
        address addr = factory.createEscrowContract(address(usdc), buyer, seller, AMOUNT, expiry, "test", arbiter);
        escrow = EscrowContract(addr);

        usdc.mint(buyer, AMOUNT);
        vm.prank(buyer);
        usdc.approve(addr, AMOUNT);
        vm.prank(buyer);
        escrow.depositFunds();
    }

    /// The marketplace's atomic swap: seller approves, operator pulls.
    function _sellTo(EscrowContract escrow, address newRecipient) internal {
        vm.prank(escrow.SELLER());
        escrow.approveRecipientTransfer(marketplace, newRecipient);
        vm.prank(marketplace);
        escrow.transferRecipientFrom(newRecipient);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // §3.3D — THE VOTE TRAP. The three cases, verbatim from §14.1.
    // ═══════════════════════════════════════════════════════════════════════════

    /// Case 1: sold escrow (arbiter unseated), seller votes 0 → MUST NOT resolve.
    /// If resolutionVotes[address(0)] read as a live 0% vote, this single call would
    /// hand the seller 100% of the escrow before the nomination window even opened.
    function testVoteTrap_SellerVotesZeroWhileUnseated_DoesNotResolve() public {
        EscrowContract escrow = _createFunded();
        _sellTo(escrow, lp);

        vm.prank(buyer);
        escrow.raiseDispute();

        assertEq(escrow.ARBITER(), address(0), "sale must unseat");

        vm.prank(lp);
        escrow.submitResolutionVote(0);

        assertFalse(escrow.consensusReached(), "seller alone must NOT reach consensus");
        assertFalse(escrow.isClaimed(), "no payout may have occurred");
        assertEq(usdc.balanceOf(lp), 0, "seller must not have been paid");
    }

    /// Case 2: seller votes 0, arbiter is THEN seated → seating MUST NOT fire consensus.
    /// A newly seated arbiter's slot defaults to 0, which is a valid "0% to buyer" vote.
    function testVoteTrap_SeatingAfterSellerVotedZero_DoesNotResolve() public {
        EscrowContract escrow = _createFunded();
        _sellTo(escrow, lp);

        vm.prank(buyer);
        escrow.raiseDispute();

        vm.prank(lp);
        escrow.submitResolutionVote(0);
        assertFalse(escrow.consensusReached());

        // Let the window lapse and seat the fallback.
        vm.warp(block.timestamp + escrow.NOMINATION_WINDOW() + 1);
        escrow.seatDefaultArbiter();

        assertEq(escrow.ARBITER(), defaultArbiter);
        assertFalse(escrow.consensusReached(), "seating must NOT fire consensus");
        assertFalse(escrow.isClaimed());
    }

    /// Case 3: buyer and seller both vote 50, no arbiter seated → MUST resolve.
    /// This is the no-arbiter-needed path and the common case; the guard must not break it.
    function testVoteTrap_BuyerAndSellerAgreeWhileUnseated_DoesResolve() public {
        EscrowContract escrow = _createFunded();
        _sellTo(escrow, lp);

        vm.prank(buyer);
        escrow.raiseDispute();

        uint256 payout = AMOUNT - escrow.CREATOR_FEE();

        vm.prank(buyer);
        escrow.submitResolutionVote(50);
        assertFalse(escrow.consensusReached());

        vm.prank(lp);
        escrow.submitResolutionVote(50);

        assertTrue(escrow.consensusReached(), "two matching party votes MUST settle");
        assertTrue(escrow.isClaimed());
        assertEq(usdc.balanceOf(buyer), payout / 2);
        assertEq(usdc.balanceOf(lp), payout - payout / 2);
    }

    /// The zero address must never read as a live voter, even directly.
    function testVoteTrap_ZeroAddressVoteSentinelWrittenAtInitialize() public {
        EscrowContract escrow = _createFunded();
        (uint8 zeroVote) = escrow.resolutionVotes(address(0));
        assertEq(zeroVote, 255, "address(0) must be pre-written as 'not voted'");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Unseating
    // ═══════════════════════════════════════════════════════════════════════════

    function testUnseat_TransferRecipientFromUnseatsAndClearsNominations() public {
        EscrowContract escrow = _createFunded();

        // Pre-load both nominations so we can prove they are cleared.
        // (Nominations are only accepted while unseated, so do this after a first sale.)
        _sellTo(escrow, lp);
        vm.prank(buyer);
        escrow.nominateArbiter(outsider);
        vm.prank(lp);
        escrow.nominateArbiter(arbiter); // deliberately non-matching
        assertEq(escrow.nominatedByBuyer(), outsider);
        assertEq(escrow.nominatedByRecipient(), arbiter);

        // Re-seat by agreement, then sell again and confirm the seat is cleared.
        vm.prank(buyer);
        escrow.nominateArbiter(arbiter);
        assertEq(escrow.ARBITER(), arbiter, "matching nominations seat immediately");

        // Expect the unseat on the PULL specifically, so the approval's own event does not
        // absorb the expectation.
        address lp2 = makeAddr("lp2");
        vm.prank(lp);
        escrow.approveRecipientTransfer(marketplace, lp2);

        vm.expectEmit(true, false, false, false);
        emit EscrowContract.ArbiterUnseated(arbiter);
        vm.prank(marketplace);
        escrow.transferRecipientFrom(lp2);

        assertEq(escrow.ARBITER(), address(0));
        assertEq(escrow.nominatedByBuyer(), address(0));
        assertEq(escrow.nominatedByRecipient(), address(0));
    }

    function testUnseat_ChangeRecipientDoesNotUnseat() public {
        EscrowContract escrow = _createFunded();

        vm.prank(seller);
        escrow.changeRecipient(outsider);

        assertEq(escrow.ARBITER(), arbiter, "wallet rotation must NOT evict a legitimate arbiter");
        assertEq(escrow.SELLER(), outsider);
    }

    function testUnseat_OldArbiterCannotVoteAfterSale() public {
        EscrowContract escrow = _createFunded();
        _sellTo(escrow, lp);

        vm.prank(buyer);
        escrow.raiseDispute();

        vm.prank(arbiter);
        vm.expectRevert(EscrowContract.NotAuthorizedToVote.selector);
        escrow.submitResolutionVote(100);
    }

    /// A sale executed MID-DISPUTE gives the new recipient a full window from the moment
    /// they hold the role.
    function testUnseat_MidDisputeSaleRestartsFullWindow() public {
        EscrowContract escrow = _createFunded();

        vm.prank(buyer);
        escrow.raiseDispute();

        vm.warp(block.timestamp + 10 days); // long after any window would have lapsed
        _sellTo(escrow, lp);

        assertEq(escrow.nominationDeadline(), uint64(block.timestamp + escrow.NOMINATION_WINDOW()));

        // And the fallback is not seatable until that fresh window elapses.
        vm.expectRevert(
            abi.encodeWithSelector(EscrowContract.NominationWindowStillOpen.selector, escrow.nominationDeadline())
        );
        escrow.seatDefaultArbiter();
    }

    /// A recipient change while unseated must clear the previous recipient's nomination.
    function testUnseat_RecipientChangeClearsRecipientNomination() public {
        EscrowContract escrow = _createFunded();
        _sellTo(escrow, lp);

        vm.prank(lp);
        escrow.nominateArbiter(outsider);
        assertEq(escrow.nominatedByRecipient(), outsider);

        // LP rotates their own wallet — a nomination by the previous holder must not bind.
        address lp2 = makeAddr("lp2");
        vm.prank(lp);
        escrow.changeRecipient(lp2);

        assertEq(escrow.nominatedByRecipient(), address(0));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Nomination & seating (§3.3A1a)
    // ═══════════════════════════════════════════════════════════════════════════

    function testNominate_RejectedWhileArbiterSeated() public {
        EscrowContract escrow = _createFunded();

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(EscrowContract.ArbiterAlreadySeated.selector, arbiter));
        escrow.nominateArbiter(outsider);
    }

    function testNominate_OnlyParties() public {
        EscrowContract escrow = _createFunded();
        _sellTo(escrow, lp);

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(EscrowContract.NotDisputeParty.selector, outsider));
        escrow.nominateArbiter(arbiter);
    }

    function testNominate_CandidateCannotBeZeroOrParty() public {
        EscrowContract escrow = _createFunded();
        _sellTo(escrow, lp);

        vm.startPrank(buyer);
        vm.expectRevert(abi.encodeWithSelector(EscrowContract.InvalidArbiterCandidate.selector, address(0)));
        escrow.nominateArbiter(address(0));

        vm.expectRevert(abi.encodeWithSelector(EscrowContract.InvalidArbiterCandidate.selector, buyer));
        escrow.nominateArbiter(buyer);

        vm.expectRevert(abi.encodeWithSelector(EscrowContract.InvalidArbiterCandidate.selector, lp));
        escrow.nominateArbiter(lp);
        vm.stopPrank();
    }

    function testNominate_SingleNominationNeverSeats() public {
        EscrowContract escrow = _createFunded();
        _sellTo(escrow, lp);

        vm.prank(buyer);
        escrow.nominateArbiter(outsider);

        assertEq(escrow.ARBITER(), address(0), "one side alone must never seat");
    }

    function testNominate_NominationsAreMutableUntilSeated() public {
        EscrowContract escrow = _createFunded();
        _sellTo(escrow, lp);

        vm.startPrank(buyer);
        escrow.nominateArbiter(outsider);
        escrow.nominateArbiter(arbiter); // overwrite
        vm.stopPrank();

        assertEq(escrow.nominatedByBuyer(), arbiter);

        // The stale first choice must no longer be matchable.
        vm.prank(lp);
        escrow.nominateArbiter(outsider);
        assertEq(escrow.ARBITER(), address(0));
    }

    function testNominate_MatchSeatsImmediatelyAndFlagsAgreement() public {
        EscrowContract escrow = _createFunded();
        _sellTo(escrow, lp);

        vm.prank(buyer);
        escrow.nominateArbiter(outsider);

        vm.expectEmit(true, false, false, true);
        emit EscrowContract.ArbiterSeated(outsider, true); // byAgreement
        vm.prank(lp);
        escrow.nominateArbiter(outsider);

        assertEq(escrow.ARBITER(), outsider);
    }

    /// Agreement is allowed BEFORE any dispute — settle governance while relations are good.
    function testNominate_AllowedPreDispute() public {
        EscrowContract escrow = _createFunded();
        _sellTo(escrow, lp);

        assertFalse(escrow.hasActiveDispute());

        vm.prank(buyer);
        escrow.nominateArbiter(outsider);
        vm.prank(lp);
        escrow.nominateArbiter(outsider);

        assertEq(escrow.ARBITER(), outsider);
    }

    /// A re-confirmed incumbent who had voted before the sale returns with a clean slate.
    function testSeat_ReconfirmedIncumbentVoteIsReset() public {
        EscrowContract escrow = _createFunded();

        vm.prank(buyer);
        escrow.raiseDispute();

        // Arbiter votes 100 while still seated, pre-sale.
        vm.prank(arbiter);
        escrow.submitResolutionVote(100);
        (uint8 voteBefore) = escrow.resolutionVotes(arbiter);
        assertEq(voteBefore, 100);

        // Sell mid-dispute, then re-confirm the same arbiter.
        _sellTo(escrow, lp);
        vm.prank(buyer);
        escrow.nominateArbiter(arbiter);
        vm.prank(lp);
        escrow.nominateArbiter(arbiter);

        (uint8 voteAfter) = escrow.resolutionVotes(arbiter);
        assertEq(voteAfter, 255, "re-seated arbiter must return with vote reset");
        assertFalse(escrow.consensusReached());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // seatDefaultArbiter
    // ═══════════════════════════════════════════════════════════════════════════

    function testSeatDefault_RequiresDispute() public {
        EscrowContract escrow = _createFunded();
        _sellTo(escrow, lp);

        vm.expectRevert(EscrowContract.ContractMustBeDisputed.selector);
        escrow.seatDefaultArbiter();
    }

    function testSeatDefault_RequiresUnseated() public {
        EscrowContract escrow = _createFunded();

        vm.prank(buyer);
        escrow.raiseDispute();

        vm.expectRevert(abi.encodeWithSelector(EscrowContract.ArbiterAlreadySeated.selector, arbiter));
        escrow.seatDefaultArbiter();
    }

    function testSeatDefault_RequiresDeadlinePassed() public {
        EscrowContract escrow = _createFunded();
        _sellTo(escrow, lp);

        vm.prank(buyer);
        escrow.raiseDispute();

        vm.expectRevert(
            abi.encodeWithSelector(EscrowContract.NominationWindowStillOpen.selector, escrow.nominationDeadline())
        );
        escrow.seatDefaultArbiter();
    }

    /// A zero window means the fallback is seatable as soon as a dispute exists.
    /// (0 at initialize means "use the default", so this drives the window to 1 second and
    /// warps past it — the nearest reachable equivalent of an immediate fallback.)
    /// One second before the window closes the fallback is still barred; one second after
    /// it is seatable. Pins the boundary exactly.
    function testSeatDefault_BoundaryIsExact() public {
        EscrowContract escrow = _createFunded();
        _sellTo(escrow, lp);

        vm.prank(buyer);
        escrow.raiseDispute();

        uint64 deadline = escrow.nominationDeadline();

        vm.warp(deadline);
        vm.expectRevert(abi.encodeWithSelector(EscrowContract.NominationWindowStillOpen.selector, deadline));
        escrow.seatDefaultArbiter();

        vm.warp(uint256(deadline) + 1);
        escrow.seatDefaultArbiter();
        assertEq(escrow.ARBITER(), defaultArbiter);
    }

    function testSeatDefault_IsPermissionless() public {
        EscrowContract escrow = _createFunded();
        _sellTo(escrow, lp);

        vm.prank(buyer);
        escrow.raiseDispute();
        vm.warp(block.timestamp + escrow.NOMINATION_WINDOW() + 1);

        vm.expectEmit(true, false, false, true);
        emit EscrowContract.ArbiterSeated(defaultArbiter, false); // NOT byAgreement
        vm.prank(outsider); // any wallet
        escrow.seatDefaultArbiter();
    }

    /// A late match still seats, right up until the fallback actually executes. The
    /// deadline's only role is to ENABLE the fallback, never to block agreement.
    function testSeatDefault_LateMatchStillWinsBeforeFallbackExecutes() public {
        EscrowContract escrow = _createFunded();
        _sellTo(escrow, lp);

        vm.prank(buyer);
        escrow.raiseDispute();
        vm.warp(block.timestamp + escrow.NOMINATION_WINDOW() + 1000);

        vm.prank(buyer);
        escrow.nominateArbiter(outsider);
        vm.prank(lp);
        escrow.nominateArbiter(outsider);

        assertEq(escrow.ARBITER(), outsider, "late agreement must still seat");

        // And the fallback can no longer take the seat.
        vm.expectRevert(abi.encodeWithSelector(EscrowContract.ArbiterAlreadySeated.selector, outsider));
        escrow.seatDefaultArbiter();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // evictArbiter (§3.3A1a)
    // ═══════════════════════════════════════════════════════════════════════════

    function testEvict_RevertsInsideTimeoutFromSeating() public {
        EscrowContract escrow = _createFunded();
        _sellTo(escrow, lp);

        vm.prank(buyer);
        escrow.raiseDispute();
        vm.warp(block.timestamp + escrow.NOMINATION_WINDOW() + 1);
        escrow.seatDefaultArbiter();

        vm.warp(block.timestamp + 29 days);
        // Read the clock BEFORE pranking: a view call would otherwise consume the prank.
        uint64 stamped = escrow.lastArbiterActionAt();
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(EscrowContract.ArbiterNotSilent.selector, stamped));
        escrow.evictArbiter();
    }

    function testEvict_SucceedsAfterTimeoutAndReopensNomination() public {
        EscrowContract escrow = _createFunded();
        _sellTo(escrow, lp);

        vm.prank(buyer);
        escrow.raiseDispute();
        vm.warp(block.timestamp + escrow.NOMINATION_WINDOW() + 1);
        escrow.seatDefaultArbiter();

        vm.warp(block.timestamp + 30 days + 1);

        vm.expectEmit(true, false, false, false);
        emit EscrowContract.ArbiterEvicted(defaultArbiter);
        vm.prank(lp);
        escrow.evictArbiter();

        assertEq(escrow.ARBITER(), address(0));
        assertEq(escrow.nominationDeadline(), uint64(block.timestamp + escrow.NOMINATION_WINDOW()));
    }

    /// The rolling clock: an arbiter who votes resets it, so eviction is measured from the
    /// LAST action, not from seating.
    function testEvict_RollingClockResetsOnArbiterVote() public {
        EscrowContract escrow = _createFunded();
        _sellTo(escrow, lp);

        vm.prank(buyer);
        escrow.raiseDispute();
        vm.warp(block.timestamp + escrow.NOMINATION_WINDOW() + 1);
        escrow.seatDefaultArbiter();

        vm.warp(block.timestamp + 20 days);
        vm.prank(defaultArbiter);
        escrow.submitResolutionVote(40); // matches neither party — the "voted once" case

        // 20 days after seating, but only just after the vote: still not silent.
        vm.warp(block.timestamp + 29 days);
        uint64 stamped = escrow.lastArbiterActionAt();
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(EscrowContract.ArbiterNotSilent.selector, stamped));
        escrow.evictArbiter();

        // Past 30 days since the vote: the standing-figure-then-vanished arbiter is evictable.
        vm.warp(block.timestamp + 2 days);
        vm.prank(buyer);
        escrow.evictArbiter();
        assertEq(escrow.ARBITER(), address(0));
    }

    /// raiseDispute starts the clock on an UNSOLD escrow — it must not run from creation.
    function testEvict_ClockStartsAtDisputeNotCreation() public {
        EscrowContract escrow = _createFunded();

        vm.warp(block.timestamp + 20 days); // escrow sits quietly
        vm.prank(buyer);
        escrow.raiseDispute();

        assertEq(escrow.lastArbiterActionAt(), uint64(block.timestamp));

        vm.warp(block.timestamp + 29 days);
        uint64 stamped = escrow.lastArbiterActionAt();
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(EscrowContract.ArbiterNotSilent.selector, stamped));
        escrow.evictArbiter();
    }

    /// On an UNSOLD escrow, eviction is the parties' exit from a slow platform Safe.
    function testEvict_UnsoldEscrowPartiesCanReplaceCreationArbiter() public {
        EscrowContract escrow = _createFunded();

        vm.prank(buyer);
        escrow.raiseDispute();
        vm.warp(block.timestamp + 30 days + 1);

        vm.prank(seller);
        escrow.evictArbiter();
        assertEq(escrow.ARBITER(), address(0));

        // Then match-nominate a private arbiter of their choosing.
        vm.prank(buyer);
        escrow.nominateArbiter(outsider);
        vm.prank(seller);
        escrow.nominateArbiter(outsider);
        assertEq(escrow.ARBITER(), outsider);
    }

    function testEvict_PartyOnlyAndDisputedOnly() public {
        EscrowContract escrow = _createFunded();

        // Not disputed.
        vm.prank(buyer);
        vm.expectRevert(EscrowContract.ContractMustBeDisputed.selector);
        escrow.evictArbiter();

        vm.prank(buyer);
        escrow.raiseDispute();
        vm.warp(block.timestamp + 30 days + 1);

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(EscrowContract.NotDisputeParty.selector, outsider));
        escrow.evictArbiter();
    }

    function testEvict_RevertsWhenNoArbiterSeated() public {
        EscrowContract escrow = _createFunded();
        _sellTo(escrow, lp);

        vm.prank(buyer);
        escrow.raiseDispute();

        vm.prank(buyer);
        vm.expectRevert(EscrowContract.NoArbiterSeated.selector);
        escrow.evictArbiter();
    }

    /// §14.3.6 — eviction is fund-neutral.
    function testEvict_MovesNoFunds() public {
        EscrowContract escrow = _createFunded();

        vm.prank(buyer);
        escrow.raiseDispute();
        vm.warp(block.timestamp + 30 days + 1);

        uint256 escrowBefore = usdc.balanceOf(address(escrow));
        uint256 buyerBefore = usdc.balanceOf(buyer);
        uint256 sellerBefore = usdc.balanceOf(seller);

        vm.prank(buyer);
        escrow.evictArbiter();

        assertEq(usdc.balanceOf(address(escrow)), escrowBefore);
        assertEq(usdc.balanceOf(buyer), buyerBefore);
        assertEq(usdc.balanceOf(seller), sellerBefore);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // State & persistence
    // ═══════════════════════════════════════════════════════════════════════════

    function testResolvedPercentage_SentinelUntilResolved() public {
        EscrowContract escrow = _createFunded();
        assertEq(escrow.resolvedBuyerPercentage(), 255);

        vm.prank(buyer);
        escrow.raiseDispute();
        assertEq(escrow.resolvedBuyerPercentage(), 255, "still unset mid-dispute");
    }

    function testResolvedPercentage_MatchesExecutedFigure() public {
        uint8[5] memory cases = [uint8(0), 1, 50, 99, 100];

        for (uint256 i = 0; i < cases.length; i++) {
            // The factory's clone salt includes block.timestamp, so identical parameters in
            // the same block would collide on a deterministic address.
            vm.warp(block.timestamp + 1);

            EscrowContract escrow = _createFunded();
            vm.prank(buyer);
            escrow.raiseDispute();

            vm.prank(buyer);
            escrow.submitResolutionVote(cases[i]);
            vm.prank(seller);
            escrow.submitResolutionVote(cases[i]);

            assertTrue(escrow.consensusReached());
            assertEq(escrow.resolvedBuyerPercentage(), cases[i]);
        }
    }

    function testTransferRecipient_RejectsDefaultArbiter() public {
        EscrowContract escrow = _createFunded();

        vm.prank(seller);
        vm.expectRevert(EscrowContract.PartyCannotBeDefaultArbiter.selector);
        escrow.changeRecipient(defaultArbiter);
    }

    function testTransferRecipient_RejectsSeatedArbiter() public {
        EscrowContract escrow = _createFunded();

        vm.prank(seller);
        vm.expectRevert(EscrowContract.ArbiterMustBeDistinct.selector);
        escrow.changeRecipient(arbiter);
    }

    function testInitialize_RejectsDefaultArbiterAsParty() public {
        address clone = Clones.clone(address(implementation));

        vm.expectRevert(EscrowContract.PartyCannotBeDefaultArbiter.selector);
        EscrowContract(clone).initialize(address(usdc), defaultArbiter, seller, arbiter, AMOUNT, expiry, 0, platform);

        address clone2 = Clones.clone(address(implementation));
        vm.expectRevert(EscrowContract.PartyCannotBeDefaultArbiter.selector);
        EscrowContract(clone2).initialize(address(usdc), buyer, defaultArbiter, arbiter, AMOUNT, expiry, 0, platform);
    }

    /// §3.3A1's load-bearing property: no code path may change the window after initialize.
    /// The window is a constant shared by every clone, so no escrow can present a different
    /// one to an LP and no code path can change it. This walks the whole arbiter surface to
    /// confirm nothing perturbs it.
    function testWindow_IsAConstantSharedByEveryClone() public {
        EscrowContract escrow = _createFunded();
        uint64 before = escrow.NOMINATION_WINDOW();

        assertEq(before, 72 hours, "the mandated window");
        assertEq(before, implementation.NOMINATION_WINDOW(), "identical to the implementation");

        // A second escrow, from the same factory, sees the identical value.
        // (Warp first: the factory's clone salt includes block.timestamp.)
        vm.warp(block.timestamp + 1);
        assertEq(_createFunded().NOMINATION_WINDOW(), before, "identical across clones");

        // Exercise every state-mutating path that touches arbiter machinery.
        _sellTo(escrow, lp);
        vm.prank(buyer);
        escrow.raiseDispute();
        vm.prank(buyer);
        escrow.nominateArbiter(outsider);
        vm.prank(lp);
        escrow.nominateArbiter(outsider);
        vm.warp(block.timestamp + 30 days + 1);
        vm.prank(buyer);
        escrow.evictArbiter();

        assertEq(escrow.NOMINATION_WINDOW(), before, "window must be immutable after initialize");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // §8.1a — THE ATTACK, END TO END.
    // "This is the single most important test in the suite." (§14.1)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * The attacker direct-clones the audited implementation (bypassing the factory
     * entirely — initialize is permissionless), installs a buyer and an arbiter they
     * control, funds it with real tokens so it passes every sellable gate, lists it, and
     * sells the cashflow to an LP at a discount.
     *
     * Then, in the block immediately after the sale, they bundle:
     *     raiseDispute → buyer votes 100 → pre-loaded arbiter votes 100
     * which under the old design would refund the attacker the full escrow while they kept
     * the LP's payment.
     *
     * It MUST fail, because the sale unseated the pre-loaded arbiter.
     */
    function testAttack_SelfDealtEscrowFailsAfterSale() public {
        address attacker = makeAddr("attacker"); // seller AND the real beneficiary
        address attackerBuyer = makeAddr("attackerBuyer"); // wallet they control
        address attackerArbiter = makeAddr("attackerArbiter"); // wallet they control
        address victimLp = makeAddr("victimLp");

        // 1. Direct clone — no factory involved. The codehash is nonetheless genuine.
        address clone = Clones.clone(address(implementation));
        EscrowContract escrow = EscrowContract(clone);
        escrow.initialize(address(usdc), attackerBuyer, attacker, attackerArbiter, AMOUNT, expiry, 0, platform);

        // 2. Fund it with real tokens so it passes funded/undisputed/unclaimed.
        usdc.mint(attackerBuyer, AMOUNT);
        vm.prank(attackerBuyer);
        usdc.approve(clone, AMOUNT);
        vm.prank(attackerBuyer);
        escrow.depositFunds();

        assertTrue(escrow.isFunded());
        assertEq(escrow.ARBITER(), attackerArbiter, "attacker's arbiter is seated pre-sale");

        // 3. Sell the cashflow to the LP (the marketplace's atomic swap).
        _sellTo(escrow, victimLp);

        // ── The attack bundle, all in the block right after the sale ──
        vm.prank(attackerBuyer);
        escrow.raiseDispute();

        vm.prank(attackerBuyer);
        escrow.submitResolutionVote(100); // full refund to the attacker's buyer

        // THE CRITICAL ASSERTION: the pre-loaded arbiter is no longer an authorised voter,
        // so the 2-of-3 cannot be completed.
        vm.prank(attackerArbiter);
        vm.expectRevert(EscrowContract.NotAuthorizedToVote.selector);
        escrow.submitResolutionVote(100);

        assertFalse(escrow.consensusReached(), "attack must not manufacture consensus");
        assertFalse(escrow.isClaimed());
        assertEq(usdc.balanceOf(attackerBuyer), 0, "no refund may have been extracted");
        assertEq(usdc.balanceOf(address(escrow)), AMOUNT, "escrowed funds must be untouched");

        // 4. And every route back to a seat runs through the LP.
        //    The attacker cannot self-nominate their way back in:
        vm.prank(attackerBuyer);
        escrow.nominateArbiter(attackerArbiter);
        assertEq(escrow.ARBITER(), address(0), "buyer alone cannot re-seat");

        //    Nor can they outwait the window into an arbiter they control — the fallback is
        //    the platform Safe, which they do not control.
        vm.warp(block.timestamp + escrow.NOMINATION_WINDOW() + 1);
        escrow.seatDefaultArbiter();
        assertEq(escrow.ARBITER(), defaultArbiter, "fallback must be the honest Safe");

        //    The attacker's buyer + the Safe still cannot pay out unless the Safe
        //    independently votes 100, which is ordinary arbitration on the merits.
        assertFalse(escrow.consensusReached());
    }

    /// The LP's protection also holds if the attacker tries to sell into a live dispute:
    /// the marketplace refuses such escrows outright, and the escrow-level guarantee is
    /// that any arbiter present at sale time is unseated regardless.
    function testAttack_MidDisputeSaleStillUnseats() public {
        EscrowContract escrow = _createFunded();

        vm.prank(buyer);
        escrow.raiseDispute();
        assertEq(escrow.ARBITER(), arbiter);

        _sellTo(escrow, lp);

        assertEq(escrow.ARBITER(), address(0));
        vm.prank(arbiter);
        vm.expectRevert(EscrowContract.NotAuthorizedToVote.selector);
        escrow.submitResolutionVote(100);
    }
}
