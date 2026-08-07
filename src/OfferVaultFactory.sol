// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {OfferVault, IStabledropEscrow} from "./OfferVault.sol";

/**
 * ═══════════════════════════════════════════════════════════════════════════════════
 * 🏭 OfferVaultFactory — DEPLOYS OFFERS, HOLDS NO MONEY
 * ═══════════════════════════════════════════════════════════════════════════════════
 *
 * The venue. It validates and prices offers and deploys one OfferVault per offer. It never
 * custodies a token: an LP's capital goes straight from their wallet into their own vault,
 * and the protocol fee goes straight to FEE_RECIPIENT at acceptance.
 *
 * 🔒 IT IS ALSO STATELESS PER ESCROW AND PER OFFER
 *
 *    The one cross-offer fact — whether an escrow has already been sold, which decides
 *    if a reserve may be set (§5.3) — lives on the ESCROW itself as `hasBeenSold`, set by
 *    `transferRecipientFrom`. Vaults read it straight from there.
 *
 *    That leaves this contract with no per-escrow and no per-offer storage at all, which
 *    means it can be redeployed freely: a new venue reads the same truth off the same
 *    escrows, with nothing to migrate and no way to lose the one-reserve guarantee. The
 *    offer book is likewise not kept here — `OfferCreated` events are the index.
 *
 * 🔒 WHAT THE OWNER CAN DO: set the fee rate, the minimum-offer floor, the default offer
 *    duration and the fee recipient; pause NEW offers and acceptances. What the owner
 *    CANNOT do: touch a deposit or a reserve. Those live in vaults this contract cannot
 *    move funds out of, and the exits (withdraw, releaseHoldback, reject) are never
 *    pausable (§5.2.10).
 * ═══════════════════════════════════════════════════════════════════════════════════
 */
contract OfferVaultFactory is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ───────────────────────────────────────────────────────────────────────────
    // Errors
    // ───────────────────────────────────────────────────────────────────────────
    error UntrustedEscrow(address escrowContract);
    error InstantEscrowNotSupported(address escrowContract);
    error EscrowNotSellable(address escrowContract);
    error OfferExpiryExceedsEscrowMaturity(uint256 offerExpiry, uint256 maturity);
    error LpCannotBeEscrowParty(address lp);
    error OfferBelowMinimum(uint256 offerAmount, uint256 minimum);
    error HoldbackExceedsOffer(uint256 holdback, uint256 fee, uint256 offerAmount);
    error HoldbackOnResale(address escrowContract);
    error FeeTooHigh(uint256 requested, uint256 max);
    error MinOfferTooHigh(uint256 requested, uint256 max);
    error ZeroOfferDuration();
    error ZeroAddress();
    error NothingToSweep(address token);

    // ───────────────────────────────────────────────────────────────────────────
    // Events
    // ───────────────────────────────────────────────────────────────────────────
    event OfferCreated(
        address indexed escrowContract,
        address indexed lp,
        address indexed seller,
        address vault,
        address token,
        uint256 offerAmount,
        uint256 netAmount,
        uint256 fee,
        uint256 holdback,
        uint256 offerExpiry
    );
    event FeeRateUpdated(uint256 newFeeRateBps);
    event MinOfferUpdated(uint256 newMinOfferBps);
    event DefaultOfferDurationUpdated(uint256 durationSeconds);
    event FeeRecipientUpdated(address newFeeRecipient);
    event TokenSwept(address indexed token, address to, uint256 amount);

    // ───────────────────────────────────────────────────────────────────────────
    // State
    // ───────────────────────────────────────────────────────────────────────────

    /// @notice The OfferVault implementation cloned for every offer.
    address public immutable VAULT_IMPLEMENTATION;

    /// @notice The audited EscrowContract implementation this venue serves.
    address public immutable TRUSTED_IMPLEMENTATION;

    /// @notice The ERC-1167 minimal-proxy runtime codehash embedding TRUSTED_IMPLEMENTATION.
    bytes32 public immutable EXPECTED_ESCROW_CODEHASH;

    uint256 public feeRateBps; // e.g. 100 = 1%; hard cap 1000 (10%)
    uint256 public minOfferBps; // floor as bps of payoutAmount(); cap 10000
    uint256 public defaultOfferDuration; // always > 0
    address public feeRecipient;

    uint256 public constant MAX_FEE_BPS = 1000; // 10%
    uint256 public constant BPS_DENOMINATOR = 10000;

    /**
     * @param vaultImplementation The OfferVault implementation to clone per offer.
     * @param trustedImplementation The audited EscrowContract implementation. Only ERC-1167
     *        clones of exactly this address are tradeable here.
     * @param initialOwner Ownable2Step initial owner. MUST be distinct from the escrow's
     *        DEFAULT_ARBITER — a single key that both sets fees and arbitrates disputes is
     *        a total-compromise target.
     */
    constructor(
        address vaultImplementation,
        address trustedImplementation,
        uint256 initialFeeRateBps,
        uint256 initialMinOfferBps,
        uint256 initialDefaultOfferDuration,
        address initialFeeRecipient,
        address initialOwner
    ) Ownable(_requireNonZero(initialOwner)) {
        if (vaultImplementation == address(0)) revert ZeroAddress();
        if (trustedImplementation == address(0)) revert ZeroAddress();
        if (initialFeeRecipient == address(0)) revert ZeroAddress();
        if (initialFeeRateBps > MAX_FEE_BPS) revert FeeTooHigh(initialFeeRateBps, MAX_FEE_BPS);
        if (initialMinOfferBps > BPS_DENOMINATOR) revert MinOfferTooHigh(initialMinOfferBps, BPS_DENOMINATOR);
        if (initialDefaultOfferDuration == 0) revert ZeroOfferDuration();

        VAULT_IMPLEMENTATION = vaultImplementation;
        TRUSTED_IMPLEMENTATION = trustedImplementation;
        feeRateBps = initialFeeRateBps;
        minOfferBps = initialMinOfferBps;
        defaultOfferDuration = initialDefaultOfferDuration;
        feeRecipient = initialFeeRecipient;

        EXPECTED_ESCROW_CODEHASH = keccak256(
            abi.encodePacked(hex"363d3d373d3d3d363d73", trustedImplementation, hex"5af43d82803e903d91602b57fd5bf3")
        );
    }

    // ───────────────────────────────────────────────────────────────────────────
    // §6.1 createOffer
    // ───────────────────────────────────────────────────────────────────────────

    /**
     * 💧 DEPLOY AN OFFER — ONE CONTRACT, ONE LP, ONE ESCROW
     *
     * Prices and validates the offer, then deploys the vault that will hold it. **No money
     * moves here.** The named LP funds their own vault afterwards by calling `fund()` on
     * it, with their own signature.
     *
     * 🔒 PERMISSIONLESS, exactly like `EscrowContractFactory.createEscrowContract`: the LP
     *    is a PARAMETER, not the caller, so the platform can deploy the vault on a user's
     *    behalf (which is how chainservice drives it) without gaining any power over the
     *    money. Deploying a vault for an LP who never funds it costs the deployer gas and
     *    achieves nothing — there is no approval to drain and no state to corrupt.
     *
     * @param escrowContract The escrow whose cashflow is being bid on.
     * @param lp             The liquidity provider this offer belongs to. Only they can
     *                       fund it, and only they can withdraw from it.
     * @param offerAmount    Gross the LP will deposit. The seller nets this minus fee and
     *                       holdback.
     * @param holdback       Reserve retained at acceptance and released at settlement.
     *                       0 = advance in full. Only permitted on an escrow's FIRST sale.
     * @param offerDurationSeconds 0 = use defaultOfferDuration.
     * @return vault The newly deployed OfferVault for this offer.
     */
    function createOffer(
        address escrowContract,
        address lp,
        uint256 offerAmount,
        uint256 holdback,
        uint256 offerDurationSeconds
    ) external nonReentrant whenNotPaused returns (address vault) {
        // Validation and pricing live in their own frame purely to keep this function's
        // stack shallow — the same split the pooled design used for the same reason.
        Quote memory q = _quote(escrowContract, lp, offerAmount, holdback, offerDurationSeconds);

        // Deploy this offer's own contract. It starts empty and PENDING; only `lp` can put
        // money into it.
        vault = Clones.clone(VAULT_IMPLEMENTATION);

        OfferVault(vault).initialize(
            escrowContract, q.seller, lp, q.token, offerAmount, holdback, q.netAmount, q.fee, q.offerExpiry
        );

        emit OfferCreated(
            escrowContract, lp, q.seller, vault, q.token, offerAmount, q.netAmount, q.fee, holdback, q.offerExpiry
        );
    }

    struct Quote {
        address seller;
        address token;
        uint256 netAmount;
        uint256 fee;
        uint256 offerExpiry;
    }

    /// Validation and pricing for createOffer (spec steps 1, 3–8).
    function _quote(
        address escrowContract,
        address lp,
        uint256 offerAmount,
        uint256 holdback,
        uint256 offerDurationSeconds
    ) internal view returns (Quote memory q) {
        if (lp == address(0)) revert ZeroAddress();

        // 1. PROVENANCE. Checked against the EVM's own record of deployed code, which a
        //    hostile contract cannot forge — unlike a self-reported value such as
        //    FACTORY(), which a fake escrow could return the real factory's address for
        //    while faking payoutAmount()/recipient() and no-op'ing the role transfer. Also
        //    rejects EOAs (codehash of an empty account) and the raw implementation.
        if (escrowContract.codehash != EXPECTED_ESCROW_CODEHASH) revert UntrustedEscrow(escrowContract);

        IStabledropEscrow escrow = IStabledropEscrow(escrowContract);

        // 2. Instant-transfer escrows have no maturity to discount and settle at deposit.
        uint256 maturity = escrow.maturity();
        if (maturity == 0) revert InstantEscrowNotSupported(escrowContract);

        // 3. Sellable composite. Protects the LP from bidding on an unfunded or settled
        //    escrow, and — critically — means an LP can NEVER buy into a disputed escrow.
        //    That is what makes the arbiter veto sufficient without a registry.
        if (!escrow.isFunded() || escrow.hasActiveDispute() || escrow.isClaimed()) {
            revert EscrowNotSellable(escrowContract);
        }

        // 4. The offer must not outlive the cashflow it is bidding on.
        q.offerExpiry = block.timestamp + (offerDurationSeconds == 0 ? defaultOfferDuration : offerDurationSeconds);
        if (q.offerExpiry >= maturity) revert OfferExpiryExceedsEscrowMaturity(q.offerExpiry, maturity);

        // 5. The LP must be an outsider — checked against the NAMED lp, not the caller,
        //    since the platform may be deploying this on their behalf. The escrow re-checks
        //    buyer/arbiter at the pull; this is a clean early error rather than a failure
        //    two transactions later.
        q.seller = escrow.recipient();
        if (lp == q.seller || lp == escrow.BUYER() || lp == escrow.ARBITER()) {
            revert LpCannotBeEscrowParty(lp);
        }

        // 6. Spam floor. max(..., 1) guards the dust edge where the product rounds to 0.
        uint256 minimum = (escrow.payoutAmount() * minOfferBps) / BPS_DENOMINATOR;
        if (minimum == 0) minimum = 1;
        if (offerAmount < minimum) revert OfferBelowMinimum(offerAmount, minimum);

        // 7. Split the deposit. The fee is snapshotted HERE, so a later setFeeRate never
        //    changes what this offer pays out.
        q.fee = (offerAmount * feeRateBps) / BPS_DENOMINATOR;
        if (q.fee + holdback > offerAmount) revert HoldbackExceedsOffer(holdback, q.fee, offerAmount);

        // 8. A reserve may only be set on an escrow's FIRST sale, because it is recourse
        //    against the party who PERFORMS. The supplier did the work; if the buyer
        //    disputes and wins it is because the supplier did not deliver, so the supplier
        //    bearing first loss is exactly right. A reselling LP performed nothing. The
        //    original reserve instead travels with the cashflow it protects.
        //    Re-checked at acceptance, because this can flip in between.
        if (holdback > 0 && escrow.hasBeenSold()) revert HoldbackOnResale(escrowContract);

        q.token = escrow.token();
        q.netAmount = offerAmount - q.fee - holdback;
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

    /// @notice Applies to NEW offers only — a live offer's terms are firm.
    /// @dev The floor is a spam guard, not a price policy. A dust offer harms nothing
    ///      on-chain (it locks only the spammer's own capital, in their own contract), so
    ///      the real cost of a high floor is banning deep-discount bids — which are the
    ///      SAFEST trades for LPs, since attacker profit scales with (refund − discount).
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

    /// @notice Where protocol fees are sent at acceptance. Applies to future acceptances;
    ///         a vault reads it live at the moment it pays.
    function setFeeRecipient(address newFeeRecipient) external onlyOwner {
        if (newFeeRecipient == address(0)) revert ZeroAddress();
        feeRecipient = newFeeRecipient;
        emit FeeRecipientUpdated(newFeeRecipient);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * 🧹 RECOVER TOKENS SENT TO THE FACTORY BY MISTAKE
     *
     * This contract is never meant to hold a balance — offers hold their own capital — so
     * anything here arrived in error and all of it is sweepable. There is no deposit or
     * reserve for this to reach, by construction.
     */
    function sweepToken(address token, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) revert NothingToSweep(token);
        IERC20(token).safeTransfer(to, balance);
        emit TokenSwept(token, to, balance);
    }

    // ───────────────────────────────────────────────────────────────────────────
    // Views
    // ───────────────────────────────────────────────────────────────────────────

    function minimumOffer(address escrowContract) external view returns (uint256) {
        uint256 minimum = (IStabledropEscrow(escrowContract).payoutAmount() * minOfferBps) / BPS_DENOMINATOR;
        return minimum == 0 ? 1 : minimum;
    }

    function isTrustedEscrow(address escrowContract) external view returns (bool) {
        return escrowContract.codehash == EXPECTED_ESCROW_CODEHASH;
    }

    function _requireNonZero(address a) internal pure returns (address) {
        if (a == address(0)) revert ZeroAddress();
        return a;
    }
}
