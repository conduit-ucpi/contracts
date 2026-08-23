// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * ═══════════════════════════════════════════════════════════════════════════════════
 *            🤝 COMPLETION ESCROW WITH DUAL-VERIFY + PAYEE SPLIT 🤝
 * ═══════════════════════════════════════════════════════════════════════════════════
 *
 * A variant of the practical escrow primitive with two additional abilities:
 *
 * 1. DUAL-VERIFY COMPLETION
 *    The LEAD_SUPPLIER marks the work complete; the VERIFIER (the buyer, or the
 *    buyer's nominated delegate) must then verify before funds pay out. Payout happens
 *    automatically inside the VERIFIER's call. This makes the contract a node in a tree
 *    of fan-out payments: each node is gated by BOTH supplier and buyer-side agreement.
 *
 * 2. UP TO MAX_PAYEES PAYEES
 *    Instead of paying a single supplier, the escrowed funds are split between 1..N
 *    payee addresses by a configured basis-point split (the shares sum to 10000).
 *    A payee may be a supplier's own wallet or a child escrow (subcontracting).
 *
 * ─────────────────────────────────────────────────────────────────────────────────
 * 🧭 ROLE VOCABULARY (buyer-side vs supplier-side)
 * ─────────────────────────────────────────────────────────────────────────────────
 * BUYER          Receives the service and pays for it. Funds the escrow, disputes.
 * LEAD_SUPPLIER  Provides/coordinates the service. Marks complete, votes in disputes.
 *                MAY take a 0% cut (a pure coordinator that passes everything on).
 * PAYEES         Where the money goes. Usually suppliers; may be child escrows.
 *                LEAD_SUPPLIER is a payee only when it takes a share of its own.
 * VERIFIER       Signs off on the buyer's behalf. Defaults to BUYER; never the
 *                LEAD_SUPPLIER. A distinct verifier keeps the escrow completable if
 *                the buyer goes silent.
 * ARBITER        Platform. Third vote in disputes. Can NEVER take money.
 *
 * ─────────────────────────────────────────────────────────────────────────────────
 * 💰 WHERE MONEY CAN GO (enforced by code)
 * ─────────────────────────────────────────────────────────────────────────────────
 * ✅ PAYEES (1..MAX_PAYEES): Receive the escrowed amount, split by basis
 *    points, on a successful dual-verify OR as the supplier-side share of a dispute.
 * ✅ BUYER: Receives a refund share on a dispute resolution.
 * ✅ PLATFORM_FEE_WALLET: Receives the small platform fee once, at deposit time.
 * ❌ NOBODY ELSE.
 *
 * ─────────────────────────────────────────────────────────────────────────────────
 * 🛡️ TRANSACTION FLOWS
 * ─────────────────────────────────────────────────────────────────────────────────
 * 📗 Happy Path:
 *    Buyer deposits → Lead supplier marks complete → Verifier verifies → payees paid
 *
 * 📕 Disputed Path:
 *    Buyer deposits → Buyer disputes → 2-of-3 vote →
 *    buyer share refunded, supplier share split between payees → Done
 *
 * ─────────────────────────────────────────────────────────────────────────────────
 * 🔐 GUARANTEED BY CODE
 * ─────────────────────────────────────────────────────────────────────────────────
 * ⚡ All addresses and the split are set once at creation and can never change
 * ⚡ Funds move ONLY via dual-verify OR dispute resolution
 * ⚡ Disputed funds MUST be split between buyer and the payees only
 * ⚡ The platform fee is fixed, transparent, and paid once at deposit
 *
 * ⏰ NO DEADLINE. There is deliberately no expiry timestamp. The buyer's right to
 *    dispute ends when the money moves, not on a date: the correct cut-off is the
 *    state transition (verification), which the buyer or their delegate controls.
 *    A calendar deadline could only ever remove the buyer's recovery path while
 *    leaving their ability to stall by not verifying untouched — stranding funds.
 *    Payout still requires an affirmative act, so nobody is paid by waiting.
 *
 * Same dispute mechanism (2-of-3 voting between buyer / lead supplier / arbiter) as the
 * base escrow applies up until the dual-verify completes.
 * ═══════════════════════════════════════════════════════════════════════════════════
 */
contract CompletionEscrowContract is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Basis-point denominator for the payee split (100% = 10000 bps)
    uint256 public constant BPS_DENOMINATOR = 10000;

    // Upper bound on the number of payout payees (bounds the distribution loop's gas)
    uint256 public constant MAX_PAYEES = 10;

    // Custom errors (saves gas compared to require strings)
    error AlreadyInitialized();
    error ImplementationCannotBeInitialized();
    error InvalidTokenAddress();
    error InvalidBuyerAddress();
    error InvalidLeadSupplierAddress();
    error InvalidArbiterAddress();
    error BuyerAndLeadSupplierMustDiffer();
    error ArbiterMustBeDistinct();
    error NoPayees();
    error TooManyPayees();
    error PayeeArrayLengthMismatch();
    error InvalidPayeeAddress();
    error InvalidPayeeBps();
    error PayeeBpsSumNot10000();
    error CreatorFeeMustBeLessThanAmount();
    error TransferAmountMismatch();
    error NotInitialized();
    error OnlyBuyer();
    error OnlyLeadSupplier();
    error OnlyVerifier();
    error VerifierCannotBeLeadSupplier();
    error OnlyBuyerOrArbiter();
    error AlreadyFundedOrClaimed();
    error InsufficientBalanceToActivate();
    error NotFunded();
    error NotAwaitingVerification();
    error CannotDisputeNow();
    error ConsensusAlreadyReached();
    error InvalidPercentage();
    error NotAuthorizedToVote();
    error ContractMustBeDisputed();
    error CannotSweepEscrowToken();
    error NoTokensToSweep();

    // 🔒 SECURITY: These addresses are SET ONCE and can NEVER be changed
    address public FACTORY;       // Factory contract that created this escrow
    IERC20 public tokenAddress;   // The ERC20 token contract (microUSDC, etc.)
    address public BUYER;         // Deposits funds and raises disputes
    address public LEAD_SUPPLIER;        // Supplier - marks work complete and votes in disputes
    address public VERIFIER;      // Verifies completion on the buyer's behalf (defaults to BUYER)
    address public ARBITER;     // Platform/arbiter - can vote in disputes, NOT take money
    address public PLATFORM_FEE_WALLET; // Address that receives the platform fee

    // 💰 PAYOUT RECIPIENTS: escrowed funds are split between these by basis points.
    // payees[i] receives payeeBps[i] / 10000 of the escrow; the bps sum to 10000.
    // 1..MAX_PAYEES payees are allowed; a single payee just has bps [10000].
    address[] public payees;
    uint256[] public payeeBps;

    // 💰 FINANCIAL TERMS: Set once at creation, cannot be modified
    uint256 public AMOUNT;           // Total amount BUYER must deposit (includes platform fee)
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
    event PlatformFeeCollected(address feeWallet, uint256 feeAmount, uint256 timestamp);
    event MarkedComplete(address leadSupplier, uint256 timestamp);
    event CompletionVerified(address buyer, uint256 timestamp);
    event DisputeRaised(uint256 timestamp);
    // supplierPercentage is the whole supplier-side share, split across ALL payees
    event DisputeResolved(uint256 buyerPercentage, uint256 supplierPercentage, uint256 timestamp);
    event FundsClaimed(address payee, uint256 amount, uint256 timestamp);
    event VoteSubmitted(address indexed voter, uint256 buyerPercentage);
    event TokensSwept(address indexed token, address indexed recipient, uint256 amount);

    // 🛡️ MODIFIERS

    modifier onlyBuyer() {
        if (msg.sender != BUYER) revert OnlyBuyer();
        _;
    }

    modifier onlyLeadSupplier() {
        if (msg.sender != LEAD_SUPPLIER) revert OnlyLeadSupplier();
        _;
    }

    modifier onlyVerifier() {
        if (msg.sender != VERIFIER) revert OnlyVerifier();
        _;
    }

    modifier onlyBuyerOrArbiter() {
        if (msg.sender != BUYER && msg.sender != ARBITER) revert OnlyBuyerOrArbiter();
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
    // (including the dynamic payee arrays) live in calldata rather than on the stack.
    struct InitParams {
        address tokenAddress;
        address buyer;
        address leadSupplier;
        address arbiter;
        uint256 amount;
        uint256 creatorFee;
        address platformFeeWallet;
        address[] payees;
        uint256[] payeeBps;
        address verifier;
    }

    function initialize(InitParams calldata p) external {
        if (_state != 0) revert AlreadyInitialized();
        if (FACTORY != address(0)) revert ImplementationCannotBeInitialized();
        FACTORY = msg.sender;
        if (p.tokenAddress == address(0)) revert InvalidTokenAddress();
        if (p.buyer == address(0)) revert InvalidBuyerAddress();
        if (p.leadSupplier == address(0)) revert InvalidLeadSupplierAddress();
        if (p.arbiter == address(0)) revert InvalidArbiterAddress();
        if (p.buyer == p.leadSupplier) revert BuyerAndLeadSupplierMustDiffer();
        /*
         * ⚠️ THE ARBITER MUST BE A THIRD PARTY, AND HERE THAT IS SHARPER THAN IT SOUNDS.
         *    Sharing the arbiter address with a party does not merely give them two roles —
         *    `_checkAndExecuteConsensus` reads both votes from the SAME storage slot, so a
         *    single `submitResolutionVote` satisfies the buyer-and-arbiter (or
         *    supplier-and-arbiter) branch outright and executes any split they name, in
         *    that one transaction, with no second party involved.
         *
         *    The sibling escrow has carried this check since creation (EscrowContract's
         *    `ArbiterMustBeDistinct`); its absence here was an omission, not a difference
         *    of design. In practice the factory always passes its OWNER as arbiter, so the
         *    reachable case is the platform being a party to its own project — but the
         *    guard belongs on the contract, which is the only thing a directly-initialized
         *    clone must still answer to.
         */
        if (p.arbiter == p.buyer || p.arbiter == p.leadSupplier) revert ArbiterMustBeDistinct();
        // A nominated verifier acts for the buyer - it must never be the supplier,
        // or the supplier could approve its own work. Unset (0) defaults to the buyer.
        if (p.verifier == p.leadSupplier) revert VerifierCannotBeLeadSupplier();
        if (p.creatorFee >= p.amount) revert CreatorFeeMustBeLessThanAmount();

        _validatePayees(p.payees, p.payeeBps);

        tokenAddress = IERC20(p.tokenAddress);
        BUYER = p.buyer;
        LEAD_SUPPLIER = p.leadSupplier;
        // Default the verifier to the buyer when none is nominated at creation
        VERIFIER = p.verifier == address(0) ? p.buyer : p.verifier;
        ARBITER = p.arbiter;
        PLATFORM_FEE_WALLET = p.platformFeeWallet;
        payees = p.payees;
        payeeBps = p.payeeBps;
        AMOUNT = p.amount;
        CREATOR_FEE = p.creatorFee;
        createdAt = block.timestamp;
        _state = 0; // unfunded

        // Initialize votes as "not voted" (255)
        resolutionVotes[p.buyer].buyerPercentage = 255;
        resolutionVotes[p.leadSupplier].buyerPercentage = 255;
        resolutionVotes[p.arbiter].buyerPercentage = 255;
    }

    /**
     * Validates the payee split: 1..MAX payees, matching bps arrays, every
     * payee non-zero with a positive share, and the shares summing to exactly 100%.
     */
    function _validatePayees(
        address[] calldata _payees,
        uint256[] calldata _payeeBps
    ) internal pure {
        uint256 n = _payees.length;
        if (n == 0) revert NoPayees();
        if (n > MAX_PAYEES) revert TooManyPayees();
        if (n != _payeeBps.length) revert PayeeArrayLengthMismatch();
        uint256 bpsSum;
        for (uint256 i = 0; i < n; i++) {
            if (_payees[i] == address(0)) revert InvalidPayeeAddress();
            if (_payeeBps[i] == 0) revert InvalidPayeeBps();
            bpsSum += _payeeBps[i];
        }
        if (bpsSum != BPS_DENOMINATOR) revert PayeeBpsSumNot10000();
    }

    /**
     * 💰 BUYER DEPOSITS MONEY - THE ESCROW BEGINS
     *
     * BUYER's money is locked in this contract; the platform fee is paid out upfront;
     * the remainder stays locked until dual-verify or dispute resolution.
     */
    function depositFunds() external onlyBuyerOrArbiter initialized nonReentrant {
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
            emit PlatformFeeCollected(PLATFORM_FEE_WALLET, CREATOR_FEE, block.timestamp);
        }

        // 🔒 STEP 2: BUYER's money is transferred to this contract (LOCKED AWAY)
        /*
         * ⚠️ REJECT FEE-ON-TRANSFER / DEFLATIONARY / REBASING TOKENS, as the base escrow
         *    does. Every payout below is a FIXED figure derived from AMOUNT, so a short
         *    transfer does not shrink the payouts — it makes the LAST payee's transfer
         *    revert, permanently, with the whole escrow stuck behind it. And the sweep
         *    cannot rescue that: it opens the escrow token only in the terminal state,
         *    which a reverting distribution can never reach. Fail the deposit instead.
         */
        uint256 balanceBefore = tokenAddress.balanceOf(address(this));
        tokenAddress.safeTransferFrom(BUYER, address(this), AMOUNT);
        if (tokenAddress.balanceOf(address(this)) - balanceBefore != AMOUNT) revert TransferAmountMismatch();

        // 💳 STEP 3: Platform gets their fee (the ONLY money the platform receives)
        if (CREATOR_FEE > 0) {
            tokenAddress.safeTransfer(PLATFORM_FEE_WALLET, CREATOR_FEE);
        }
    }

    /**
     * 💰 SELF-FUND FROM EXISTING BALANCE - FOR TREE FAN-OUT
     *
     * When this escrow is itself a payee of a parent node, the parent pays it by
     * transferring tokens directly to this address (no approval/transferFrom is
     * possible). This function activates the escrow using funds it already holds in
     * `tokenAddress` (the only currency it recognizes), instead of pulling from BUYER.
     *
     * It needs to hold at least AMOUNT. The platform fee is paid out of that balance,
     * exactly as in depositFunds(). Any balance beyond AMOUNT is left untouched, so
     * orchestrators should size each node's AMOUNT to match the payout it will receive.
     */
    function checkAndActivate() external onlyBuyerOrArbiter initialized nonReentrant {
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
            emit PlatformFeeCollected(PLATFORM_FEE_WALLET, CREATOR_FEE, block.timestamp);
        }

        // 💳 STEP 2: Platform gets their fee out of the funds already held here
        if (CREATOR_FEE > 0) {
            tokenAddress.safeTransfer(PLATFORM_FEE_WALLET, CREATOR_FEE);
        }
    }

    /**
     * ✅ LEAD_SUPPLIER MARKS THE WORK COMPLETE
     *
     * Moves the contract into "pending verification". The BUYER must still verify
     * before funds pay out. The BUYER may instead dispute, at any point before payout.
     */
    function markComplete() external onlyLeadSupplier initialized {
        if (_state != 1) revert NotFunded();

        _state = 3; // completePendingVerify

        emit MarkedComplete(LEAD_SUPPLIER, block.timestamp);
    }

    /**
     * ✅ VERIFIER VERIFIES COMPLETION - FUNDS PAY OUT IN THIS CALL
     *
     * Once the LEAD_SUPPLIER has marked complete and the VERIFIER verifies, the full escrowed
     * amount is split between the payees immediately. There is no separate claim.
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

        // Distribute the entire escrow to the payees per the configured split
        _distributeToPayees(escrowAmount);
    }

    /**
     * 🚨 BUYER PROTECTION - RAISE A DISPUTE
     *
     * The BUYER can dispute while the contract is funded (state 1) OR while it is
     * awaiting verification (state 3). Disputing freezes the funds until the 2-of-3
     * vote resolves.
     *
     * There is no deadline. The right to dispute ends when the money moves - i.e. when
     * the VERIFIER signs off (state 4), which is the buyer's own act or that of their
     * nominated delegate. This guarantees the buyer always has a path to recover funds,
     * so an escrow can never be stranded by a missed date.
     *
     * ⚠️ THE ARBITER MAY ALSO RAISE ONE, AND THAT IS THE SUPPLIER'S ONLY WAY OUT. Payout
     *    needs the VERIFIER (the buyer, or their delegate) to act, and voting needs a
     *    dispute to exist. While this was buyer-only, those two facts composed into a
     *    permanent freeze: a buyer who simply stopped responding left the supplier with no
     *    lever at all — unable to verify, unable to dispute, and unable to reach the
     *    arbiter, because the arbiter could not vote on a dispute nobody was allowed to
     *    open. Not a missed-deadline problem, a missing-trigger one, which is why no clock
     *    would have fixed it (see the header's note on deadlines).
     *
     *    Opening it to the arbiter changes nothing about who gets paid: raising a dispute
     *    moves no money, and settlement still needs two of the three to agree. It only
     *    ensures the question can always be ASKED. The supplier is deliberately not given
     *    the trigger directly — routing it through the arbiter keeps a neutral party
     *    between a supplier and the buyer's funds.
     */
    function raiseDispute() external onlyBuyerOrArbiter initialized {
        if (_state != 1 && _state != 3) revert CannotDisputeNow();

        _state = 2; // disputed - funds frozen until resolution

        emit DisputeRaised(block.timestamp);
    }

    /**
     * ⚖️  DISPUTE RESOLUTION - 2-OF-3 VOTING SYSTEM
     *
     * Buyer, leadSupplier (supplier), and arbiter each vote on the % refunded to the BUYER.
     * When any 2 votes agree, the resolution executes automatically. The supplier-side
     * share (everything not refunded to the BUYER) is split between the payees by
     * the same configured basis-point split.
     */
    function submitResolutionVote(uint256 _buyerPercentage) external initialized {
        if (_state != 2) revert ContractMustBeDisputed();
        if (consensusReached) revert ConsensusAlreadyReached();
        if (_buyerPercentage > 100) revert InvalidPercentage();
        if (msg.sender != BUYER && msg.sender != LEAD_SUPPLIER && msg.sender != ARBITER) revert NotAuthorizedToVote();

        // casting to uint8 is safe: _buyerPercentage is bounded to <= 100 above
        // forge-lint: disable-next-line(unsafe-typecast)
        resolutionVotes[msg.sender].buyerPercentage = uint8(_buyerPercentage);

        emit VoteSubmitted(msg.sender, _buyerPercentage);

        _checkAndExecuteConsensus();
    }

    function _checkAndExecuteConsensus() internal {
        uint8 buyerVote = resolutionVotes[BUYER].buyerPercentage;
        uint8 leadSupplierVote = resolutionVotes[LEAD_SUPPLIER].buyerPercentage;
        uint8 adminVote = resolutionVotes[ARBITER].buyerPercentage;

        bool buyerVoted = (buyerVote != 255);
        bool leadSupplierVoted = (leadSupplierVote != 255);
        bool adminVoted = (adminVote != 255);

        uint256 agreedPercentage;
        bool hasConsensus = false;

        if (buyerVoted && leadSupplierVoted && buyerVote == leadSupplierVote) {
            agreedPercentage = buyerVote;
            hasConsensus = true;
        } else if (buyerVoted && adminVoted && buyerVote == adminVote) {
            agreedPercentage = buyerVote;
            hasConsensus = true;
        } else if (leadSupplierVoted && adminVoted && leadSupplierVote == adminVote) {
            agreedPercentage = leadSupplierVote;
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

        // 🔒 Supplier-side share is split between the payees per the configured split
        _distributeToPayees(supplierAmount);
    }

    /**
     * Splits `amount` between the payees by their configured basis-point shares.
     * Each payee but the last gets floor(amount * bps[i] / 10000); the last payee
     * gets whatever remains, so any rounding dust always lands on it and nothing is stuck.
     * (For a single payee it simply gets the whole amount.)
     */
    function _distributeToPayees(uint256 amount) internal {
        uint256 n = payees.length;
        uint256 distributed;
        for (uint256 i = 0; i < n; i++) {
            uint256 share;
            if (i + 1 == n) {
                // Last payee absorbs the remainder (no dust left behind)
                unchecked {
                    // Safe: distributed <= amount, since each share <= its bps fraction
                    share = amount - distributed;
                }
            } else {
                share = (amount * payeeBps[i]) / BPS_DENOMINATOR;
                distributed += share;
            }
            if (share > 0) {
                emit FundsClaimed(payees[i], share, block.timestamp);
                tokenAddress.safeTransfer(payees[i], share);
            }
        }
    }

    /**
     * 🧹 RECOVER TOKENS THAT NOBODY IS OWED
     *
     * ⚠️ THIS CONTRACT PREVIOUSLY HAD NO RECOVERY PATH OF ANY KIND, so anything that
     *    arrived here by mistake was lost outright: a wrong token, or — because
     *    `checkAndActivate` funds from the balance and pays out a fixed
     *    `AMOUNT − CREATOR_FEE` — any overpayment on the right one. The fan-out flow makes
     *    the second case realistic, since a parent node pays its children by direct
     *    transfer and a mis-sized child simply strands the difference.
     *
     * 🔒 TWO RULES, AND THE SECOND IS WHAT KEEPS IT SAFE:
     *    • A foreign token is always recoverable — this contract's obligations are
     *      denominated solely in `tokenAddress`, so it can never owe anyone a balance in
     *      anything else.
     *    • The ESCROW token is recoverable ONLY once the contract is terminal
     *      (`_state == 4`). Before then the balance is the escrow itself; after it, every
     *      obligation has been discharged by `verifyComplete` or `_executeResolution`, so
     *      whatever remains is surplus by definition.
     *
     * ✅ Callable by anyone, and the destination is fixed to the BUYER — the depositor,
     *    and the only party who can have overpaid. The caller chooses nothing, so this is
     *    permissionless for the same reason the exits elsewhere are.
     */
    function sweepToken(address _token) external initialized nonReentrant {
        if (_token == address(tokenAddress) && _state != 4) revert CannotSweepEscrowToken();

        uint256 balance = IERC20(_token).balanceOf(address(this));
        if (balance == 0) revert NoTokensToSweep();

        emit TokensSwept(_token, BUYER, balance);

        IERC20(_token).safeTransfer(BUYER, balance);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // VIEW HELPERS
    // ─────────────────────────────────────────────────────────────────────────────

    function getContractInfo() external view initialized returns (
        address _buyer,
        address _leadSupplier,
        uint256 _amount,
        uint8 _currentState,
        uint256 _currentTimestamp,
        uint256 _creatorFee,
        uint256 _createdAt,
        address _tokenAddress
    ) {
        return (
            BUYER,
            LEAD_SUPPLIER,
            AMOUNT,
            _state,
            block.timestamp,
            CREATOR_FEE,
            createdAt,
            address(tokenAddress)
        );
    }

    function getPayees() external view initialized returns (
        address[] memory _payees,
        uint256[] memory _payeeBps
    ) {
        return (payees, payeeBps);
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

    /// @notice True while a dispute can still be raised (by the buyer or the arbiter) —
    ///         i.e. any time before payout.
    function canDispute() external view initialized returns (bool) {
        return _state == 1 || _state == 3;
    }
}
