// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {CompletionEscrowContract} from "./CompletionEscrowContract.sol";

/**
 * ═══════════════════════════════════════════════════════════════════════════════════
 *           🔒 COMPLETION ESCROW FACTORY (DUAL-VERIFY + RECIPIENT SPLIT) 🔒
 * ═══════════════════════════════════════════════════════════════════════════════════
 *
 * Creates individual CompletionEscrowContract instances via minimal proxies. Each
 * escrow gates payout behind BOTH supplier and buyer agreement (dual-verify) and pays
 * out to up to MAX_RECIPIENTS recipients by a configured basis-point split. The factory
 * has no power over contracts once created.
 *
 * The recipient split is validated inside CompletionEscrowContract.initialize; that
 * revert bubbles up through createEscrowContract, so callers see the same errors.
 * ═══════════════════════════════════════════════════════════════════════════════════
 */
contract CompletionEscrowContractFactory {

    // Custom errors (saves gas compared to require strings)
    error InvalidOwnerAddress();
    error InvalidImplementationAddress();
    error InvalidTokenAddress();
    error InvalidBuyerAddress();
    error InvalidSellerAddress();
    error BuyerSellerMustBeDifferent();
    error VerifierCannotBeSeller();
    error AmountMustBeGreaterThanZero();
    error InvalidExpiryTimestamp();
    error OnlyOwner();

    // 🔒 IMMUTABLE FACTORY SETTINGS
    address public immutable OWNER;          // Platform/arbiter - creates contracts, cannot take money
    address public immutable IMPLEMENTATION; // Template contract (all escrows share its security)
    address public immutable FEE_RECIPIENT;  // Receives platform fees (defaults to OWNER if unset)

    // 📢 PUBLIC EVENT: Records every escrow creation
    event ContractCreated(
        address indexed contractAddress,
        address indexed buyer,
        address indexed seller,
        uint256 amount,
        uint256 expiryTimestamp,
        address[] recipients,
        uint256[] recipientBps,
        address verifier,
        string description
    );

    constructor(address _owner, address _implementation, address _feeRecipient) {
        if (_owner == address(0)) revert InvalidOwnerAddress();
        if (_implementation == address(0)) revert InvalidImplementationAddress();

        OWNER = _owner;
        IMPLEMENTATION = _implementation;
        FEE_RECIPIENT = _feeRecipient == address(0) ? _owner : _feeRecipient;
    }

    /**
     * 🏭 CREATE NEW COMPLETION ESCROW CONTRACT
     *
     * Creates a dual-verify escrow between BUYER and SELLER (supplier), paying out to
     * 1..MAX_RECIPIENTS recipients by a basis-point split (the bps must sum to 10000).
     * All addresses and the split are locked in at creation. Charges the flat 1%
     * platform fee - this is the path for top-level (root) escrows.
     */
    function createEscrowContract(
        address tokenAddress,
        address buyer,
        address seller,
        uint256 amount,
        uint256 expiryTimestamp,
        address[] calldata recipients,
        uint256[] calldata recipientBps,
        address verifier,
        string memory description
    ) external returns (address) {
        return _create(EscrowParams({
            tokenAddress: tokenAddress,
            buyer: buyer,
            seller: seller,
            amount: amount,
            expiryTimestamp: expiryTimestamp,
            recipients: recipients,
            recipientBps: recipientBps,
            verifier: verifier,
            creatorFee: _calculateCreatorFee(amount)
        }), description);
    }

    /**
     * 🏭 CREATE CHILD ESCROW CONTRACT (FEE-EXEMPT, PLATFORM ONLY)
     *
     * The platform fee is charged once per fan-out tree, on the top-level escrow.
     * Child nodes are created through this fee-exempt path instead. Only OWNER (the
     * platform relayer, which deploys all nodes) may call it - otherwise anyone
     * could create fee-free escrows.
     */
    function createChildEscrowContract(
        address tokenAddress,
        address buyer,
        address seller,
        uint256 amount,
        uint256 expiryTimestamp,
        address[] calldata recipients,
        uint256[] calldata recipientBps,
        address verifier,
        string memory description
    ) external returns (address) {
        if (msg.sender != OWNER) revert OnlyOwner();
        return _create(EscrowParams({
            tokenAddress: tokenAddress,
            buyer: buyer,
            seller: seller,
            amount: amount,
            expiryTimestamp: expiryTimestamp,
            recipients: recipients,
            recipientBps: recipientBps,
            verifier: verifier,
            creatorFee: 0
        }), description);
    }

    /**
     * Shared validate + deploy + announce path for both creation variants. The params
     * arrive as a memory struct so the deploy step keeps a shallow stack.
     */
    function _create(EscrowParams memory p, string memory description) internal returns (address) {
        if (p.tokenAddress == address(0)) revert InvalidTokenAddress();
        if (p.buyer == address(0)) revert InvalidBuyerAddress();
        if (p.seller == address(0)) revert InvalidSellerAddress();
        if (p.buyer == p.seller) revert BuyerSellerMustBeDifferent();
        // A nominated verifier acts for the buyer - it must never be the supplier
        if (p.verifier == p.seller) revert VerifierCannotBeSeller();
        if (p.amount == 0) revert AmountMustBeGreaterThanZero();
        // This variant has no instant transfer - expiry must be a real future timestamp
        if (p.expiryTimestamp <= block.timestamp) revert InvalidExpiryTimestamp();
        // The recipient split is validated in CompletionEscrowContract.initialize.

        address clone = _deploy(p);

        emit ContractCreated(
            clone,
            p.buyer,
            p.seller,
            p.amount,
            p.expiryTimestamp,
            p.recipients,
            p.recipientBps,
            p.verifier,
            description
        );

        return clone;
    }

    // Internal carrier for escrow parameters - keeps createEscrowContract's stack shallow
    struct EscrowParams {
        address tokenAddress;
        address buyer;
        address seller;
        uint256 amount;
        uint256 expiryTimestamp;
        address[] recipients;
        uint256[] recipientBps;
        address verifier;
        uint256 creatorFee;
    }

    /**
     * 🏭 Deterministically clones the implementation and initializes it. Split into
     * _computeSalt and _init so each heavy step gets its own stack frame and the build
     * stays within the stack limit with via_ir disabled.
     */
    function _deploy(EscrowParams memory p) internal returns (address) {
        address clone = Clones.cloneDeterministic(IMPLEMENTATION, _computeSalt(p));
        _init(clone, p);
        return clone;
    }

    function _computeSalt(EscrowParams memory p) internal view returns (bytes32) {
        // abi.encode (not encodePacked) so the dynamic arrays are encoded unambiguously
        return keccak256(abi.encode(
            p.tokenAddress,
            p.buyer,
            p.seller,
            p.amount,
            p.expiryTimestamp,
            p.recipients,
            p.recipientBps,
            block.timestamp
        ));
    }

    function _init(address clone, EscrowParams memory p) internal {
        CompletionEscrowContract(clone).initialize(
            CompletionEscrowContract.InitParams({
                tokenAddress: p.tokenAddress,
                buyer: p.buyer,
                seller: p.seller,
                gasPayer: OWNER,
                amount: p.amount,
                expiryTimestamp: p.expiryTimestamp,
                creatorFee: p.creatorFee,
                feeRecipient: FEE_RECIPIENT,
                recipients: p.recipients,
                recipientBps: p.recipientBps,
                verifier: p.verifier
            })
        );
    }

    /**
     * 📊 Flat 1% platform fee, floor division. No minimum and no thresholds: tiny
     * amounts floor to a zero fee, and 1% can never reach the escrow contract's
     * creatorFee < amount limit, so no amount or split can revert a creation.
     */
    function _calculateCreatorFee(uint256 amount) internal pure returns (uint256) {
        return amount / 100;
    }

    function getContractAddress(
        address tokenAddress,
        address buyer,
        address seller,
        uint256 amount,
        uint256 expiryTimestamp,
        address[] calldata recipients,
        uint256[] calldata recipientBps,
        uint256 creationTimestamp
    ) external view returns (address) {
        bytes32 salt = keccak256(abi.encode(
            tokenAddress,
            buyer,
            seller,
            amount,
            expiryTimestamp,
            recipients,
            recipientBps,
            creationTimestamp
        ));

        return Clones.predictDeterministicAddress(IMPLEMENTATION, salt, address(this));
    }
}
