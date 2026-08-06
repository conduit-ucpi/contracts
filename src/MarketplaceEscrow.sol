// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * Minimal view of the EscrowContract surface this marketplace consumes.
 * Deliberately narrow: everything here is either read-only or the one-shot recipient
 * pull, and genuineness of the target is established by codehash (§8.1) rather than by
 * anything the escrow reports about itself.
 */
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
    function transferRecipientFrom(address newRecipient) external;
}

/**
 * ═══════════════════════════════════════════════════════════════════════════════════
 *              💧 STABLEDROP LIQUIDITY MARKETPLACE — MarketplaceEscrow 💧
 * ═══════════════════════════════════════════════════════════════════════════════════
 *
 * Lets an escrow recipient (the SELLER — typically a supplier holding a receivable that
 * unlocks at a known future date) sell that locked cashflow to a liquidity provider (LP)
 * at a discount, via an ATOMIC, TRUSTLESS swap. No UI dependency: every function is
 * operable directly on-chain by any wallet.
 *
 * ─────────────────────────────────────────────────────────────────────────────────
 * 🔑 THE CENTRAL DESIGN PRINCIPLE: THIS CONTRACT NEVER TAKES CUSTODY OF THE ROLE
 * ─────────────────────────────────────────────────────────────────────────────────
 * The seller grants a one-shot, target-bound approval on the ESCROW; acceptOffer then
 * pulls the recipient role straight from seller to LP and pays the seller, in a single
 * transaction. The marketplace holds the recipient role for ZERO blocks.
 *
 * That is not a convenience — it structurally eliminates an entire class of failure that
 * a custody-window design has to handle case by case: a dispute payout landing on the
 * marketplace, a maturity claim landing on the marketplace, a stranded recipient role, a
 * stale seller being paid, expire-and-restore griefing. None of these are "handled" here.
 * None of them are reachable.
 *
 * ─────────────────────────────────────────────────────────────────────────────────
 * 📗 LIFECYCLE
 * ─────────────────────────────────────────────────────────────────────────────────
 *   LP deposits token ──▶ Offer created (OPEN)
 *        │
 *        ├─ Seller: escrow.approveRecipientTransfer(marketplace, lp)   (tx 1, 5-min TTL)
 *        │  Seller: marketplace.acceptOffer(escrow, lp)                (tx 2, atomic)
 *        │        ▶ role pulled to LP, seller paid, fee accrued, slot freed
 *        │        ▶ every OTHER open offer on this escrow is now STALE, withdrawable
 *        │
 *        ├─ Seller rejects ──▶ CANCELLED ──▶ LP withdraws full gross
 *        ├─ Offer expiry passes ──▶ LP withdraws full gross (no separate expire step)
 *        └─ Recipient changes for ANY reason ──▶ STALE ──▶ LP withdraws full gross
 *
 * There is no expireOffer and no reclaimRecipient: expiry and staleness are evaluated
 * lazily inside withdrawFunds, and there is no custody, so there is nothing to reclaim.
 *
 * ─────────────────────────────────────────────────────────────────────────────────
 * 💰 WHO PAYS WHAT — THE SELLER BEARS THE FEE
 * ─────────────────────────────────────────────────────────────────────────────────
 * An LP bidding X transfers exactly X. At acceptance the seller receives
 * X − fee − holdback. The fee travels inside the LP's deposit but its economic incidence
 * is on the SELLER's proceeds, not on the LP's cost.
 *
 * ⚠️ A seller who sees "offer: 10,000" and receives 9,900 will read it as a bug unless
 *    the UI shows their NET figure at bid display and at acceptance. Note also that
 *    `fee` is snapshotted at createOffer, so a later setFeeRate never changes what a
 *    live offer pays out — a seller's quote is firm from the moment it appears.
 *
 * The holdback is different from the fee: it comes back to the seller at settlement if
 * the cashflow collects in full (§5.3 / releaseHoldback below).
 *
 * ─────────────────────────────────────────────────────────────────────────────────
 * 🛡️ WHAT THE OWNER CAN AND CANNOT DO
 * ─────────────────────────────────────────────────────────────────────────────────
 * ✅ Set the fee rate (hard cap 10%), the minimum offer floor, the default offer duration
 * ✅ Withdraw ACCRUED FEES only — capped by accruedFees[token], which only ever grows at
 *    acceptance. LP deposits and holdbacks are structurally unreachable.
 * ✅ Sweep the EXCESS of a token above what the books say is owed (accidental transfers)
 * ✅ Pause — but only the INFLOWS (createOffer, acceptOffer)
 * ❌ Cannot touch a live deposit, cannot touch a holdback, cannot interfere with any
 *    individual escrow transaction, cannot stop anyone exiting
 *
 * The pause asymmetry is deliberate and load-bearing: withdrawFunds, releaseHoldback and
 * rejectOffer carry NO pause check, ever. A paused marketplace is one where nothing new
 * starts but every LP recovers every deposit and every holdback still settles. The pause
 * is a stop button that is structurally incapable of being a seize button — even a
 * malicious owner pausing forever produces only a dead venue from which everyone exits
 * whole.
 *
 * ─────────────────────────────────────────────────────────────────────────────────
 * ⚠️ RISKS AN LP MUST UNDERSTAND BEFORE BUYING
 * ─────────────────────────────────────────────────────────────────────────────────
 * 1. YOU INHERIT THE DISPUTE. After acceptance you ARE the escrow's seller-side party.
 *    The buyer can still dispute before maturity, and a 2-of-3 vote can go against you up
 *    to a full buyer refund. The escrow gives you a VETO over who arbitrates (any arbiter
 *    chosen before your purchase is unseated by the sale itself), and a holdback means the
 *    original supplier absorbs first loss — but an honest arbiter may still rule against
 *    you on the merits.
 *
 * 2. YOU CANNOT EVIDENCE THE UNDERLYING DEAL. Sharper than the above and worth its own
 *    line: you inherit a dispute about work you never performed. No delivery records, no
 *    correspondence with the buyer, and the original supplier has been paid and has no
 *    incentive to help. If the buyer alleges non-delivery you are structurally unable to
 *    rebut it. Your real levers are care in agreeing an arbiter, the holdback you set, and
 *    preferring SHORT-DATED purchases where the remaining dispute window is small.
 *
 * 3. GENUINE CODE IS NOT AN HONEST COUNTERPARTY. The codehash check proves the escrow is a
 *    real clone of the audited implementation. It says NOTHING about whether the parties
 *    are colluding. An attacker can clone the implementation directly, install a buyer they
 *    control, fund it with real tokens, sell you the cashflow, then dispute. Attacker
 *    profit scales with (refund fraction − your discount), so DEEPER DISCOUNTS ARE
 *    INHERENTLY SAFER. The sale-triggered arbiter reset kills the variant where they also
 *    pre-load the arbiter; what remains is ordinary arbitration risk.
 *
 * 4. FIRM QUOTES. You cannot cancel an OPEN offer. This is deliberate — otherwise you
 *    could bait with a high bid and front-run the seller's acceptOffer with a cancellation.
 *    Control your exposure with offerDurationSeconds instead.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════
 */
contract MarketplaceEscrow is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ───────────────────────────────────────────────────────────────────────────
    // Errors
    // ───────────────────────────────────────────────────────────────────────────
    error UntrustedEscrow(address escrowContract);
    error OfferSlotOccupied(address escrowContract, address lp);
    error OfferNotOpen(address escrowContract, address lp);
    error OfferExpired(address escrowContract, address lp);
    error OfferStale(address escrowContract, address lp);
    error NotEscrowRecipient(address caller);
    error EscrowNotSellable(address escrowContract);
    error InstantEscrowNotSupported(address escrowContract);
    error OfferExpiryExceedsEscrowMaturity(uint256 offerExpiry, uint256 maturity);
    error OfferBelowMinimum(uint256 offerAmount, uint256 minimum);
    error MinOfferTooHigh(uint256 requested, uint256 max);
    error LpCannotBeEscrowParty(address lp);
    error TransferAmountMismatch();
    error NothingToWithdraw(address escrowContract, address lp);
    error HoldbackExceedsOffer(uint256 holdback, uint256 fee, uint256 offerAmount);
    error HoldbackOnResale(address escrowContract);
    error NoHoldback(address escrowContract);
    error EscrowNotSettled(address escrowContract);
    error FeeTooHigh(uint256 requested, uint256 max);
    error InsufficientAccruedFees(address token, uint256 requested, uint256 available);
    error ZeroAddress();
    error ZeroOfferDuration();
    error NothingToSweep(address token);

    // ───────────────────────────────────────────────────────────────────────────
    // Events
    // ───────────────────────────────────────────────────────────────────────────
    event OfferCreated(
        address indexed escrowContract,
        address indexed lp,
        address indexed seller,
        address token,
        uint256 offerAmount,
        uint256 netAmount,
        uint256 fee,
        uint256 holdback,
        uint256 offerExpiry
    );
    event OfferAccepted(
        address indexed escrowContract,
        address indexed lp,
        address indexed seller,
        uint256 netAmount,
        uint256 fee,
        uint256 holdback
    );
    event HoldbackReleased(
        address indexed escrowContract,
        address indexed funder,
        address indexed beneficiary,
        uint256 toFunder,
        uint256 toBeneficiary
    );
    event OfferRejected(address indexed escrowContract, address indexed lp);
    event FundsWithdrawn(address indexed escrowContract, address indexed lp, address token, uint256 amount);
    event FeeRateUpdated(uint256 newFeeRateBps);
    event MinOfferUpdated(uint256 newMinOfferBps);
    event DefaultOfferDurationUpdated(uint256 durationSeconds);
    event FeesWithdrawn(address indexed token, address to, uint256 amount);
    event TokenSwept(address indexed token, address to, uint256 amount);

    // ───────────────────────────────────────────────────────────────────────────
    // Types & state
    // ───────────────────────────────────────────────────────────────────────────

    /// @dev NONE is the default, so an untouched slot reads as empty.
    ///      There is deliberately NO COMPLETED state. An accepted offer's slot is deleted
    ///      inside acceptOffer — the deposit has already left the contract, so there is
    ///      nothing left to track, and a persisted COMPLETED would be write-only dead
    ///      state that permanently barred that (escrow, LP) pair from ever bidding again,
    ///      quietly capping resale at one round-trip per address. Completion is recorded
    ///      by the OfferAccepted event, which is where history belongs.
    enum OfferStatus {
        NONE,
        OPEN,
        CANCELLED
    }

    struct Offer {
        address escrowContract; // The underlying escrow being sold
        address seller; // recipient() at creation — the offer is valid ONLY while this holds
        address lp; // LP wallet that made the offer
        address token; // escrow.token() at creation; every transfer for this offer uses it
        uint256 offerAmount; // Gross deposited by the LP, before fee and holdback
        uint256 holdback; // Reserve retained at acceptance, released later
        uint256 netAmount; // What the seller receives AT ACCEPTANCE
        uint256 fee; // Protocol fee, computed at creation, accrued only on acceptance
        uint256 offerExpiry; // Timestamp after which the LP may withdraw
        OfferStatus status;
    }

    /// @notice Invoice-factoring reserve. The LP advances part of the agreed price and
    ///         retains this, released once the cashflow is collected.
    /// @dev The BENEFICIARY is deliberately NOT stored — it is escrow.recipient(), read
    ///      live at settlement. That makes the reserve follow the position automatically
    ///      through any number of resales, with no state to keep in sync and no action
    ///      required on a resale. Storing it would need reassigning on every transfer, and
    ///      any missed path (a direct changeRecipient, say) would strand the reserve on a
    ///      party who no longer holds the cashflow.
    struct Holdback {
        address token;
        address funder; // the seller in this escrow's FIRST marketplace sale
        uint256 amount;
    }

    /// @notice key = keccak256(abi.encodePacked(escrowContract, lp)).
    /// @dev ONE LIVE offer record per (escrow, LP). A slot is occupied exactly while the
    ///      contract still holds that LP's deposit for that escrow, and is freed the
    ///      moment it does not — on acceptance (funds paid out) or on withdrawal (funds
    ///      returned). A cancelled-but-unwithdrawn offer therefore still owns its slot and
    ///      its deposit and can never be overwritten.
    mapping(bytes32 => Offer) public offers;

    /// @notice ONE reserve per escrow, set on the first sale only.
    mapping(address => Holdback) public holdbacks;

    /// @notice Set on first acceptance; blocks stacking a second reserve on a resale.
    mapping(address => bool) public hasBeenSold;

    /// @notice The audited EscrowContract implementation this marketplace serves.
    address public immutable TRUSTED_IMPLEMENTATION;

    /// @notice The ERC-1167 minimal-proxy runtime codehash embedding TRUSTED_IMPLEMENTATION.
    /// @dev A single immutable precisely because there is exactly ONE supported
    ///      implementation. Multi-implementation support would be a constructor and
    ///      state-layout change, not a configuration change.
    bytes32 public immutable EXPECTED_ESCROW_CODEHASH;

    uint256 public feeRateBps; // e.g. 100 = 1%; hard cap 1000 (10%)
    uint256 public minOfferBps; // floor as bps of payoutAmount(); cap 10000
    uint256 public defaultOfferDuration; // always > 0

    /// @notice Per-token protocol fees. The ONLY balance the owner can withdraw.
    mapping(address => uint256) public accruedFees;
    /// @notice Per-token sum of live LP deposits.
    mapping(address => uint256) public totalDeposits;
    /// @notice Per-token sum of live holdbacks.
    mapping(address => uint256) public totalHoldbacks;

    uint256 public constant MAX_FEE_BPS = 1000; // 10%
    uint256 public constant BPS_DENOMINATOR = 10000;

    /**
     * @param trustedImplementation The audited EscrowContract implementation. Only ERC-1167
     *        clones of exactly this address are tradeable here.
     * @param initialOwner Ownable2Step initial owner. MUST be distinct from the escrow's
     *        DEFAULT_ARBITER — a single key that both sets fees and arbitrates disputes is
     *        a total-compromise target.
     */
    constructor(
        address trustedImplementation,
        uint256 initialFeeRateBps,
        uint256 initialMinOfferBps,
        uint256 initialDefaultOfferDuration,
        address initialOwner
        // Validated inside the base-constructor argument so a zero owner reverts with this
        // contract's own ZeroAddress rather than Ownable's OwnableInvalidOwner: base
        // constructors run before the derived body, so a check placed below would be dead
        // code for that case.
    ) Ownable(_requireNonZero(initialOwner)) {
        if (trustedImplementation == address(0)) revert ZeroAddress();
        if (initialFeeRateBps > MAX_FEE_BPS) revert FeeTooHigh(initialFeeRateBps, MAX_FEE_BPS);
        if (initialMinOfferBps > BPS_DENOMINATOR) revert MinOfferTooHigh(initialMinOfferBps, BPS_DENOMINATOR);
        if (initialDefaultOfferDuration == 0) revert ZeroOfferDuration();

        TRUSTED_IMPLEMENTATION = trustedImplementation;
        feeRateBps = initialFeeRateBps;
        minOfferBps = initialMinOfferBps;
        defaultOfferDuration = initialDefaultOfferDuration;

        // The exact runtime code OpenZeppelin's Clones library deploys, with the
        // implementation address embedded in the middle.
        EXPECTED_ESCROW_CODEHASH = keccak256(
            abi.encodePacked(hex"363d3d373d3d3d363d73", trustedImplementation, hex"5af43d82803e903d91602b57fd5bf3")
        );
    }

    // ───────────────────────────────────────────────────────────────────────────
    // §6.1 createOffer
    // ───────────────────────────────────────────────────────────────────────────

    /**
     * 💧 LP MAKES A FIRM, FUNDED OFFER FOR AN ESCROW'S CASHFLOW
     *
     * The deposit is pulled here and held until the seller accepts, the seller rejects,
     * the offer expires, or the escrow becomes permanently unacceptable. An OPEN offer is
     * an IRREVOCABLE commitment — see the firm-quotes note in the contract header.
     *
     * @param escrowContract The escrow whose cashflow is being bid on.
     * @param offerAmount    Gross amount to deposit. The seller nets this minus fee and
     *                       holdback; bid accordingly.
     * @param holdback       Reserve retained at acceptance and released at settlement.
     *                       0 = advance in full. Only permitted on an escrow's FIRST sale.
     * @param offerDurationSeconds 0 = use defaultOfferDuration.
     */
    function createOffer(address escrowContract, uint256 offerAmount, uint256 holdback, uint256 offerDurationSeconds)
        external
        nonReentrant
        whenNotPaused
    {
        // 2. Slot must be empty. A slot is occupied exactly while we hold that LP's
        //    deposit for that escrow, so this can only collide with a live or
        //    cancelled-but-unwithdrawn offer — never with a completed one.
        //    (Step 1, the provenance check, is the first thing _quoteOffer does.)
        bytes32 key = _offerKey(escrowContract, msg.sender);
        if (offers[key].status != OfferStatus.NONE) revert OfferSlotOccupied(escrowContract, msg.sender);

        // Steps 1 and 3–8: validate everything and price the offer. Split into its own
        // frame purely to keep this function's stack shallow.
        Offer memory o = _quoteOffer(escrowContract, offerAmount, holdback, offerDurationSeconds);

        // 9. Pull the deposit with a balance-delta check, rejecting fee-on-transfer and
        //    deflationary tokens — mirroring the escrow's own deposit guard. Every payout
        //    elsewhere assumes exactly offerAmount arrived.
        uint256 balanceBefore = IERC20(o.token).balanceOf(address(this));
        IERC20(o.token).safeTransferFrom(msg.sender, address(this), offerAmount);
        if (IERC20(o.token).balanceOf(address(this)) - balanceBefore != offerAmount) {
            revert TransferAmountMismatch();
        }

        // 10. Book it.
        totalDeposits[o.token] += offerAmount;
        offers[key] = o;

        emit OfferCreated(
            escrowContract, msg.sender, o.seller, o.token, offerAmount, o.netAmount, o.fee, holdback, o.offerExpiry
        );
    }

    /**
     * Validation and pricing for createOffer (spec steps 1, 3–8). Returns the fully-formed
     * Offer record; the caller performs the token pull and the store.
     */
    function _quoteOffer(address escrowContract, uint256 offerAmount, uint256 holdback, uint256 offerDurationSeconds)
        internal
        view
        returns (Offer memory o)
    {
        // 1. PROVENANCE. Checked against the EVM's own record of deployed code, which a
        //    hostile contract cannot forge — unlike a self-reported value such as
        //    FACTORY(), which a fake escrow could simply return the real factory's address
        //    for while faking payoutAmount()/recipient() and no-op'ing the role transfer.
        //    This also rejects EOAs (codehash of an empty account) and the raw
        //    implementation itself.
        //
        //    Checked ONCE, here, and deliberately NOT re-checked at acceptOffer: a deployed
        //    clone's codehash is immutable and a minimal proxy has no SELFDESTRUCT path, so
        //    the value cannot change between the two calls. Re-reading it would be pure gas.
        //    The MUTABLE conditions below ARE re-checked at acceptance, because those
        //    genuinely can change.
        if (escrowContract.codehash != EXPECTED_ESCROW_CODEHASH) revert UntrustedEscrow(escrowContract);

        IStabledropEscrow escrow = IStabledropEscrow(escrowContract);

        // 3. Instant-transfer escrows have no maturity to discount and settle at deposit.
        uint256 maturity = escrow.maturity();
        if (maturity == 0) revert InstantEscrowNotSupported(escrowContract);

        // 4. Sellable composite. Protects the LP from bidding on an unfunded or
        //    already-settled escrow, and — critically — means an LP can NEVER buy into a
        //    disputed escrow. That is what makes the arbiter veto sufficient without a
        //    registry: an LP is never bound by a selection made before they arrived.
        if (!escrow.isFunded() || escrow.hasActiveDispute() || escrow.isClaimed()) {
            revert EscrowNotSellable(escrowContract);
        }

        // 5. The offer must not outlive the cashflow it is bidding on.
        o.offerExpiry = block.timestamp + (offerDurationSeconds == 0 ? defaultOfferDuration : offerDurationSeconds);
        if (o.offerExpiry >= maturity) revert OfferExpiryExceedsEscrowMaturity(o.offerExpiry, maturity);

        // 6. The LP must be an outsider. The escrow re-checks buyer/arbiter at the pull;
        //    this is a clean early error rather than a failure three transactions later.
        o.seller = escrow.recipient();
        if (msg.sender == o.seller || msg.sender == escrow.BUYER() || msg.sender == escrow.ARBITER()) {
            revert LpCannotBeEscrowParty(msg.sender);
        }

        // 7. Spam floor. max(..., 1) guards the dust edge where the product rounds to 0,
        //    so the minimum is never zero even at minOfferBps == 0.
        uint256 minimum = (escrow.payoutAmount() * minOfferBps) / BPS_DENOMINATOR;
        if (minimum == 0) minimum = 1;
        if (offerAmount < minimum) revert OfferBelowMinimum(offerAmount, minimum);

        // 8. Split the deposit. The fee is snapshotted HERE, so a later setFeeRate never
        //    changes what this offer pays out.
        o.fee = (offerAmount * feeRateBps) / BPS_DENOMINATOR;
        if (o.fee + holdback > offerAmount) revert HoldbackExceedsOffer(holdback, o.fee, offerAmount);

        // A reserve may only be set on an escrow's FIRST sale, because it is recourse
        // against the party who PERFORMS. The supplier did the work; if the buyer disputes
        // and wins it is because the supplier did not deliver, so the supplier bearing
        // first loss is exactly right. A reselling LP performed nothing, so "LP1 funds
        // LP2's first loss" does not follow. The original reserve instead travels with the
        // cashflow it protects.
        if (holdback > 0 && hasBeenSold[escrowContract]) revert HoldbackOnResale(escrowContract);

        o.escrowContract = escrowContract;
        o.lp = msg.sender;
        o.token = escrow.token();
        o.offerAmount = offerAmount;
        o.holdback = holdback;
        o.netAmount = offerAmount - o.fee - holdback;
        o.status = OfferStatus.OPEN;
    }

    // ───────────────────────────────────────────────────────────────────────────
    // §6.2 acceptOffer
    // ───────────────────────────────────────────────────────────────────────────

    /**
     * 🤝 SELLER ACCEPTS — THE ATOMIC SWAP
     *
     * PRE-CONDITION (tx 1, by the seller, on the ESCROW):
     *     escrow.approveRecipientTransfer(marketplace, lp)
     * which binds both this contract as operator AND the exact LP as destination, for 5
     * minutes. Without it — or after it expires — the pull below reverts and NOTHING
     * moves; the seller simply re-approves and calls again.
     *
     * Every other OPEN offer on this escrow becomes stale the instant this succeeds,
     * because recipient() has changed. Each of those LPs withdraws their full gross via
     * withdrawFunds. There is no cancellation loop, no gas ceiling, and no event storm —
     * which is exactly what makes sybil dust offers unable to DoS this function.
     */
    function acceptOffer(address escrowContract, address lp) external nonReentrant whenNotPaused {
        bytes32 key = _offerKey(escrowContract, lp);
        Offer storage offer = offers[key];

        // ── CHECKS ──
        if (offer.status != OfferStatus.OPEN) revert OfferNotOpen(escrowContract, lp);
        if (block.timestamp > offer.offerExpiry) revert OfferExpired(escrowContract, lp);

        IStabledropEscrow escrow = IStabledropEscrow(escrowContract);

        // Live read, never the snapshot. Payment always goes to
        // msg.sender == offer.seller == recipient(), so a stale snapshot can never be paid.
        address seller = escrow.recipient();
        if (msg.sender != seller) revert NotEscrowRecipient(msg.sender);
        if (seller != offer.seller) revert OfferStale(escrowContract, lp);

        if (!escrow.isFunded() || escrow.hasActiveDispute() || escrow.isClaimed()) {
            revert EscrowNotSellable(escrowContract);
        }

        // ⚠️ RE-CHECKED HERE, not only at createOffer. `hasBeenSold` can flip between an
        // offer's creation and its acceptance, and this offer's holdback was validated
        // against the value at CREATION time.
        //
        // The sequence that breaks without this: two LPs both bid with a holdback while the
        // escrow is unsold (both legal). The seller accepts the first, which records the one
        // permitted reserve. The position then returns to that same seller by ANY route — a
        // direct changeRecipient back, or the seller buying their own cashflow back as an LP
        // — which makes the second offer live again, because its `seller` snapshot matches
        // the current recipient once more. Accepting it would OVERWRITE holdbacks[escrow]
        // while still adding to totalHoldbacks, stranding the first reserve permanently: no
        // record remains to release it, and sweepToken subtracts totalHoldbacks, so the
        // tokens become unreachable by everyone including the funder who put them up.
        if (offer.holdback > 0 && hasBeenSold[escrowContract]) revert HoldbackOnResale(escrowContract);

        // ── EFFECTS ──
        // Cache first: the delete below destroys the struct, so every later step MUST read
        // these locals rather than `offer`.
        address token = offer.token;
        uint256 offerAmount = offer.offerAmount;
        uint256 netAmount = offer.netAmount;
        uint256 fee = offer.fee;
        uint256 holdback = offer.holdback;

        totalDeposits[token] -= offerAmount;
        accruedFees[token] += fee;

        // The delete is what marks the offer consumed: the slot reads NONE, so a re-entrant
        // acceptOffer fails the status check above. It also keeps re-bidding possible — an
        // LP who buys this escrow and later resells it may bid on it again.
        delete offers[key];

        hasBeenSold[escrowContract] = true;

        // Only reachable on a first sale (createOffer rejects a holdback once hasBeenSold).
        // Nothing is written on a resale: the existing reserve already follows the position,
        // since its beneficiary is read live at settlement.
        if (holdback > 0) {
            holdbacks[escrowContract] = Holdback({token: token, funder: seller, amount: holdback});
            totalHoldbacks[token] += holdback;
        }

        // Conservation: netAmount + fee + holdback == offerAmount, by construction at
        // createOffer.

        // ── INTERACTIONS ──
        // a. Pull the recipient role directly seller → LP using the one-shot approval. The
        //    escrow enforces lp != zero/buyer/arbiter, resets the LP's dispute vote, and
        //    UNSEATS the incumbent arbiter (the sale-triggered reset that makes a
        //    pre-loaded 2-of-3 majority unmanufacturable).
        escrow.transferRecipientFrom(lp);

        // b. Pay the seller their net. Skipped when zero (reachable when the LP quotes a
        //    holdback that consumes the whole offer): some ERC20s revert on a zero-value
        //    transfer, which would otherwise make such an offer permanently unacceptable.
        if (netAmount > 0) IERC20(token).safeTransfer(seller, netAmount);

        emit OfferAccepted(escrowContract, lp, seller, netAmount, fee, holdback);
    }

    // ───────────────────────────────────────────────────────────────────────────
    // §6.3 rejectOffer
    // ───────────────────────────────────────────────────────────────────────────

    /**
     * 🚫 SELLER DECLINES AN OFFER
     *
     * Only the CURRENT recipient may reject — a stale offer needs no rejection, it is
     * already withdrawable.
     *
     * ⚠️ The slot is deliberately NOT freed here: this contract still holds the LP's
     *    deposit, so it must keep tracking it. The LP calls withdrawFunds to recover the
     *    deposit and free the slot. Consequence: an LP who wants to re-bid higher after a
     *    rejection needs three transactions (reject → withdraw → new offer).
     *
     * NOT pausable — this is an exit path (§5.2.10).
     */
    function rejectOffer(address escrowContract, address lp) external nonReentrant {
        bytes32 key = _offerKey(escrowContract, lp);
        Offer storage offer = offers[key];

        if (offer.status != OfferStatus.OPEN) revert OfferNotOpen(escrowContract, lp);
        if (msg.sender != offer.seller) revert NotEscrowRecipient(msg.sender);
        if (IStabledropEscrow(escrowContract).recipient() != offer.seller) revert OfferStale(escrowContract, lp);

        offer.status = OfferStatus.CANCELLED;

        emit OfferRejected(escrowContract, lp);
    }

    // ───────────────────────────────────────────────────────────────────────────
    // §6.4 withdrawFunds
    // ───────────────────────────────────────────────────────────────────────────

    /**
     * 💸 LP RECOVERS THEIR DEPOSIT — IN FULL GROSS, INCLUDING THE NEVER-ACCRUED FEE
     *
     * Expiry and staleness are evaluated lazily HERE rather than in a separate expire step;
     * nothing on-chain notifies the LP, so the indexer must detect these conditions and
     * prompt.
     *
     * No withdrawable offer is ever simultaneously acceptable — acceptance rejects all
     * three of expired, stale and disputed/claimed — so there is no accept/withdraw race.
     *
     * NOT pausable — this is THE exit path (§5.2.10).
     */
    function withdrawFunds(address escrowContract) external nonReentrant {
        bytes32 key = _offerKey(escrowContract, msg.sender);
        Offer storage offer = offers[key];

        OfferStatus status = offer.status;
        bool withdrawable;

        if (status == OfferStatus.CANCELLED) {
            withdrawable = true;
        } else if (status == OfferStatus.OPEN) {
            IStabledropEscrow escrow = IStabledropEscrow(escrowContract);
            withdrawable = block.timestamp > offer.offerExpiry // expired
                || escrow.recipient() != offer.seller // stale — recipient changed
                || 
                // Permanently unacceptable: a dispute can only resolve to settled (state 2
                // never returns to state 1), so the offer can never be accepted again. The
                // LP exits immediately instead of waiting out offerExpiry.
                escrow.hasActiveDispute() || escrow.isClaimed()
                // Likewise permanently unacceptable: this offer quotes a holdback, but the
                // escrow has since had its first sale, so acceptOffer will always reject it
                // (only the first sale may set a reserve). Without this the LP's capital
                // would sit locked until expiry for an offer that can never be taken.
                || (offer.holdback > 0 && hasBeenSold[escrowContract]);
        }

        if (!withdrawable) revert NothingToWithdraw(escrowContract, msg.sender);

        // ── EFFECTS FIRST ──
        address token = offer.token;
        uint256 offerAmount = offer.offerAmount;

        totalDeposits[token] -= offerAmount;
        delete offers[key]; // frees the slot for a future offer

        // ── INTERACTIONS ──
        IERC20(token).safeTransfer(msg.sender, offerAmount);

        emit FundsWithdrawn(escrowContract, msg.sender, token, offerAmount);
    }

    // ───────────────────────────────────────────────────────────────────────────
    // §6.7 releaseHoldback
    // ───────────────────────────────────────────────────────────────────────────

    /**
     * 🏦 SETTLE THE RESERVE ONCE THE CASHFLOW HAS FINALLY COLLECTED
     *
     * Permissionless and single-shot: it takes no discretion, and both destinations are
     * fixed by the escrow's own final state. Anyone may trigger it; the funds can only
     * ever reach the recorded funder and the escrow's CURRENT recipient.
     *
     * The cashflow itself never passes through this contract — the escrow pays its
     * recipient directly and this settles only the reserve. A complete payout is therefore
     * two independent, permissionless transactions, and neither blocks the other:
     *
     *   Undisputed     │ escrow: full payoutAmount → beneficiary │ here: full → funder
     *   Disputed, b%   │ escrow: L → buyer, rest → beneficiary   │ here: min(amount, L) →
     *                  │   where L = payoutAmount × b / 100      │   beneficiary, rest → funder
     *
     * Read the rows together: undisputed, the beneficiary collects the whole cashflow and
     * the funder gets their reserve back; disputed, the beneficiary is made whole out of
     * the reserve up to its size, and only what it cannot cover is a real loss to them.
     *
     * ⏳ LIVENESS: this is only releasable once the escrow reaches its settled state. Since
     *    dispute resolution has no deadline, a dispute that never resolves leaves the
     *    reserve locked alongside the escrow itself. Same freeze surface as the escrow's,
     *    with the same remedy (evictArbiter) — the reserve inherits the escrow's liveness
     *    rather than having its own.
     *
     * NOT pausable — this is an exit path (§5.2.10).
     */
    function releaseHoldback(address escrowContract) external nonReentrant {
        Holdback storage h = holdbacks[escrowContract];
        uint256 amount = h.amount;
        if (amount == 0) revert NoHoldback(escrowContract);

        IStabledropEscrow escrow = IStabledropEscrow(escrowContract);

        // Covers BOTH terminal paths — claimed at maturity and dispute-resolved — because
        // executing a resolution also marks the escrow claimed. An escrow still funded or
        // still disputed is not settleable, and reverting keeps the reserve in place until
        // the outcome is known.
        if (!escrow.isClaimed()) revert EscrowNotSettled(escrowContract);

        // Read LIVE, so the reserve lands on whoever holds the position, no matter how many
        // times it changed hands or by what route.
        address beneficiary = escrow.recipient();

        // 255 = never disputed. Note the sentinel is not load-bearing here: a 0% resolution
        // yields loss == 0 too, so both cases pay the funder in full. It is kept for
        // observability — indexers can tell a dispute that went the recipient's way from
        // one that never happened.
        uint8 b = escrow.resolvedBuyerPercentage();
        uint256 loss = (b == 255) ? 0 : (escrow.payoutAmount() * b) / 100;

        uint256 toBeneficiary = loss < amount ? loss : amount;
        uint256 toFunder = amount - toBeneficiary;

        // ── EFFECTS FIRST ──
        address token = h.token;
        address funder = h.funder;

        totalHoldbacks[token] -= amount;
        delete holdbacks[escrowContract]; // makes this single-shot: a second call finds 0

        // ── INTERACTIONS ── (one side is zero in the common cases)
        if (toBeneficiary > 0) IERC20(token).safeTransfer(beneficiary, toBeneficiary);
        if (toFunder > 0) IERC20(token).safeTransfer(funder, toFunder);

        emit HoldbackReleased(escrowContract, funder, beneficiary, toFunder, toBeneficiary);
    }

    // ───────────────────────────────────────────────────────────────────────────
    // §6.5 Owner surface
    // ───────────────────────────────────────────────────────────────────────────

    /// @notice Applies to NEW offers only — live offers snapshotted their fee at creation.
    function setFeeRate(uint256 newFeeRateBps) external onlyOwner {
        if (newFeeRateBps > MAX_FEE_BPS) revert FeeTooHigh(newFeeRateBps, MAX_FEE_BPS);
        feeRateBps = newFeeRateBps;
        emit FeeRateUpdated(newFeeRateBps);
    }

    /// @notice Applies to NEW offers only — a live offer was validated at creation and its
    ///         terms are firm.
    /// @dev The floor is a spam guard, not a price policy. With no enumeration array a dust
    ///      offer harms nothing on-chain (it occupies only its own slot and locks the
    ///      spammer's own capital), so the real cost of a high floor is banning
    ///      deep-discount bids — which are the SAFEST trades for LPs, since attacker profit
    ///      scales with (refund fraction − discount).
    function setMinOfferBps(uint256 newMinOfferBps) external onlyOwner {
        if (newMinOfferBps > BPS_DENOMINATOR) revert MinOfferTooHigh(newMinOfferBps, BPS_DENOMINATOR);
        minOfferBps = newMinOfferBps;
        emit MinOfferUpdated(newMinOfferBps);
    }

    /// @dev Must be > 0: a zero default would make offers expire at creation.
    function setDefaultOfferDuration(uint256 durationSeconds) external onlyOwner {
        if (durationSeconds == 0) revert ZeroOfferDuration();
        defaultOfferDuration = durationSeconds;
        emit DefaultOfferDurationUpdated(durationSeconds);
    }

    /// @notice Withdraw protocol fees. Capped by accruedFees[token], which only ever grows
    ///         at acceptance — LP deposits and holdbacks are structurally unreachable.
    function withdrawFees(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 available = accruedFees[token];
        if (amount > available) revert InsufficientAccruedFees(token, amount, available);

        accruedFees[token] = available - amount; // decrement BEFORE the transfer

        IERC20(token).safeTransfer(to, amount);

        emit FeesWithdrawn(token, to, amount);
    }

    /**
     * 🧹 RECOVER TOKENS SENT STRAIGHT TO THIS ADDRESS BY MISTAKE
     *
     * A routine occurrence for any well-known contract. Sweeps ONLY the excess above
     * everything the books say is owed to someone, so it is structurally incapable of
     * touching a live deposit, an accrued fee, or a holdback.
     *
     * Not pausable — an owner recovery path, not an inflow.
     */
    function sweepToken(address token, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();

        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 owed = totalDeposits[token] + accruedFees[token] + totalHoldbacks[token];
        if (balance <= owed) revert NothingToSweep(token);

        uint256 excess = balance - owed;

        IERC20(token).safeTransfer(to, excess);

        emit TokenSwept(token, to, excess);
    }

    /// @notice Halts createOffer and acceptOffer ONLY. Exits are never pausable.
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ───────────────────────────────────────────────────────────────────────────
    // Views
    // ───────────────────────────────────────────────────────────────────────────

    /// @notice The offers-mapping key for an (escrow, LP) pair.
    function offerKey(address escrowContract, address lp) external pure returns (bytes32) {
        return _offerKey(escrowContract, lp);
    }

    /// @notice Convenience read of a whole offer without destructuring the public getter.
    function getOffer(address escrowContract, address lp) external view returns (Offer memory) {
        return offers[_offerKey(escrowContract, lp)];
    }

    /// @notice The minimum acceptable offerAmount for an escrow right now, at the CURRENT
    ///         minOfferBps. Never zero.
    function minimumOffer(address escrowContract) external view returns (uint256) {
        uint256 minimum = (IStabledropEscrow(escrowContract).payoutAmount() * minOfferBps) / BPS_DENOMINATOR;
        return minimum == 0 ? 1 : minimum;
    }

    /// @notice Whether an escrow is a genuine clone of the trusted implementation.
    function isTrustedEscrow(address escrowContract) external view returns (bool) {
        return escrowContract.codehash == EXPECTED_ESCROW_CODEHASH;
    }

    function _offerKey(address escrowContract, address lp) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(escrowContract, lp));
    }

    function _requireNonZero(address a) internal pure returns (address) {
        if (a == address(0)) revert ZeroAddress();
        return a;
    }
}
