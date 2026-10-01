// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {EscrowContract} from "./EscrowContract.sol";

/**
 * ═══════════════════════════════════════════════════════════════════════════════════
 *                      🔒 ESCROW FACTORY - SECURITY OVERVIEW 🔒
 * ═══════════════════════════════════════════════════════════════════════════════════
 *
 * This factory creates individual escrow contracts. Each escrow contract it creates
 * has the same security guarantees outlined in EscrowContract.sol.
 *
 * 🔐 FACTORY SECURITY PROMISES:
 * ✅ Only creates legitimate escrow contracts (no malicious code)
 * ✅ Each contract locks money between BUYER and SELLER only
 * ✅ Platform cannot modify contracts after creation
 * ✅ All created contracts follow the same security rules
 *
 * 🛡️ WHAT THIS FACTORY CANNOT DO:
 * ❌ Cannot modify existing escrow contracts
 * ❌ Cannot access money in escrow contracts
 * ❌ Cannot change the BUYER address after creation (the SELLER may reassign only its
 *    own payout address, and only the seller itself can do so - not the factory)
 * ❌ Cannot bypass security mechanisms in individual contracts
 *
 * The factory simply creates secure escrow contracts - it has no power over them afterward.
 *
 * 🤝 PARTNER FEE SPLITS:
 * An escrow may route a share of the platform fee to a revenue-share partner. The share
 * comes OUT OF the fee - the buyer pays and the seller nets exactly what they would
 * without it. Creation is permissionless, so the split cannot simply be a parameter:
 * anyone could name themselves partner on an escrow from THIS factory and skim the
 * platform's fee. Every split therefore needs a signature from FEE_SPLIT_SIGNER over the
 * complete terms (see _validateSplit).
 * ═══════════════════════════════════════════════════════════════════════════════════
 */
contract EscrowContractFactory is EIP712 {
    // Custom errors (saves gas compared to require strings)
    error InvalidOwnerAddress();
    error InvalidImplementationAddress();
    error OnlyOwner();
    error InvalidTokenAddress();
    error InvalidBuyerAddress();
    error InvalidSellerAddress();
    error BuyerSellerMustBeDifferent();
    error ArbiterMustBeDistinct();
    error InvalidArbiterAddress();
    error AmountMustBeGreaterThanZero();
    error InvalidExpiryTimestamp();
    error AmountTooSmallForMinFee();
    error CreatorFeeMustBeLessThanAmount();
    error InvalidPartnerAddress();
    error InvalidPartnerBps();
    error InvalidFeeSplitSignature();

    // 🔒 IMMUTABLE FACTORY SETTINGS: These CANNOT be changed after deployment
    address public immutable OWNER; // Platform address - can create contracts but NOT access money
    address public immutable IMPLEMENTATION; // Template contract - ensures all escrows have same security
    address public immutable FEE_RECIPIENT; // Address that receives platform fees (defaults to OWNER if not set)
    address public immutable FEE_SPLIT_SIGNER; // Sole authority for partner fee splits (defaults to OWNER if not set)
    bytes20 public immutable GIT_COMMIT; // Commit this factory was built from, stamped at deploy

    /// @notice Partner shares are in basis points OF THE FEE, not of the amount:
    ///         5_000 = half the platform fee. 10_000 hands the partner the whole fee.
    uint16 public constant MAX_PARTNER_BPS = 10_000;

    /// @notice The EIP-712 struct FEE_SPLIT_SIGNER signs. It covers EVERY term, not just
    ///         the split, so a signature cannot be lifted onto a different escrow.
    bytes32 public constant FEE_SPLIT_TYPEHASH = keccak256(
        "FeeSplitTerms(address tokenAddress,address buyer,address seller,uint256 amount,uint256 expiryTimestamp,address arbiter,bytes32 externalId,address partner,uint16 partnerBps)"
    );

    /// @notice A partner's share of the platform fee. partnerBps == 0 means no split.
    struct FeeSplit {
        address partner;
        uint16 partnerBps;
    }

    // 📢 PUBLIC EVENT: Records every escrow contract creation (permanent blockchain record)
    // Description stored here instead of contract storage to save ~20k gas per deployment
    event ContractCreated(
        address indexed contractAddress,
        address indexed buyer,
        address indexed seller,
        uint256 amount,
        uint256 expiryTimestamp,
        string description
    );

    event FeeSplitApplied(
        address indexed contractAddress, address indexed partner, uint16 partnerBps, uint256 partnerFee
    );

    /**
     * @param _feeSplitSigner Signs partner fee splits. Zero defaults to OWNER, but OWNER is
     *        the relayer's hot key - a dedicated key (or an ERC-1271 multisig) keeps a relayer
     *        compromise from also being a fee-diversion compromise. It is immutable: every
     *        signature it has ever issued stays valid, so rotating it means a new factory.
     * @param _gitCommit The commit the deployed bytecode was built from.
     */
    constructor(
        address _owner,
        address _implementation,
        address _feeRecipient,
        address _feeSplitSigner,
        bytes20 _gitCommit
    ) EIP712("EscrowContractFactory", "1") {
        if (_owner == address(0)) revert InvalidOwnerAddress();
        if (_implementation == address(0)) revert InvalidImplementationAddress();

        OWNER = _owner;
        IMPLEMENTATION = _implementation;
        // Default to OWNER if feeRecipient not specified
        FEE_RECIPIENT = _feeRecipient == address(0) ? _owner : _feeRecipient;
        FEE_SPLIT_SIGNER = _feeSplitSigner == address(0) ? _owner : _feeSplitSigner;
        GIT_COMMIT = _gitCommit;
    }

    /**
     * 🏭 CREATE NEW ESCROW CONTRACT
     *
     * 🔒 SECURITY GUARANTEE: This creates a secure escrow contract with the same protections
     *                        outlined in EscrowContract.sol
     *
     * What this function does:
     * ✅ Creates a new escrow contract between BUYER and SELLER
     * ✅ Locks in the BUYER address (immutable); the SELLER may later reassign only its
     *    own payout address via changeRecipient (seller-controlled)
     * ✅ Sets up all security mechanisms to protect both parties
     * ✅ Ensures only BUYER and SELLER can receive the escrowed money
     *
     * 🛡️ SECURITY VERIFICATION:
     * - Each contract is created from the same secure template
     * - Factory cannot modify contracts after creation
     * - All contracts have identical security guarantees
     * - Platform can only facilitate - never access escrowed funds
     */
    /**
     * ⚠️ THE SIGNATURE CHANGED HERE, unlike every previous factory revision.
     *
     * `arbiter` is no longer optional and `externalId` is new, because the escrow address is
     * now a pure function of these arguments (see _salt). A caller that passed address(0) for
     * the arbiter and let the factory substitute msg.sender would get an address nobody but
     * the relayer could have predicted, which defeats the purpose.
     *
     * The arbiter nomination window used after a marketplace sale is still the escrow's
     * NOMINATION_WINDOW constant (72 hours), not a per-escrow parameter — see
     * EscrowContract.NOMINATION_WINDOW for why.
     */
    function createEscrowContract(
        address tokenAddress,
        address buyer,
        address seller,
        uint256 amount,
        uint256 expiryTimestamp,
        string memory description,
        address arbiter,
        bytes32 externalId
    ) external returns (address) {
        return _create(
            Terms(tokenAddress, buyer, seller, amount, expiryTimestamp, arbiter, externalId, address(0), 0),
            description,
            true,
            ""
        );
    }

    /**
     * 🏭 CREATE AN ESCROW WHOSE FEE IS SHARED WITH A PARTNER
     *
     * As createEscrowContract, plus a split of the platform fee authorised by
     * FEE_SPLIT_SIGNER. `signature` is the signer's EIP-712 signature over FeeSplitTerms:
     * every argument here except `description`. Anyone may submit it; nobody but the signer
     * can produce it.
     */
    function createEscrowContractWithSplit(
        address tokenAddress,
        address buyer,
        address seller,
        uint256 amount,
        uint256 expiryTimestamp,
        string memory description,
        address arbiter,
        bytes32 externalId,
        FeeSplit calldata split,
        bytes calldata signature
    ) external returns (address) {
        return _create(
            Terms(
                tokenAddress,
                buyer,
                seller,
                amount,
                expiryTimestamp,
                arbiter,
                externalId,
                split.partner,
                split.partnerBps
            ),
            description,
            true,
            signature
        );
    }

    /**
     * 🏭 CREATE AND ACTIVATE — for an address that was funded BEFORE it was deployed.
     *
     * Because the address is counterfactual, a payer can send tokens to it while it is still
     * empty space. Nothing happens when they do: an ERC20 transfer is a ledger update inside
     * the TOKEN contract, so no code runs here and no event of ours fires. Somebody must then
     * send this transaction to bring the escrow into existence on top of those funds.
     *
     * Deploy and activation are one transaction on purpose. checkAndActivate() reverts unless
     * the balance is already there, so this is all-or-nothing: either the escrow exists AND is
     * funded, or the chain state is untouched. There is no window in which a deployed escrow
     * sits unfunded because the second half failed.
     *
     * Permissionless, like checkAndActivate() itself — the parameters are fixed by the salt,
     * so a caller cannot influence where the money goes. Whoever calls it only pays the gas.
     *
     * ⚠️ A PAST EXPIRY IS ACCEPTED HERE, and rejected by createEscrowContract.
     *
     * The terms were fixed when the address was quoted, so by the time money arrives the
     * dispute window may already have run out. Refusing to deploy would be the stricter
     * reading, but it would also mean nothing could ever deploy at that address again — and
     * because the address holds no code, nobody could move the funds either. That strands
     * real money to defend a window that has already gone.
     *
     * So we deploy. The escrow lands funded-and-expired: the seller can claim at once and
     * the buyer cannot dispute (CannotDisputeAfterExpiry). The system already has this
     * shape — an instant transfer (expiryTimestamp == 0) is the same bargain, chosen up
     * front. The difference worth remembering is that here the buyer did NOT choose it, so
     * callers should treat a late funding as something to surface, not to pass over
     * quietly.
     *
     * createEscrowContract keeps the check: creating a fresh escrow whose window has
     * already closed is a caller bug, and there is no stranded money to rescue.
     */
    function createAndActivate(
        address tokenAddress,
        address buyer,
        address seller,
        uint256 amount,
        uint256 expiryTimestamp,
        string memory description,
        address arbiter,
        bytes32 externalId
    ) external returns (address clone) {
        clone = _create(
            Terms(tokenAddress, buyer, seller, amount, expiryTimestamp, arbiter, externalId, address(0), 0),
            description,
            false,
            ""
        );
        EscrowContract(clone).checkAndActivate();
    }

    /**
     * 🏭 CREATE AND ACTIVATE, WITH A PARTNER SPLIT — the late-funding path for split escrows.
     *
     * Still permissionless: the signature authorises the split, not the caller. Whoever
     * rescues a late-funded split escrow needs the signature the address was quoted with,
     * so it must be kept alongside the pending contract for as long as funds could arrive.
     */
    function createAndActivateWithSplit(
        address tokenAddress,
        address buyer,
        address seller,
        uint256 amount,
        uint256 expiryTimestamp,
        string memory description,
        address arbiter,
        bytes32 externalId,
        FeeSplit calldata split,
        bytes calldata signature
    ) external returns (address clone) {
        clone = _create(
            Terms(
                tokenAddress,
                buyer,
                seller,
                amount,
                expiryTimestamp,
                arbiter,
                externalId,
                split.partner,
                split.partnerBps
            ),
            description,
            false,
            signature
        );
        EscrowContract(clone).checkAndActivate();
    }

    /**
     * The address of an escrow with these parameters, whether or not it exists yet.
     *
     * Pure function of its arguments — it reads no chain state beyond this factory's own
     * immutables, so a client can compute the same value locally without an RPC call and
     * without this factory being consulted at all.
     */
    function getContractAddress(
        address tokenAddress,
        address buyer,
        address seller,
        uint256 amount,
        uint256 expiryTimestamp,
        address arbiter,
        bytes32 externalId
    ) external view returns (address) {
        return Clones.predictDeterministicAddress(
            IMPLEMENTATION,
            _salt(Terms(tokenAddress, buyer, seller, amount, expiryTimestamp, arbiter, externalId, address(0), 0)),
            address(this)
        );
    }

    /// The address of a split escrow. With partnerBps == 0 this equals getContractAddress.
    function getContractAddressWithSplit(
        address tokenAddress,
        address buyer,
        address seller,
        uint256 amount,
        uint256 expiryTimestamp,
        address arbiter,
        bytes32 externalId,
        FeeSplit calldata split
    ) external view returns (address) {
        return Clones.predictDeterministicAddress(
            IMPLEMENTATION,
            _salt(
                Terms(
                    tokenAddress,
                    buyer,
                    seller,
                    amount,
                    expiryTimestamp,
                    arbiter,
                    externalId,
                    split.partner,
                    split.partnerBps
                )
            ),
            address(this)
        );
    }

    /**
     * The EIP-712 digest FEE_SPLIT_SIGNER signs for these terms. Exposed so signing code
     * can check its encoding against the chain before it hands out an address.
     */
    function feeSplitDigest(
        address tokenAddress,
        address buyer,
        address seller,
        uint256 amount,
        uint256 expiryTimestamp,
        address arbiter,
        bytes32 externalId,
        FeeSplit calldata split
    ) external view returns (bytes32) {
        return _feeSplitDigest(
            Terms(
                tokenAddress,
                buyer,
                seller,
                amount,
                expiryTimestamp,
                arbiter,
                externalId,
                split.partner,
                split.partnerBps
            )
        );
    }

    /**
     * 🔐 THE SALT — and why every initialize parameter is in it.
     *
     * initialize() on the clone is `external` with no caller restriction; its only guard is
     * that it runs once. So whoever deploys a given address first chooses that escrow's terms.
     * Because the salt now has to be predictable (that is the whole point), the address is no
     * longer a secret, and "deploy it first" is something anyone can attempt.
     *
     * That is safe ONLY while every parameter initialize() consumes is committed to here: an
     * attacker who wants a different buyer, seller, amount, expiry or arbiter necessarily
     * computes a different salt, and therefore a different address, and therefore cannot
     * occupy this one. Front-running collapses into building exactly the escrow that was
     * asked for, at the attacker's own gas expense.
     *
     * ⚠️ If a parameter is ever added to initialize(), it MUST be added here too.
     *
     * The partner split is: partner and partnerBps are appended when partnerBps > 0, so a
     * split lands at a different address from the same terms without one, and nobody can
     * strip (or swap) the split off an address that has been quoted and funded. With no
     * split the encoding is byte-for-byte the pre-split one - every existing address, the
     * committed vector and every off-chain predictor stay correct unchanged.
     *
     * The signature is NOT in the salt. It authorises the split; the salt commits to it.
     * FEE_RECIPIENT is not in it either: it is a factory immutable, already pinned by the
     * factory address that CREATE2 hashes in.
     *
     * `description` is deliberately absent: it is advisory metadata, emitted in the event and
     * never stored, and it feeds no permission or fund-flow decision. Keeping it out also
     * keeps this an unambiguous encoding of fixed-size values — abi.encodePacked over mixed
     * dynamic types is where hash-collision footguns live.
     *
     * `externalId` is opaque to this contract: any value unique per intended escrow. Callers
     * use the pending contract's id, which exists before payment and is therefore known to
     * both sides at prediction time. It is what lets two escrows with otherwise identical
     * terms occupy different addresses.
     */
    function _salt(Terms memory t) internal pure returns (bytes32) {
        if (t.partnerBps == 0) {
            return keccak256(
                abi.encodePacked(
                    t.tokenAddress, t.buyer, t.seller, t.amount, t.expiryTimestamp, t.arbiter, t.externalId
                )
            );
        }
        return keccak256(
            abi.encodePacked(
                t.tokenAddress,
                t.buyer,
                t.seller,
                t.amount,
                t.expiryTimestamp,
                t.arbiter,
                t.externalId,
                t.partner,
                t.partnerBps
            )
        );
    }

    function _feeSplitDigest(Terms memory t) internal view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    FEE_SPLIT_TYPEHASH,
                    t.tokenAddress,
                    t.buyer,
                    t.seller,
                    t.amount,
                    t.expiryTimestamp,
                    t.arbiter,
                    t.externalId,
                    t.partner,
                    t.partnerBps
                )
            )
        );
    }

    /**
     * 🔐 THE SPLIT GATE.
     *
     * Creation is permissionless and addresses are counterfactual, so the question is never
     * "who is calling" - a late-funded escrow must be deployable by anyone. It is "did the
     * signer approve exactly these terms". The EIP-712 domain binds the chain and this
     * factory, and the struct covers every term, so a signature is good for one address
     * only. Replaying it just rebuilds that address, which CREATE2 allows once.
     *
     * No expiry and no nonce, deliberately: funds may reach a quoted address at any time,
     * and the escrow must stay deployable on top of them. The price is that a signature
     * cannot be revoked. A leaked signer key can divert platform FEES on escrows its holder
     * gets buyers to fund - never escrowed funds, which only ever reach buyer or seller.
     */
    function _validateSplit(Terms memory t, bytes memory signature) internal view {
        if (t.partnerBps == 0) {
            // No split. A partner without a share would be ignored by the salt, so reject it
            // rather than let a caller believe it took effect.
            if (t.partner != address(0)) revert InvalidPartnerBps();
            return;
        }
        if (t.partnerBps > MAX_PARTNER_BPS) revert InvalidPartnerBps();
        if (t.partner == address(0) || t.partner == t.buyer || t.partner == t.seller || t.partner == FEE_RECIPIENT) {
            revert InvalidPartnerAddress();
        }
        if (!SignatureChecker.isValidSignatureNow(FEE_SPLIT_SIGNER, _feeSplitDigest(t), signature)) {
            revert InvalidFeeSplitSignature();
        }
    }

    function _validate(Terms memory t, bool requireFutureExpiry) internal view {
        if (t.tokenAddress == address(0)) revert InvalidTokenAddress();
        if (t.buyer == address(0)) revert InvalidBuyerAddress();
        if (t.seller == address(0)) revert InvalidSellerAddress();
        if (t.buyer == t.seller) revert BuyerSellerMustBeDifferent();
        if (t.amount == 0) revert AmountMustBeGreaterThanZero();
        if (requireFutureExpiry && t.expiryTimestamp != 0 && t.expiryTimestamp <= block.timestamp) {
            revert InvalidExpiryTimestamp();
        }
        // No msg.sender default any more. The arbiter is in the salt, so it has to be a value
        // the caller states and a client can reproduce — silently substituting the relayer
        // would make the address unpredictable to everyone except the relayer itself.
        if (t.arbiter == address(0)) revert InvalidArbiterAddress();
        // The arbiter must be an independent third party. Sharing the arbiter address
        // with the buyer or seller would hand that party 2-of-3 dispute votes. This
        // also blocks the footgun of a buyer/seller creating their own escrow and
        // defaulting the arbiter to themselves.
        if (t.arbiter == t.buyer || t.arbiter == t.seller) revert ArbiterMustBeDistinct();
    }

    /**
     * Terms bundled into a struct rather than passed flat: every one of them has to stay
     * live right through the initialize() call below, and eight loose stack slots plus the
     * call arguments overflows the stack with via_ir off. The external signatures stay flat.
     */
    struct Terms {
        address tokenAddress;
        address buyer;
        address seller;
        uint256 amount;
        uint256 expiryTimestamp;
        address arbiter;
        bytes32 externalId;
        address partner;
        uint16 partnerBps;
    }

    function _create(Terms memory t, string memory description, bool requireFutureExpiry, bytes memory signature)
        internal
        returns (address clone)
    {
        _validate(t, requireFutureExpiry);
        _validateSplit(t, signature);

        // 🏭 Create from the secure template, at the address the salt determines
        clone = Clones.cloneDeterministic(IMPLEMENTATION, _salt(t));

        uint256 partnerFee = _initialize(clone, t);

        // 📝 Record this contract creation permanently on blockchain
        emit ContractCreated(clone, t.buyer, t.seller, t.amount, t.expiryTimestamp, description);
        if (t.partnerBps > 0) {
            emit FeeSplitApplied(clone, t.partner, t.partnerBps, partnerFee);
        }

        // ✅ SECURITY CONFIRMATION: The new contract now has all the security guarantees
        //    described in EscrowContract.sol. Factory has no further control over it.
    }

    /// Split out of _create only because ten initialize arguments overflow its stack.
    function _initialize(address clone, Terms memory t) internal returns (uint256 partnerFee) {
        uint256 creatorFee = _calculateCreatorFee(t.tokenAddress, t.amount);
        // Rounds down: any dust stays with the platform.
        partnerFee = (creatorFee * t.partnerBps) / MAX_PARTNER_BPS;

        // 🔒 Initialize with IMMUTABLE security settings
        // Note: description is NOT passed to initialize - only emitted in event
        EscrowContract(clone)
            .initialize(
                t.tokenAddress, // ERC20 token to be used for this escrow
                t.buyer, // ONLY this address can deposit and dispute
                t.seller, // ONLY this address can receive funds (with buyer)
                t.arbiter, // Arbiter - can vote on disputes but NOT take money
                t.amount,
                t.expiryTimestamp,
                creatorFee, // Platform fee (transparent and upfront)
                FEE_RECIPIENT, // Address that receives the platform fee
                t.partner, // Partner sharing the fee (address(0) = none)
                partnerFee // Partner's portion, carved out of creatorFee
            );
    }

    /**
     * Calculates the creator fee for a given token and amount.
     * - Amounts at or below 1/1000 of one token unit: zero fee.
     * - Otherwise: max(1% of amount, 30% of one token unit).
     *   Reverts if the amount is too small to cover the minimum fee.
     */
    function _calculateCreatorFee(address tokenAddress, uint256 amount) internal view returns (uint256) {
        // decimals() is an OPTIONAL ERC20 extension. Tokens that omit it (or revert)
        // must not brick escrow creation, so fall back to the 18-decimal convention.
        // Clamp to a sane maximum to avoid 10**decimals overflowing uint256.
        uint8 decimals = 18;
        try IERC20Metadata(tokenAddress).decimals() returns (uint8 d) {
            if (d <= 36) decimals = d;
        } catch {
            // keep the 18-decimal fallback
        }

        uint256 oneUnit = 10 ** decimals;
        uint256 noFeeThreshold = oneUnit / 1000;

        if (amount <= noFeeThreshold) return 0;

        uint256 minFee = (oneUnit * 30) / 100;
        if (amount <= minFee) revert AmountTooSmallForMinFee();

        uint256 onePercentFee = amount / 100;
        uint256 fee = onePercentFee > minFee ? onePercentFee : minFee;

        if (fee >= amount) revert CreatorFeeMustBeLessThanAmount();
        return fee;
    }
}
