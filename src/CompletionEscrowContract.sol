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
 * 2. UP TO TWO PAYOUT RECIPIENTS
 *    Instead of paying a single SELLER, the escrowed funds are split between up to two
 *    recipient addresses by a configured basis-point split. The SELLER is the supplier
 *    (who marks complete and votes in disputes) and is NOT necessarily a recipient.
 *
 * ─────────────────────────────────────────────────────────────────────────────────
 * 💰 WHERE MONEY CAN GO (enforced by code)
 * ─────────────────────────────────────────────────────────────────────────────────
 * ✅ RECIPIENT1 / RECIPIENT2: Receive the escrowed amount, split by basis points,
 *    on a successful dual-verify OR as the supplier-side share of a dispute.
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

    // Custom errors (saves gas compared to require strings)
    error AlreadyInitialized();
    error ImplementationCannotBeInitialized();
    error InvalidTokenAddress();
    error InvalidBuyerAddress();
    error InvalidSellerAddress();
    error InvalidGasPayerAddress();
    error BuyerSellerMustBeDifferent();
    error InvalidRecipientAddress();
    error RecipientsMustBeDifferent();
    error InvalidRecipientSplit();
    error InvalidExpiryTimestamp();
    error CreatorFeeMustBeLessThanAmount();
    error NotInitialized();
    error OnlyBuyer();
    error OnlySeller();
    error OnlyBuyerOrGasPayer();
    error AlreadyFundedOrClaimed();
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
    address public BUYER;         // Deposits funds, disputes, and verifies completion
    address public SELLER;        // Supplier - marks work complete and votes in disputes
    address public GAS_PAYER;     // Platform/arbiter - can vote in disputes, NOT take money
    address public FEE_RECIPIENT; // Address that receives the platform fee

    // 💰 PAYOUT RECIPIENTS: escrowed funds are split between these by basis points
    address public RECIPIENT1;    // Primary payout recipient (receives RECIPIENT1_BPS share)
    address public RECIPIENT2;    // Secondary payout recipient (receives remainder); 0 = single recipient
    uint256 public RECIPIENT1_BPS; // Share of escrow to RECIPIENT1, in basis points (0-10000)

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

    function initialize(
        address _tokenAddress,
        address _buyer,
        address _seller,
        address _gasPayer,
        uint256 _amount,
        uint256 _expiryTimestamp,
        uint256 _creatorFee,
        address _feeRecipient,
        address _recipient1,
        address _recipient2,
        uint256 _recipient1Bps
    ) external {
        if (_state != 0) revert AlreadyInitialized();
        if (FACTORY != address(0)) revert ImplementationCannotBeInitialized();
        FACTORY = msg.sender;
        if (_tokenAddress == address(0)) revert InvalidTokenAddress();
        if (_buyer == address(0)) revert InvalidBuyerAddress();
        if (_seller == address(0)) revert InvalidSellerAddress();
        if (_gasPayer == address(0)) revert InvalidGasPayerAddress();
        if (_buyer == _seller) revert BuyerSellerMustBeDifferent();
        // Expiry must be a real future timestamp - this variant has no instant transfer
        if (_expiryTimestamp <= block.timestamp) revert InvalidExpiryTimestamp();
        if (_creatorFee >= _amount) revert CreatorFeeMustBeLessThanAmount();

        // Validate recipient split
        if (_recipient1 == address(0)) revert InvalidRecipientAddress();
        if (_recipient2 == address(0)) {
            // Single recipient: must take the entire escrow
            if (_recipient1Bps != BPS_DENOMINATOR) revert InvalidRecipientSplit();
        } else {
            // Two recipients: distinct addresses and a strict split in (0, 10000)
            if (_recipient1 == _recipient2) revert RecipientsMustBeDifferent();
            if (_recipient1Bps == 0 || _recipient1Bps >= BPS_DENOMINATOR) revert InvalidRecipientSplit();
        }

        tokenAddress = IERC20(_tokenAddress);
        BUYER = _buyer;
        SELLER = _seller;
        GAS_PAYER = _gasPayer;
        FEE_RECIPIENT = _feeRecipient;
        RECIPIENT1 = _recipient1;
        RECIPIENT2 = _recipient2;
        RECIPIENT1_BPS = _recipient1Bps;
        AMOUNT = _amount;
        EXPIRY_TIMESTAMP = _expiryTimestamp;
        CREATOR_FEE = _creatorFee;
        createdAt = block.timestamp;
        _state = 0; // unfunded

        // Initialize votes as "not voted" (255)
        resolutionVotes[_buyer].buyerPercentage = 255;
        resolutionVotes[_seller].buyerPercentage = 255;
        resolutionVotes[_gasPayer].buyerPercentage = 255;
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
     * ✅ BUYER VERIFIES COMPLETION - FUNDS PAY OUT IN THIS CALL
     *
     * Once the SELLER has marked complete and the BUYER verifies, the full escrowed
     * amount is split between the recipients immediately. There is no separate claim.
     */
    function verifyComplete() external onlyBuyer initialized nonReentrant {
        if (_state != 3) revert NotAwaitingVerification();

        _state = 4; // claimed

        uint256 escrowAmount;
        unchecked {
            // Safe: CREATOR_FEE < AMOUNT is checked in initialize
            escrowAmount = AMOUNT - CREATOR_FEE;
        }

        emit CompletionVerified(BUYER, block.timestamp);

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
     * Splits `amount` between the recipients by the configured basis-point split.
     * For a single recipient (RECIPIENT2 == 0) the whole amount goes to RECIPIENT1.
     * For two recipients, RECIPIENT1 gets floor(amount * bps / 10000) and RECIPIENT2
     * gets the remainder, so any rounding dust always lands on RECIPIENT2 (never stuck).
     */
    function _distributeToRecipients(uint256 amount) internal {
        if (RECIPIENT2 == address(0)) {
            if (amount > 0) {
                emit FundsClaimed(RECIPIENT1, amount, block.timestamp);
                tokenAddress.safeTransfer(RECIPIENT1, amount);
            }
            return;
        }

        uint256 amount1 = (amount * RECIPIENT1_BPS) / BPS_DENOMINATOR;
        uint256 amount2;
        unchecked {
            // Safe: amount1 <= amount by math (RECIPIENT1_BPS <= BPS_DENOMINATOR)
            amount2 = amount - amount1;
        }

        if (amount1 > 0) {
            emit FundsClaimed(RECIPIENT1, amount1, block.timestamp);
            tokenAddress.safeTransfer(RECIPIENT1, amount1);
        }
        if (amount2 > 0) {
            emit FundsClaimed(RECIPIENT2, amount2, block.timestamp);
            tokenAddress.safeTransfer(RECIPIENT2, amount2);
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
        address _recipient1,
        address _recipient2,
        uint256 _recipient1Bps
    ) {
        return (RECIPIENT1, RECIPIENT2, RECIPIENT1_BPS);
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
