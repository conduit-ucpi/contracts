// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
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
 * ═══════════════════════════════════════════════════════════════════════════════════
 */
contract EscrowContractFactory {
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

    // 🔒 IMMUTABLE FACTORY SETTINGS: These CANNOT be changed after deployment
    address public immutable OWNER; // Platform address - can create contracts but NOT access money
    address public immutable IMPLEMENTATION; // Template contract - ensures all escrows have same security
    address public immutable FEE_RECIPIENT; // Address that receives platform fees (defaults to OWNER if not set)

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

    constructor(address _owner, address _implementation, address _feeRecipient) {
        if (_owner == address(0)) revert InvalidOwnerAddress();
        if (_implementation == address(0)) revert InvalidImplementationAddress();

        OWNER = _owner;
        IMPLEMENTATION = _implementation;
        // Default to OWNER if feeRecipient not specified
        FEE_RECIPIENT = _feeRecipient == address(0) ? _owner : _feeRecipient;
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
        return _create(Terms(tokenAddress, buyer, seller, amount, expiryTimestamp, arbiter, externalId), description);
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
        clone = _create(Terms(tokenAddress, buyer, seller, amount, expiryTimestamp, arbiter, externalId), description);
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
            _salt(Terms(tokenAddress, buyer, seller, amount, expiryTimestamp, arbiter, externalId)),
            address(this)
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
        return keccak256(
            abi.encodePacked(t.tokenAddress, t.buyer, t.seller, t.amount, t.expiryTimestamp, t.arbiter, t.externalId)
        );
    }

    function _validate(Terms memory t) internal view {
        if (t.tokenAddress == address(0)) revert InvalidTokenAddress();
        if (t.buyer == address(0)) revert InvalidBuyerAddress();
        if (t.seller == address(0)) revert InvalidSellerAddress();
        if (t.buyer == t.seller) revert BuyerSellerMustBeDifferent();
        if (t.amount == 0) revert AmountMustBeGreaterThanZero();
        if (t.expiryTimestamp != 0 && t.expiryTimestamp <= block.timestamp) revert InvalidExpiryTimestamp();
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
    }

    function _create(Terms memory t, string memory description) internal returns (address clone) {
        _validate(t);

        // 🏭 Create from the secure template, at the address the salt determines
        clone = Clones.cloneDeterministic(IMPLEMENTATION, _salt(t));

        // 🔒 Initialize with IMMUTABLE security settings
        // Note: description is NOT passed to initialize - only emitted in event below
        EscrowContract(clone)
            .initialize(
                t.tokenAddress, // ERC20 token to be used for this escrow
                t.buyer, // ONLY this address can deposit and dispute
                t.seller, // ONLY this address can receive funds (with buyer)
                t.arbiter, // Arbiter - can vote on disputes but NOT take money
                t.amount,
                t.expiryTimestamp,
                _calculateCreatorFee(t.tokenAddress, t.amount), // Platform fee (transparent and upfront)
                FEE_RECIPIENT // Address that receives the platform fee
            );

        // 📝 Record this contract creation permanently on blockchain
        emit ContractCreated(clone, t.buyer, t.seller, t.amount, t.expiryTimestamp, description);

        // ✅ SECURITY CONFIRMATION: The new contract now has all the security guarantees
        //    described in EscrowContract.sol. Factory has no further control over it.
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
