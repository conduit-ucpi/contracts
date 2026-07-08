// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
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
    error AmountTooSmallForMinFee();
    error CreatorFeeMustBeLessThanAmount();

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
     * All addresses and the split are locked in at creation.
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
        if (tokenAddress == address(0)) revert InvalidTokenAddress();
        if (buyer == address(0)) revert InvalidBuyerAddress();
        if (seller == address(0)) revert InvalidSellerAddress();
        if (buyer == seller) revert BuyerSellerMustBeDifferent();
        // A nominated verifier acts for the buyer - it must never be the supplier
        if (verifier == seller) revert VerifierCannotBeSeller();
        if (amount == 0) revert AmountMustBeGreaterThanZero();
        // This variant has no instant transfer - expiry must be a real future timestamp
        if (expiryTimestamp <= block.timestamp) revert InvalidExpiryTimestamp();
        // The recipient split is validated in CompletionEscrowContract.initialize.

        // Collapse the params into a memory struct so the deploy step has a shallow stack
        EscrowParams memory p = EscrowParams({
            tokenAddress: tokenAddress,
            buyer: buyer,
            seller: seller,
            amount: amount,
            expiryTimestamp: expiryTimestamp,
            recipients: recipients,
            recipientBps: recipientBps,
            verifier: verifier,
            creatorFee: _calculateCreatorFee(tokenAddress, amount)
        });

        address clone = _deploy(p);

        emit ContractCreated(
            clone,
            buyer,
            seller,
            amount,
            expiryTimestamp,
            recipients,
            recipientBps,
            verifier,
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
     * 📊 Dynamic platform fee: free below 1/1000 of one token unit, otherwise the
     * greater of 1% of the amount or 30% of one token unit.
     */
    function _calculateCreatorFee(address tokenAddress, uint256 amount) internal view returns (uint256) {
        uint8 decimals = IERC20Metadata(tokenAddress).decimals();

        uint256 oneUnit = 10 ** decimals;
        uint256 noFeeThreshold = oneUnit / 1000;

        if (amount <= noFeeThreshold) {
            return 0;
        }

        uint256 minFee = (oneUnit * 30) / 100;
        if (amount <= minFee) revert AmountTooSmallForMinFee();

        uint256 onePercentFee = amount / 100;
        uint256 creatorFee = onePercentFee > minFee ? onePercentFee : minFee;

        if (creatorFee >= amount) revert CreatorFeeMustBeLessThanAmount();
        return creatorFee;
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
