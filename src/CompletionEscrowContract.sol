// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * ═══════════════════════════════════════════════════════════════════════════════════
 *            🤝 COMPLETION ESCROW WITH DUAL-VERIFY + RECIPIENT SPLIT 🤝
 * ═══════════════════════════════════════════════════════════════════════════════════
 *
 * A variant of the practical escrow primitive with two additional abilities:
 *
 * 1. DUAL-VERIFY COMPLETION
 *    The SELLER (supplier) marks the work complete; the BUYER must then verify before
 *    funds pay out. Payout happens automatically inside the BUYER's verify call.
 *    This makes the contract a node in a tree of fan-out payments: each node is gated
 *    by BOTH supplier and buyer agreement.
 *
 * 2. UP TO MAX_RECIPIENTS PAYOUT RECIPIENTS
 *    Instead of paying a single SELLER, the escrowed funds are split between 1..N
 *    recipient addresses by a configured basis-point split (the shares sum to 10000).
 *    The SELLER is the supplier (who marks complete and votes in disputes) and is NOT
 *    necessarily a recipient.
 *
 * ─────────────────────────────────────────────────────────────────────────────────
 * 💰 WHERE MONEY CAN GO (enforced by code)
 * ─────────────────────────────────────────────────────────────────────────────────
 * ✅ RECIPIENTS (1..MAX_RECIPIENTS): Receive the escrowed amount, split by basis
 *    points, on a successful dual-verify OR as the supplier-side share of a dispute.
 * ✅ BUYER: Receives a refund share on a dispute resolution.
 * ✅ FEE_RECIPIENT: Receives the small platform fee once, at deposit time.
 * ❌ NOBODY ELSE.
 *
 * ─────────────────────────────────────────────────────────────────────────────────
 * 🛡️ TRANSACTION FLOWS
 * ─────────────────────────────────────────────────────────────────────────────────
 * 📗 Happy Path:
 *    Buyer deposits → Seller marks complete → Buyer verifies → recipients paid → Done
 *
 * 📕 Disputed Path:
 *    Buyer deposits → Buyer disputes (before expiry) → 2-of-3 vote →
 *    buyer share refunded, supplier share split between recipients → Done
 *
 * ─────────────────────────────────────────────────────────────────────────────────
 * 🔐 GUARANTEED BY CODE
 * ─────────────────────────────────────────────────────────────────────────────────
 * ⚡ All addresses and the split are set once at creation and can never change
 * ⚡ Funds move ONLY via dual-verify OR dispute resolution — never on expiry alone
 * ⚡ Expiry only closes the buyer's dispute window; it never releases funds
 * ⚡ Disputed funds MUST be split between buyer and the recipients only
 * ⚡ The platform fee is fixed, transparent, and paid once at deposit
 *
 * Same dispute mechanism (2-of-3 voting between buyer / seller / arbiter) as the base
 * escrow applies up until the dual-verify completes.
 * ═══════════════════════════════════════════════════════════════════════════════════
 */
contract CompletionEscrowContract is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Basis-point denominator for the recipient split (100% = 10000 bps)
    uint256 public constant BPS_DENOMINATOR = 10000;

    // Upper bound on the number of payout recipients (bounds the distribution loop's gas)
    uint256 public constant MAX_RECIPIENTS = 10;

    // Custom errors (saves gas compared to require strings)
    error AlreadyInitialized();
    error ImplementationCannotBeInitialized();
    error InvalidTokenAddress();
    error InvalidBuyerAddress();
    error InvalidSellerAddress();
    error InvalidGasPayerAddress();
    error BuyerSellerMustBeDifferent();
    error NoRecipients();
    error TooManyRecipients();
    error RecipientArrayLengthMismatch();
    error InvalidRecipientAddress();
    error InvalidRecipientBps();
    error RecipientBpsSumNot10000();
    error InvalidExpiryTimestamp();
    error CreatorFeeMustBeLessThanAmount();
    error NotInitialized();
    error OnlyBuyer();
    error OnlySeller();
    error OnlyVerifier();
    error VerifierCannotBeSeller();
    error OnlyBuyerOrGasPayer();
    error AlreadyFundedOrClaimed();
    error InsufficientBalanceToActivate();
    error CannotDisputeAfterExpiry();
    error NotFunded();
    error NotAwaitingVerification();
    error CannotDisputeNow();
    error ConsensusAlreadyReached();
    error InvalidPercentage();
    error NotAuthorizedToVote();
    error ContractMustBeDisputed();

    // 🔒 SECURITY: These addresses are SET ONCE and can NEVER be changed
    address public FACTORY;       // Factory contract that created this escrow
    IERC20 public tokenAddress;   // The ERC20 token contract (microUSDC, etc.)
    address public BUYER;         // Deposits funds and raises disputes
    address public SELLER;        // Supplier - marks work complete and votes in disputes
    address public VERIFIER;      // Verifies completion on the buyer's behalf (defaults to BUYER)
    address public GAS_PAYER;     // Platform/arbiter - can vote in disputes, NOT take money
    address public FEE_RECIPIENT; // Address that receives the platform fee

    // 💰 PAYOUT RECIPIENTS: escrowed funds are split between these by basis points.
    // recipients[i] receives recipientBps[i] / 10000 of the escrow; the bps sum to 10000.
    // 1..MAX_RECIPIENTS recipients are allowed; a single recipient just has bps [10000].
    address[] public recipients;
    uint256[] public recipientBps;

    // 💰 FINANCIAL TERMS: Set once at creation, cannot be modified
    uint256 public AMOUNT;           // Total amount BUYER must deposit (includes platform fee)
    uint256 public EXPIRY_TIMESTAMP; // When the BUYER's dispute window closes
    uint256 public CREATOR_FEE;      // Platform fee (deducted from AMOUNT at deposit)
    uint256 public createdAt;        // Timestamp when the contract was created

    // 🔐 INTERNAL STATE
    // 0=unfunded, 1=funded, 2=disputed, 3=completePendingVerify, 4=claimed, 255=disabled
    uint8 private _state;

    // ⚖️  VOTING STATE: 2-of-3 voting resolution system
    struct ResolutionVote {
        uint8 buyerPercentage; // 0-100 = valid vote, 255 = not voted yet
    }

    mapping(address => ResolutionVote) public resolutionVotes;
    bool public consensusReached;

    // 📢 PUBLIC EVENTS
    event FundsDeposited(address buyer, uint256 escrowAmount, uint256 timestamp);
    event PlatformFeeCollected(address recipient, uint256 feeAmount, uint256 timestamp);
    event MarkedComplete(address seller, uint256 timestamp);
    event CompletionVerified(address buyer, uint256 timestamp);
    event DisputeRaised(uint256 timestamp);
    event DisputeResolved(uint256 buyerPercentage, uint256 sellerPercentage, uint256 timestamp);
    event FundsClaimed(address recipient, uint256 amount, uint256 timestamp);
    event VoteSubmitted(address indexed voter, uint256 buyerPercentage);

    // 🛡️ MODIFIERS

    modifier onlyBuyer() {
        if (msg.sender != BUYER) revert OnlyBuyer();
        _;
    }

    modifier onlySeller() {
        if (msg.sender != SELLER) revert OnlySeller();
        _;
    }

    modifier onlyVerifier() {
        if (msg.sender != VERIFIER) revert OnlyVerifier();
        _;
    }

    modifier onlyBuyerOrGasPayer() {
        if (msg.sender != BUYER && msg.sender != GAS_PAYER) revert OnlyBuyerOrGasPayer();
        _;
    }

    modifier initialized() {
        if (_state == 255) revert NotInitialized();
        _;
    }

    constructor() {
        // Implementation contract - disable initialization
        _state = 255;
    }

    // Initialization parameters, passed as a single calldata struct so the many fields
    // (including the dynamic recipient arrays) live in calldata rather than on the stack.
    struct InitParams {
        address tokenAddress;
        address buyer;
        address seller;
        address gasPayer;
        uint256 amount;
        uint256 expiryTimestamp;
        uint256 creatorFee;
        address feeRecipient;
        address[] recipients;
        uint256[] recipientBps;
        address verifier;
    }

    function initialize(InitParams calldata p) external {
        if (_state != 0) revert AlreadyInitialized();
        if (FACTORY != address(0)) revert ImplementationCannotBeInitialized();
        FACTORY = msg.sender;
        if (p.tokenAddress == address(0)) revert InvalidTokenAddress();
        if (p.buyer == address(0)) revert InvalidBuyerAddress();
        if (p.seller == address(0)) revert InvalidSellerAddress();
        if (p.gasPayer == address(0)) revert InvalidGasPayerAddress();
        if (p.buyer == p.seller) revert BuyerSellerMustBeDifferent();
        // A nominated verifier acts for the buyer - it must never be the supplier,
        // or the supplier could approve its own work. Unset (0) defaults to the buyer.
        if (p.verifier == p.seller) revert VerifierCannotBeSeller();
        // Expiry must be a real future timestamp - this variant has no instant transfer
        if (p.expiryTimestamp <= block.timestamp) revert InvalidExpiryTimestamp();
        if (p.creatorFee >= p.amount) revert CreatorFeeMustBeLessThanAmount();

        _validateRecipients(p.recipients, p.recipientBps);

        tokenAddress = IERC20(p.tokenAddress);
        BUYER = p.buyer;
        SELLER = p.seller;
        // Default the verifier to the buyer when none is nominated at creation
        VERIFIER = p.verifier == address(0) ? p.buyer : p.verifier;
        GAS_PAYER = p.gasPayer;
        FEE_RECIPIENT = p.feeRecipient;
        recipients = p.recipients;
        recipientBps = p.recipientBps;
        AMOUNT = p.amount;
        EXPIRY_TIMESTAMP = p.expiryTimestamp;
        CREATOR_FEE = p.creatorFee;
        createdAt = block.timestamp;
        _state = 0; // unfunded

        // Initialize votes as "not voted" (255)
        resolutionVotes[p.buyer].buyerPercentage = 255;
        resolutionVotes[p.seller].buyerPercentage = 255;
        resolutionVotes[p.gasPayer].buyerPercentage = 255;
    }

    /**
     * Validates the recipient split: 1..MAX recipients, matching bps arrays, every
     * recipient non-zero with a positive share, and the shares summing to exactly 100%.
     */
    function _validateRecipients(
        address[] calldata _recipients,
        uint256[] calldata _recipientBps
    ) internal pure {
        uint256 n = _recipients.length;
        if (n == 0) revert NoRecipients();
        if (n > MAX_RECIPIENTS) revert TooManyRecipients();
        if (n != _recipientBps.length) revert RecipientArrayLengthMismatch();
        uint256 bpsSum;
        for (uint256 i = 0; i < n; i++) {
            if (_recipients[i] == address(0)) revert InvalidRecipientAddress();
            if (_recipientBps[i] == 0) revert InvalidRecipientBps();
            bpsSum += _recipientBps[i];
        }
        if (bpsSum != BPS_DENOMINATOR) revert RecipientBpsSumNot10000();
    }

    /**
     * 💰 BUYER DEPOSITS MONEY - THE ESCROW BEGINS
     *
     * BUYER's money is locked in this contract; the platform fee is paid out upfront;
     * the remainder stays locked until dual-verify or dispute resolution.
     */
    function depositFunds() external onlyBuyerOrGasPayer initialized nonReentrant {
        if (_state != 0) revert AlreadyFundedOrClaimed();

        uint256 escrowAmount;
        unchecked {
            // Safe: CREATOR_FEE < AMOUNT is checked in initialize
            escrowAmount = AMOUNT - CREATOR_FEE;
        }

        _state = 1; // funded - money is now LOCKED in escrow

        // 📝 STEP 1: Emit events before external calls to prevent event-based reentrancy
        emit FundsDeposited(BUYER, escrowAmount, block.timestamp);
        if (CREATOR_FEE > 0) {
            emit PlatformFeeCollected(FEE_RECIPIENT, CREATOR_FEE, block.timestamp);
        }

        // 🔒 STEP 2: BUYER's money is transferred to this contract (LOCKED AWAY)
        tokenAddress.safeTransferFrom(BUYER, address(this), AMOUNT);

        // 💳 STEP 3: Platform gets their fee (the ONLY money the platform receives)
        if (CREATOR_FEE > 0) {
            tokenAddress.safeTransfer(FEE_RECIPIENT, CREATOR_FEE);
        }
    }

    /**
     * 💰 SELF-FUND FROM EXISTING BALANCE - FOR TREE FAN-OUT
     *
     * When this escrow is itself a recipient of a parent node, the parent pays it by
     * transferring tokens directly to this address (no approval/transferFrom is
     * possible). This function activates the escrow using funds it already holds in
     * `tokenAddress` (the only currency it recognizes), instead of pulling from BUYER.
     *
     * It needs to hold at least AMOUNT. The platform fee is paid out of that balance,
     * exactly as in depositFunds(). Any balance beyond AMOUNT is left untouched, so
     * orchestrators should size each node's AMOUNT to match the payout it will receive.
     */
    function checkAndActivate() external onlyBuyerOrGasPayer initialized nonReentrant {
        if (_state != 0) revert AlreadyFundedOrClaimed();
        if (tokenAddress.balanceOf(address(this)) < AMOUNT) revert InsufficientBalanceToActivate();

        uint256 escrowAmount;
        unchecked {
            // Safe: CREATOR_FEE < AMOUNT is checked in initialize
            escrowAmount = AMOUNT - CREATOR_FEE;
        }

        _state = 1; // funded - the held balance is now LOCKED in escrow

        // 📝 STEP 1: Emit events before external calls to prevent event-based reentrancy
        emit FundsDeposited(BUYER, escrowAmount, block.timestamp);
        if (CREATOR_FEE > 0) {
            emit PlatformFeeCollected(FEE_RECIPIENT, CREATOR_FEE, block.timestamp);
        }

        // 💳 STEP 2: Platform gets their fee out of the funds already held here
        if (CREATOR_FEE > 0) {
            tokenAddress.safeTransfer(FEE_RECIPIENT, CREATOR_FEE);
        }
    }

    /**
     * ✅ SELLER MARKS THE WORK COMPLETE
     *
     * Moves the contract into "pending verification". The BUYER must still verify
     * before funds pay out. The BUYER may instead dispute (before expiry).
     */
    function markComplete() external onlySeller initialized {
        if (_state != 1) revert NotFunded();

        _state = 3; // completePendingVerify

        emit MarkedComplete(SELLER, block.timestamp);
    }

    /**
     * ✅ VERIFIER VERIFIES COMPLETION - FUNDS PAY OUT IN THIS CALL
     *
     * Once the SELLER has marked complete and the VERIFIER verifies, the full escrowed
     * amount is split between the recipients immediately. There is no separate claim.
     * The VERIFIER is the buyer's nominated delegate for this step, and defaults to the
     * BUYER when none was nominated at creation.
     */
    function verifyComplete() external onlyVerifier initialized nonReentrant {
        if (_state != 3) revert NotAwaitingVerification();

        _state = 4; // claimed

        uint256 escrowAmount;
        unchecked {
            // Safe: CREATOR_FEE < AMOUNT is checked in initialize
            escrowAmount = AMOUNT - CREATOR_FEE;
        }

        emit CompletionVerified(VERIFIER, block.timestamp);

        // Distribute the entire escrow to the recipients per the configured split
        _distributeToRecipients(escrowAmount);
    }

    /**
     * 🚨 BUYER PROTECTION - RAISE A DISPUTE
     *
     * The BUYER can dispute while the contract is funded (state 1) OR while it is
     * awaiting their verification (state 3), as long as it is before expiry. Disputing
     * freezes the funds until the 2-of-3 vote resolves.
     */
    function raiseDispute() external onlyBuyer initialized {
        if (_state != 1 && _state != 3) revert CannotDisputeNow();
        if (block.timestamp >= EXPIRY_TIMESTAMP) revert CannotDisputeAfterExpiry();

        _state = 2; // disputed - funds frozen until resolution

        emit DisputeRaised(block.timestamp);
    }

    /**
     * ⚖️  DISPUTE RESOLUTION - 2-OF-3 VOTING SYSTEM
     *
     * Buyer, seller (supplier), and arbiter each vote on the % refunded to the BUYER.
     * When any 2 votes agree, the resolution executes automatically. The supplier-side
     * share (everything not refunded to the BUYER) is split between the recipients by
     * the same configured basis-point split.
     */
    function submitResolutionVote(uint256 _buyerPercentage) external initialized {
        if (_state != 2) revert ContractMustBeDisputed();
        if (consensusReached) revert ConsensusAlreadyReached();
        if (_buyerPercentage > 100) revert InvalidPercentage();
        if (msg.sender != BUYER && msg.sender != SELLER && msg.sender != GAS_PAYER) revert NotAuthorizedToVote();

        resolutionVotes[msg.sender].buyerPercentage = uint8(_buyerPercentage);

        emit VoteSubmitted(msg.sender, _buyerPercentage);

        _checkAndExecuteConsensus();
    }

    function _checkAndExecuteConsensus() internal {
        uint8 buyerVote = resolutionVotes[BUYER].buyerPercentage;
        uint8 sellerVote = resolutionVotes[SELLER].buyerPercentage;
        uint8 adminVote = resolutionVotes[GAS_PAYER].buyerPercentage;

        bool buyerVoted = (buyerVote != 255);
        bool sellerVoted = (sellerVote != 255);
        bool adminVoted = (adminVote != 255);

        uint256 agreedPercentage;
        bool hasConsensus = false;

        if (buyerVoted && sellerVoted && buyerVote == sellerVote) {
            agreedPercentage = buyerVote;
            hasConsensus = true;
        } else if (buyerVoted && adminVoted && buyerVote == adminVote) {
            agreedPercentage = buyerVote;
            hasConsensus = true;
        } else if (sellerVoted && adminVoted && sellerVote == adminVote) {
            agreedPercentage = sellerVote;
            hasConsensus = true;
        }

        if (hasConsensus) {
            consensusReached = true;
            _executeResolution(agreedPercentage);
        }
    }

    function _executeResolution(uint256 _buyerPercentage) internal nonReentrant {
        _state = 4; // claimed (resolved)

        uint256 escrowAmount;
        uint256 buyerAmount;
        uint256 supplierAmount;

        unchecked {
            // Safe: CREATOR_FEE < AMOUNT is checked in initialize
            escrowAmount = AMOUNT - CREATOR_FEE;
            buyerAmount = (escrowAmount * _buyerPercentage) / 100;
            // Safe: buyerAmount <= escrowAmount by math (percentage <= 100)
            supplierAmount = escrowAmount - buyerAmount;
        }

        emit DisputeResolved(_buyerPercentage, 100 - _buyerPercentage, block.timestamp);

        // 🔒 BUYER's refund share (money can ONLY go to the BUYER address)
        if (buyerAmount > 0) {
            emit FundsClaimed(BUYER, buyerAmount, block.timestamp);
            tokenAddress.safeTransfer(BUYER, buyerAmount);
        }

        // 🔒 Supplier-side share is split between the recipients per the configured split
        _distributeToRecipients(supplierAmount);
    }

    /**
     * Splits `amount` between the recipients by their configured basis-point shares.
     * Each recipient but the last gets floor(amount * bps[i] / 10000); the last recipient
     * gets whatever remains, so any rounding dust always lands on it and nothing is stuck.
     * (For a single recipient it simply gets the whole amount.)
     */
    function _distributeToRecipients(uint256 amount) internal {
        uint256 n = recipients.length;
        uint256 distributed;
        for (uint256 i = 0; i < n; i++) {
            uint256 share;
            if (i + 1 == n) {
                // Last recipient absorbs the remainder (no dust left behind)
                unchecked {
                    // Safe: distributed <= amount, since each share <= its bps fraction
                    share = amount - distributed;
                }
            } else {
                share = (amount * recipientBps[i]) / BPS_DENOMINATOR;
                distributed += share;
            }
            if (share > 0) {
                emit FundsClaimed(recipients[i], share, block.timestamp);
                tokenAddress.safeTransfer(recipients[i], share);
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // VIEW HELPERS
    // ─────────────────────────────────────────────────────────────────────────────

    function getContractInfo() external view initialized returns (
        address _buyer,
        address _seller,
        uint256 _amount,
        uint256 _expiryTimestamp,
        uint8 _currentState,
        uint256 _currentTimestamp,
        uint256 _creatorFee,
        uint256 _createdAt,
        address _tokenAddress
    ) {
        return (
            BUYER,
            SELLER,
            AMOUNT,
            EXPIRY_TIMESTAMP,
            _state,
            block.timestamp,
            CREATOR_FEE,
            createdAt,
            address(tokenAddress)
        );
    }

    function getRecipients() external view initialized returns (
        address[] memory _recipients,
        uint256[] memory _recipientBps
    ) {
        return (recipients, recipientBps);
    }

    function isExpired() external view initialized returns (bool) {
        return block.timestamp >= EXPIRY_TIMESTAMP;
    }

    function isFunded() external view initialized returns (bool) {
        return _state >= 1;
    }

    function canDeposit() external view initialized returns (bool) {
        return _state == 0;
    }

    /// @notice This escrow's own balance of the escrow token (the only currency it recognizes).
    function tokenBalance() external view initialized returns (uint256) {
        return tokenAddress.balanceOf(address(this));
    }

    /// @notice True if the escrow is unfunded and already holds enough to self-activate.
    function canActivateFromBalance() external view initialized returns (bool) {
        return _state == 0 && tokenAddress.balanceOf(address(this)) >= AMOUNT;
    }

    function isDisputed() external view initialized returns (bool) {
        return _state == 2;
    }

    function isAwaitingVerification() external view initialized returns (bool) {
        return _state == 3;
    }

    function isClaimed() external view initialized returns (bool) {
        return _state == 4;
    }

    function canDispute() external view initialized returns (bool) {
        return (_state == 1 || _state == 3) && block.timestamp < EXPIRY_TIMESTAMP;
    }
}
