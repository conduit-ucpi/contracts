// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IStabledropEscrow {
    function recipient() external view returns (address);
    function maturity() external view returns (uint256);
    function hasActiveDispute() external view returns (bool);
    function isFunded() external view returns (bool);
    function isClaimed() external view returns (bool);
    function token() external view returns (address);
    function payoutAmount() external view returns (uint256);
    function BUYER() external view returns (address);
    function ARBITER() external view returns (address);
    function resolvedBuyerPercentage() external view returns (uint8);
    function hasBeenSold() external view returns (bool);
    function recipientNonce() external view returns (uint64);
    function transferRecipientFrom(address newRecipient) external;
}

interface IOfferVaultFactory {
    function feeRecipient() external view returns (address);
    function paused() external view returns (bool);
    function owner() external view returns (address);
}

/**
 * ═══════════════════════════════════════════════════════════════════════════════════
 * 💧 OfferVault — ONE LP's OFFER, IN ITS OWN CONTRACT
 * ═══════════════════════════════════════════════════════════════════════════════════
 *
 * A single LP's bid on a single escrow's cashflow. Deployed as an ERC-1167 clone by
 * OfferVaultFactory, one per offer, and it holds that LP's capital and nothing else.
 *
 * 🔒 WHY ONE CONTRACT PER OFFER, RATHER THAN ONE SHARED VENUE
 *
 *    The earlier design put every LP's deposit in a single MarketplaceEscrow contract,
 *    tracked apart by per-(escrow, LP) accounting. That was correct on its own terms —
 *    the owner could never reach a deposit — but it commingled unrelated users' capital
 *    at one address, which is a custody question before it is a technical one.
 *
 *    Here each offer's funds sit in their own contract, reachable only by that offer's
 *    LP (withdrawal) or that offer's seller (acceptance). There is no shared balance, so
 *    there is nothing to apportion and no accounting to get wrong: this contract's token
 *    balance IS the offer. A solvency bug can only ever affect one offer.
 *
 *    Two consequences fall out for free:
 *      • The seller's §3.2 approval names THIS vault as operator, not a global venue —
 *        the narrowest possible authority for the swap.
 *      • Conservation is trivially checkable per contract instead of being an invariant
 *        over pooled sums.
 *
 * 🔒 WHAT THE PLATFORM CAN DO HERE: nothing. The factory owner sets fee parameters and
 *    can pause NEW offers, but no role — owner, factory, or anyone else — can move the
 *    capital in this contract. `withdraw` pays ONLY the LP and is never pausable — it is
 *    callable by anyone precisely because it has no discretion to abuse.
 *
 * ⚠️ AN OPEN OFFER IS A FIRM, IRREVOCABLE QUOTE. The LP cannot cancel it; they exit when
 *    the seller rejects, when it expires, or when the escrow becomes permanently
 *    unacceptable. Control exposure with the offer duration, not by expecting to retract.
 * ═══════════════════════════════════════════════════════════════════════════════════
 */
contract OfferVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ───────────────────────────────────────────────────────────────────────────
    // Errors
    // ───────────────────────────────────────────────────────────────────────────
    error AlreadyInitialized();
    error ImplementationCannotBeInitialized();
    error NotInitialized();
    error OfferNotOpen();
    error OfferExpiredError();
    error OfferStale();
    error NotEscrowRecipient(address caller);
    error EscrowNotSellable();
    error NothingToWithdraw();
    error NoHoldback();
    error EscrowNotSettled();
    error InsufficientDirectPayment();
    error OffersPaused();
    error OnlyFactoryOwner(address caller);
    error NothingToSweep();

    // ───────────────────────────────────────────────────────────────────────────
    // Events
    // ───────────────────────────────────────────────────────────────────────────
    event OfferAccepted(
        address indexed escrowContract, address indexed lp, address indexed seller, uint256 netAmount, uint256 fee, uint256 holdback
    );
    event OfferFunded(address indexed escrowContract, address indexed lp, address token, uint256 amount);
    event OfferRejected(address indexed escrowContract, address indexed lp);
    event FundsWithdrawn(address indexed escrowContract, address indexed lp, address token, uint256 amount);
    event HoldbackReleased(
        address indexed escrowContract, address indexed funder, address indexed beneficiary, uint256 toFunder, uint256 toBeneficiary
    );
    event TokenSwept(address indexed token, address to, uint256 amount);

    // ───────────────────────────────────────────────────────────────────────────
    // State
    // ───────────────────────────────────────────────────────────────────────────

    /// @dev Lifecycle: PENDING (deployed, not yet funded) → OPEN (LP funded it) →
    ///      CANCELLED (seller rejected) or ACCEPTED (swap done, reserve still held) →
    ///      SETTLED (this vault owes nobody anything).
    ///
    ///      PENDING exists because the platform deploys the vault but only the LP can put
    ///      money in it — the same split as the escrow, where the factory creates and the
    ///      buyer deposits. A PENDING vault holds nothing, so an LP who never funds has
    ///      simply not made an offer; it expires harmlessly.
    ///
    ///      There is no COMPLETED state: acceptance sets ACCEPTED because the vault may
    ///      still hold a reserve afterwards, and SETTLED once even that has gone.
    enum Status {
        NONE,
        PENDING,
        OPEN,
        CANCELLED,
        ACCEPTED,
        SETTLED
    }

    address public FACTORY; // set once, in initialize; address(0) on the implementation
    address public escrowContract;
    address public seller; // recipient() at creation — the offer is valid ONLY while this holds
    address public lp;
    address public token;

    uint256 public offerAmount; // gross deposited by the LP
    uint256 public holdback; // reserve retained at acceptance, released at settlement
    uint256 public netAmount; // what the seller receives AT ACCEPTANCE
    uint256 public fee; // protocol fee, snapshotted at creation
    uint256 public offerExpiry;

    /// @dev escrow.recipientNonce() at creation. The offer is valid ONLY while the escrow
    ///      still reads this value; any recipient move bumps it and is never undone, so
    ///      staleness here is PERMANENT rather than a comparison that can flip back.
    ///
    ///      Comparing `recipient()` against `seller` instead would make staleness
    ///      REVERSIBLE: a seller rotating their payout wallet and rotating back would mute
    ///      every offer on the escrow and then revive them all. With the exit path open to
    ///      any caller, that window is one in which a stranger could permanently settle a
    ///      still-good offer out from under its LP. A monotonic counter has no such window.
    ///
    ///      uint64 to pack into the same slot as `status`.
    uint64 public sellerNonce;

    Status public status;

    /// @dev The reserve's funder is the seller of the FIRST sale, which is this vault's
    ///      `seller`. The BENEFICIARY is deliberately not stored — it is escrow.recipient()
    ///      read live at settlement, so the reserve follows the position through any number
    ///      of resales with no state to keep in sync.
    modifier onlyInitialized() {
        if (FACTORY == address(0)) revert NotInitialized();
        _;
    }

    constructor() {
        // The implementation must never be initializable: a clone's storage starts empty,
        // so FACTORY == 0 marks "not a live offer". Setting a sentinel here would let the
        // implementation itself be driven.
        status = Status.SETTLED;
    }

    /**
     * Called exactly once, by the factory, in the same transaction as the clone's
     * deployment. The factory has already validated provenance, sellability, the expiry
     * bound, LP eligibility, the minimum and the holdback rules — this records the terms.
     *
     * 🔒 NO MONEY MOVES HERE. Whoever deploys the vault (in practice the platform, exactly
     *    as it creates escrows) cannot cause the LP's funds to move — only the LP can, by
     *    calling fund(). Deployment is therefore an unprivileged act: the worst a hostile
     *    caller achieves is an empty contract naming an LP who never funds it.
     */
    function initialize(
        address _escrowContract,
        address _seller,
        address _lp,
        address _token,
        uint256 _offerAmount,
        uint256 _holdback,
        uint256 _netAmount,
        uint256 _fee,
        uint256 _offerExpiry,
        uint64 _sellerNonce
    ) external {
        if (status == Status.SETTLED) revert ImplementationCannotBeInitialized();
        if (FACTORY != address(0)) revert AlreadyInitialized();

        FACTORY = msg.sender;
        escrowContract = _escrowContract;
        seller = _seller;
        lp = _lp;
        token = _token;
        offerAmount = _offerAmount;
        holdback = _holdback;
        netAmount = _netAmount;
        fee = _fee;
        offerExpiry = _offerExpiry;
        sellerNonce = _sellerNonce;
        status = Status.PENDING;
    }

    /**
     * 💰 THE LP PUTS UP THE MONEY — DIRECT TRANSFER FUNDING
     *
     * 🔒 SECURITY GUARANTEE: This function can be called by ANYONE — the same guarantee
     *    EscrowContract.checkAndActivate() relies on. It takes no discretion and names no
     *    destination: `lp` was fixed at initialize() and the capital can only ever leave
     *    via this vault's own roles. A caller chooses nothing and gains nothing.
     *
     * ✅ NO APPROVAL NEEDED. The LP sends the offer token straight to this address from
     *    their own wallet — one plain ERC20 transfer, which every wallet can decode and
     *    display honestly — and this flips the offer live once the money is here. That
     *    single transfer IS the LP's consent: deployment merely named them, and nothing
     *    binds them until their own signature moves their own funds.
     *
     *    The previous approve+transferFrom shape asked for two signatures and presented
     *    the second as an opaque call on a freshly-cloned proxy. Mirroring the escrow's
     *    direct-transfer path costs one signature and reads as what it is.
     *
     * The offer becomes live, firm and visible to the seller only at this point. Before
     * it, the vault is an empty shell.
     */
    function fund() external onlyInitialized nonReentrant {
        if (status != Status.PENDING) revert OfferNotOpen();
        if (block.timestamp > offerExpiry) revert OfferExpiredError();

        // The money must ALREADY be here. Anything short of the full offer is not an
        // offer: the LP can top up and call again while the vault is still PENDING, and
        // withdraw() returns a partial deposit once the offer lapses.
        address _token = token;
        uint256 amount = offerAmount;
        uint256 balance = IERC20(_token).balanceOf(address(this));
        if (balance < amount) revert InsufficientDirectPayment();

        status = Status.OPEN;

        emit OfferFunded(escrowContract, lp, _token, amount);
    }

    // ───────────────────────────────────────────────────────────────────────────
    // §6.2 accept — the atomic swap
    // ───────────────────────────────────────────────────────────────────────────

    /**
     * 🤝 SELLER ACCEPTS — THE ATOMIC SWAP
     *
     * PRE-CONDITION (tx 1, by the seller, on the ESCROW):
     *     escrow.approveRecipientTransfer(address(this), lp)
     * which binds THIS VAULT as operator and the exact LP as destination, for 5 minutes.
     * Note the operator is this offer's own contract, so the approval authorises exactly
     * one swap and nothing else. Without it — or after it expires — the pull below reverts
     * and NOTHING moves; the seller re-approves and calls again.
     *
     * Every other OPEN offer on this escrow becomes stale the instant this succeeds,
     * because recipient() has changed. Each of those LPs withdraws their full gross from
     * their own vault. There is no cancellation loop and no gas ceiling, which is what
     * makes sybil dust offers unable to DoS this.
     */
    function accept() external onlyInitialized nonReentrant {
        if (status != Status.OPEN) revert OfferNotOpen();
        if (block.timestamp > offerExpiry) revert OfferExpiredError();
        if (IOfferVaultFactory(FACTORY).paused()) revert OffersPaused();

        IStabledropEscrow escrow = IStabledropEscrow(escrowContract);

        // Live read, never the snapshot: the caller must be the CURRENT recipient.
        address currentRecipient = escrow.recipient();
        if (msg.sender != currentRecipient) revert NotEscrowRecipient(msg.sender);

        // The role must never have MOVED — not "must match again". A round trip
        // (seller → other → seller) leaves the address comparison reading fresh, which
        // would make this offer both acceptable here and withdrawable below, the one thing
        // that must never be true at once: a stranger could then settle the vault in front
        // of the seller's own accept().
        //
        // 🔒 THIS IS ALSO WHAT MAKES THE PAYOUT SAFE. `escrow.SELLER` is written in exactly
        //    two places — initialize (before any offer can exist) and _transferRecipient,
        //    which always bumps recipientNonce. So an unchanged nonce proves the recipient
        //    has not moved since this offer was priced, hence
        //    msg.sender == currentRecipient == seller, and paying the `seller` snapshot
        //    below pays the live recipient. A separate `currentRecipient != seller` branch
        //    could never fire and was removed.
        if (escrow.recipientNonce() != sellerNonce) revert OfferStale();

        if (!escrow.isFunded() || escrow.hasActiveDispute() || escrow.isClaimed()) {
            revert EscrowNotSellable();
        }

        // ⚠️ THE ONE-RESERVE RULE (§0.4c High) needs no re-check here. It is enforced at
        //    creation (factory step 8) and, for anything that changes afterwards, by the
        //    staleness check above: a reserve may only be quoted on an unsold escrow, and
        //    the only thing that can set hasBeenSold is transferRecipientFrom, which moves
        //    the recipient and therefore bumps recipientNonce. The dangerous sequence — the
        //    position returning to this seller so a second reserve could stack on one
        //    escrow — is exactly a recipient round trip, and the nonce makes that permanent
        //    staleness. A `holdback > 0 && hasBeenSold()` branch here could never fire.

        // ── EFFECTS ──
        // Set before any external call. A reserve keeps this vault alive holding exactly
        // `holdback`; with no reserve the vault is finished the moment it pays out.
        status = holdback > 0 ? Status.ACCEPTED : Status.SETTLED;

        uint256 _fee = fee;
        uint256 _net = netAmount;
        address _token = token;

        // ── INTERACTIONS ──
        // a. Pull the recipient role directly seller → LP using the one-shot approval. The
        //    escrow enforces lp != zero/buyer/arbiter, resets the LP's dispute vote, and
        //    UNSEATS the incumbent arbiter (the sale-triggered reset that makes a
        //    pre-loaded 2-of-3 majority unmanufacturable).
        escrow.transferRecipientFrom(lp);

        // b. Pay the protocol fee straight out. Nothing accrues here — there is no pooled
        //    fee balance to withdraw later, and therefore no owner-held balance at all.
        if (_fee > 0) IERC20(_token).safeTransfer(IOfferVaultFactory(FACTORY).feeRecipient(), _fee);

        // c. Pay the seller their net. Skipped when zero (reachable when the LP quotes a
        //    holdback that consumes the whole offer): some ERC20s revert on a zero-value
        //    transfer, which would otherwise make such an offer permanently unacceptable.
        if (_net > 0) IERC20(_token).safeTransfer(seller, _net);

        // Conservation: netAmount + fee + holdback == offerAmount by construction, so what
        // remains in this contract after the transfers is exactly `holdback`.
        //
        // d. …unless the LP overpaid. `fund()` only requires the balance to REACH
        //    offerAmount, so a mistyped transfer opens the offer with a surplus on top, and
        //    from here the vault owes only the reserve — which would leave that surplus
        //    sweepable to FEE_RECIPIENT. It is the LP's money and this is the last moment
        //    they have a claim on it, so it goes home now. Costs nothing in the normal case:
        //    the balance is exactly the reserve and the branch is skipped.
        //
        //    Written as a comparison rather than a subtraction so a fee-on-transfer token —
        //    which can leave LESS than the reserve here — fails later at the release rather
        //    than reverting an acceptance that is otherwise sound.
        uint256 remaining = IERC20(_token).balanceOf(address(this));
        if (remaining > holdback) IERC20(_token).safeTransfer(lp, remaining - holdback);

        emit OfferAccepted(escrowContract, lp, seller, _net, _fee, holdback);
    }

    // ───────────────────────────────────────────────────────────────────────────
    // §6.3 reject
    // ───────────────────────────────────────────────────────────────────────────

    /**
     * 🚫 SELLER DECLINES
     *
     * Only the CURRENT recipient may reject — a stale offer needs no rejection, it is
     * already withdrawable.
     *
     * ⚠️ The capital is deliberately NOT pushed back here: the seller should not pay gas
     *    to return someone else's money, and every exit stays on one audited path. The LP
     *    calls withdraw().
     *
     * NOT pausable — this is an exit path (§5.2.10).
     */
    function reject() external onlyInitialized nonReentrant {
        if (status != Status.OPEN) revert OfferNotOpen();
        if (msg.sender != seller) revert NotEscrowRecipient(msg.sender);
        // An unchanged nonce proves the recipient has not moved since creation, which
        // implies recipient() == seller; comparing the addresses too would add a branch
        // that can never fire.
        if (IStabledropEscrow(escrowContract).recipientNonce() != sellerNonce) revert OfferStale();

        status = Status.CANCELLED;

        emit OfferRejected(escrowContract, lp);
    }

    // ───────────────────────────────────────────────────────────────────────────
    // §6.4 withdraw
    // ───────────────────────────────────────────────────────────────────────────

    /**
     * 🔎 WOULD withdraw() SUCCEED RIGHT NOW?
     *
     * Public because §15.2 puts the detection burden off-chain: nothing on-chain notifies
     * the LP that their offer has lapsed or gone stale, so the indexer must poll for it and
     * prompt. Exposing the matrix means the UI reads the contract's own answer instead of
     * reimplementing the conditions and drifting from them.
     *
     * It is also the single source of truth `withdraw()` itself branches on, which is what
     * lets the invariant suite check withdrawability against acceptability without
     * restating the matrix in the test — a restatement would assert only that the test
     * agrees with itself, and would pass no matter how the contract changed.
     */
    function isWithdrawable() public view returns (bool) {
        if (status == Status.PENDING) {
            // Direct-transfer funding means a PENDING vault can hold money: the LP sent the
            // token but fund() never landed, or they sent too little for it to succeed.
            // Once the offer has lapsed that capital has no future here, and without this
            // branch its only exit is sweep() — which pays FEE_RECIPIENT, not the LP whose
            // money it is. Recovers a partial deposit too. The balance test keeps this
            // honest for an empty vault, where withdraw() would revert NothingToWithdraw.
            return block.timestamp > offerExpiry && IERC20(token).balanceOf(address(this)) > 0;
        }
        if (status == Status.CANCELLED) return true;
        if (status != Status.OPEN) return false;

        IStabledropEscrow escrow = IStabledropEscrow(escrowContract);
        return block.timestamp > offerExpiry // expired
            || escrow.recipientNonce() != sellerNonce // stale — the recipient MOVED
            // Permanently unacceptable: a dispute can only resolve to settled, so the offer
            // can never be accepted again. The LP exits immediately rather than waiting out
            // offerExpiry.
            || escrow.hasActiveDispute() || escrow.isClaimed();
        // A reserve-bearing offer on an escrow that has since been sold needs no term of
        // its own: the sale moved the recipient, so the nonce test above already reports it
        // stale.
    }

    /**
     * 💸 LP RECOVERS THEIR DEPOSIT — IN FULL GROSS, INCLUDING THE NEVER-CHARGED FEE
     *
     * Expiry and staleness are evaluated lazily HERE rather than in a separate expire
     * step; nothing on-chain notifies the LP, so the indexer must detect these conditions
     * and prompt.
     *
     * 🔓 CALLABLE BY ANYONE, PAYS ONLY THE LP. The caller chooses nothing: the destination
     *    is `lp`, fixed at initialize(); the amount is fixed by state; and every condition
     *    is read from the escrow or the clock. So a stranger calling this can only do the
     *    LP a favour — returning their capital, at the stranger's own gas expense. The same
     *    no-discretion argument that makes fund() permissionless.
     *
     *    ⚠️ THIS IS ONLY SAFE BECAUSE EVERY CONDITION BELOW IS ONE-WAY. An offer that is
     *    withdrawable can never become acceptable again, so opening the function up cannot
     *    destroy anything of value to the LP. Time only moves forward; a dispute resolves
     *    to claimed and never back to funded; isClaimed and hasBeenSold are absorbing; and
     *    staleness is measured with the escrow's monotonic recipientNonce rather than by
     *    comparing recipient() to a snapshot — a comparison that WOULD flip back, and would
     *    hand any passer-by a window to settle a still-good offer against the LP's wishes.
     *    Add no reversible condition here without re-closing this to the LP.
     *
     * No withdrawable offer is ever simultaneously acceptable — acceptance rejects
     * expired, stale, disputed and claimed — so there is no accept/withdraw race, and no
     * caller can settle a vault in front of the seller's accept().
     *
     * NOT pausable — this is THE exit path (§5.2.10).
     */
    function withdraw() external onlyInitialized nonReentrant {
        if (!isWithdrawable()) revert NothingToWithdraw();

        // ── EFFECTS FIRST ──
        address _token = token;

        /*
         * THE WHOLE BALANCE, IN EVERY WITHDRAWABLE STATE — the LP is this vault's residual
         * claimant until it is accepted, and after this call the vault owes nobody anything.
         *
         * ⚠️ PAYING `offerAmount` HERE GAVE AN OVERPAYMENT TO FEE_RECIPIENT. Funding is a
         *    direct transfer, and `fund()` only requires the balance to REACH offerAmount —
         *    so an LP who sends too much (a mistyped QR amount, a double transfer) opens the
         *    offer with a surplus sitting in the vault. Paying out the face amount left that
         *    surplus behind, and `owed()` then reported it as sweepable: their mistake became
         *    the platform's revenue. Nobody but the LP has any reason to send this token to
         *    this address, so the whole balance is theirs.
         *
         * A partial PENDING deposit is the same rule read the other way: pay what actually
         * arrived, because paying offerAmount would revert and strand it for good.
         *
         * Never zero — isWithdrawable() requires a non-zero balance in the PENDING branch,
         * and every other withdrawable state holds at least offerAmount.
         */
        uint256 amount = IERC20(_token).balanceOf(address(this));

        status = Status.SETTLED;

        // ── INTERACTIONS ──
        IERC20(_token).safeTransfer(lp, amount);

        emit FundsWithdrawn(escrowContract, lp, _token, amount);
    }

    // ───────────────────────────────────────────────────────────────────────────
    // §6.7 releaseHoldback
    // ───────────────────────────────────────────────────────────────────────────

    /**
     * 🏦 SETTLE THE RESERVE ONCE THE CASHFLOW HAS FINALLY COLLECTED
     *
     * 🔓 CALLABLE BY ANYONE, AND THE SAME ARGUMENT AS withdraw() SAYS WHY THAT IS SAFE. The
     *    caller chooses nothing: both destinations are fixed — the FUNDER is this vault's
     *    seller, set at initialize(), and the BENEFICIARY is read live off the escrow — and
     *    both amounts fall out of the escrow's own final state. Whoever sends the
     *    transaction, the identical split lands in the identical two places, so a stranger
     *    calling this can only do the parties a favour at their own gas expense.
     *
     *    ⚠️ THE CONDITION IS ONE-WAY, WHICH IS THE OTHER HALF OF THAT ARGUMENT. A settled
     *       escrow never becomes unsettled: `_state = 4` is absorbing on both terminal paths,
     *       and `resolvedBuyerPercentage` is written before the payout and never rewritten.
     *       So there is no window in which an early caller could settle the reserve against
     *       a party's interest, and no reversible condition to race. Add no reversible term
     *       here without restoring a caller check.
     *
     * 📌 §6.7 RESTORED. An earlier revision restricted this to the funder and the live
     *    beneficiary, on the rule that a vault's functions answer only to that deal's
     *    participants. That rule was doing no work here — neither party can influence the
     *    outcome by being the one to call — and it cost the platform the ability to relay
     *    the release, so both parties had to sign for a transaction with no decision in it.
     *    Since the destinations are fixed, opening it up gives that away for nothing.
     *
     * ⏳ LIVENESS: releasable only once the escrow reaches its settled state. Since dispute
     *    resolution has no deadline, a dispute that never resolves leaves the reserve
     *    locked alongside the escrow itself — same freeze surface, same remedy
     *    (evictArbiter). The reserve inherits the escrow's liveness rather than having its
     *    own.
     *
     * NOT pausable — this is an exit path (§5.2.10).
     */
    function releaseHoldback() external onlyInitialized nonReentrant {
        if (status != Status.ACCEPTED || holdback == 0) revert NoHoldback();

        IStabledropEscrow escrow = IStabledropEscrow(escrowContract);

        // Covers BOTH terminal paths — claimed at maturity and dispute-resolved — because
        // executing a resolution also marks the escrow claimed. An escrow still funded or
        // still disputed is not settleable, and reverting keeps the reserve in place until
        // the outcome is known.
        if (!escrow.isClaimed()) revert EscrowNotSettled();

        // Read LIVE, so the reserve lands on whoever holds the position, no matter how
        // many times it changed hands or by what route.
        address beneficiary = escrow.recipient();

        // 255 = never disputed. The sentinel is not load-bearing here: a 0% resolution
        // yields loss == 0 too, so both cases pay the funder in full. Kept for
        // observability — indexers can tell a dispute that went the recipient's way from
        // one that never happened.
        uint8 b = escrow.resolvedBuyerPercentage();
        uint256 loss = (b == 255) ? 0 : (escrow.payoutAmount() * b) / 100;

        uint256 amount = holdback;
        uint256 toBeneficiary = loss < amount ? loss : amount;
        uint256 toFunder = amount - toBeneficiary;

        // ── EFFECTS FIRST ── single-shot: a second call finds status SETTLED.
        status = Status.SETTLED;
        address _token = token;
        address funder = seller;

        // ── INTERACTIONS ── (one side is zero in the common cases)
        if (toBeneficiary > 0) IERC20(_token).safeTransfer(beneficiary, toBeneficiary);
        if (toFunder > 0) IERC20(_token).safeTransfer(funder, toFunder);

        emit HoldbackReleased(escrowContract, funder, beneficiary, toFunder, toBeneficiary);
    }

    // ───────────────────────────────────────────────────────────────────────────
    // Views
    // ───────────────────────────────────────────────────────────────────────────

    /// @notice True while this vault still holds the LP's deposit awaiting a decision.
    function isOpen() external view returns (bool) {
        return status == Status.OPEN;
    }

    /**
     * 🔎 WOULD releaseHoldback() SUCCEED RIGHT NOW?
     *
     * The counterpart to isWithdrawable(), and it exists for the same reason (§15.2): nothing
     * on-chain announces that an escrow settled, so the reserve's release has to be detected
     * off-chain and either prompted or fired. A caller that restates the conditions here in
     * its own code drifts from them; this way it reads the contract's own answer.
     *
     * ⚠️ IT MATTERS MOST FOR THE DISPUTED CASE, WHICH LOOKS UNRELEASABLE AND IS NOT. A
     *    resolution marks the escrow claimed in the same transaction that pays it out, so a
     *    dispute-resolved escrow is settled and its reserve is releasable — that is precisely
     *    the case where the split is non-trivial. A caller that treats "disputed" as "leave
     *    it alone" strands the reserve exactly when it is doing its job.
     */
    function isReleasable() external view returns (bool) {
        if (status != Status.ACCEPTED || holdback == 0) return false;
        return IStabledropEscrow(escrowContract).isClaimed();
    }

    /// @notice What this vault still owes someone. Anything above it was sent here by
    ///         mistake and is recoverable by sweep().
    ///
    /// @dev PENDING owes whatever is actually sitting here, which under DIRECT TRANSFER
    ///      funding is the LP's in-flight deposit — theirs from the moment it lands, in the
    ///      window between the transfer and fund(). Treating PENDING as owing nothing was
    ///      right when a PENDING vault was necessarily empty (approve+transferFrom moved
    ///      money and opened the offer in one call); now it would let sweep() take a
    ///      deposit to FEE_RECIPIENT.
    ///
    ///      It is the live balance and NOT offerAmount because the deposit may be partial,
    ///      or absent entirely — claiming a fixed obligation against an empty vault would
    ///      report every unfunded offer as insolvent (§14.3.1).
    ///
    /// @dev ⚠️ OPEN AND CANCELLED OWE THE BALANCE WHEN IT EXCEEDS THE OFFER, for the same
    ///      reason: an LP who overpaid still owns the difference, and `withdraw()` now hands
    ///      it back. Reporting a flat offerAmount here declared that surplus sweepable — so
    ///      the owner could take an LP's overpayment before they had any chance to recover
    ///      it, and could take it from a live offer, not just a finished one.
    ///
    ///      Still floored at offerAmount rather than being the bare balance, so the solvency
    ///      invariant keeps biting: a funded offer must cover its face value, and `owed()`
    ///      collapsing to whatever happens to be present would make that assertion vacuous.
    function owed() public view returns (uint256) {
        if (status == Status.PENDING) return IERC20(token).balanceOf(address(this));
        if (status == Status.OPEN || status == Status.CANCELLED) {
            uint256 balance = IERC20(token).balanceOf(address(this));
            return balance > offerAmount ? balance : offerAmount;
        }
        if (status == Status.ACCEPTED) return holdback;
        return 0;
    }

    /**
     * 🧹 RECOVER TOKENS SENT HERE BY MISTAKE
     *
     * A routine occurrence for any address users can see. Sweeps ONLY the excess above
     * what this vault still owes someone, so it is structurally incapable of touching the
     * LP's deposit or a live reserve — the same guarantee the pooled design gave, but now
     * checkable against one offer's own balance rather than a global ledger.
     *
     * Restricted to the factory owner and hard-wired to send to FEE_RECIPIENT, so the
     * caller chooses neither the amount nor the destination. Mis-sent funds are a platform
     * housekeeping matter, not one of the deal's parties' business.
     *
     * Works for any token, including this offer's own: a stray extra transfer of the offer
     * token is recoverable above `owed()`, and once the vault is SETTLED its whole balance
     * is by definition surplus.
     */
    function sweep(address sweptToken) external onlyInitialized nonReentrant {
        address factoryOwner = IOfferVaultFactory(FACTORY).owner();
        if (msg.sender != factoryOwner) revert OnlyFactoryOwner(msg.sender);

        uint256 balance = IERC20(sweptToken).balanceOf(address(this));
        uint256 reserved = sweptToken == token ? owed() : 0;
        if (balance <= reserved) revert NothingToSweep();

        address to = IOfferVaultFactory(FACTORY).feeRecipient();
        uint256 excess = balance - reserved;
        IERC20(sweptToken).safeTransfer(to, excess);

        emit TokenSwept(sweptToken, to, excess);
    }
}
