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
 * out to up to two recipients by a configured basis-point split. The factory has no
 * power over contracts once created.
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
    error InvalidRecipientAddress();
    error RecipientsMustBeDifferent();
    error InvalidRecipientSplit();
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
        address recipient1,
        address recipient2,
        uint256 recipient1Bps,
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
     * one or two recipients by a basis-point split. All addresses and the split are
     * locked in at creation.
     */
    function createEscrowContract(
        address tokenAddress,
        address buyer,
        address seller,
        uint256 amount,
        uint256 expiryTimestamp,
        address recipient1,
        address recipient2,
        uint256 recipient1Bps,
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

        // Validate the recipient split up front (mirrors CompletionEscrowContract.initialize)
        if (recipient1 == address(0)) revert InvalidRecipientAddress();
        if (recipient2 == address(0)) {
            if (recipient1Bps != 10000) revert InvalidRecipientSplit();
        } else {
            if (recipient1 == recipient2) revert RecipientsMustBeDifferent();
            if (recipient1Bps == 0 || recipient1Bps >= 10000) revert InvalidRecipientSplit();
        }

        // Collapse the params into a memory struct so the deploy step has a shallow stack
        EscrowParams memory p = EscrowParams({
            tokenAddress: tokenAddress,
            buyer: buyer,
            seller: seller,
            amount: amount,
            expiryTimestamp: expiryTimestamp,
            recipient1: recipient1,
            recipient2: recipient2,
            recipient1Bps: recipient1Bps,
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
            recipient1,
            recipient2,
            recipient1Bps,
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
        address recipient1;
        address recipient2;
        uint256 recipient1Bps;
        address verifier;
        uint256 creatorFee;
    }

    /**
     * 🏭 Deterministically clones the implementation and initializes it. Lives in its
     * own stack frame so the deterministic salt (which mixes in many params) does not
     * exhaust the stack with via_ir disabled.
     */
    function _deploy(EscrowParams memory p) internal returns (address) {
        address clone = Clones.cloneDeterministic(IMPLEMENTATION, _computeSalt(p));
        _init(clone, p);
        return clone;
    }

    function _computeSalt(EscrowParams memory p) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(
            p.tokenAddress,
            p.buyer,
            p.seller,
            p.amount,
            p.expiryTimestamp,
            p.recipient1,
            p.recipient2,
            p.recipient1Bps,
            block.timestamp
        ));
    }

    function _init(address clone, EscrowParams memory p) internal {
        CompletionEscrowContract(clone).initialize(
            p.tokenAddress,
            p.buyer,
            p.seller,
            OWNER,
            p.amount,
            p.expiryTimestamp,
            p.creatorFee,
            FEE_RECIPIENT,
            p.recipient1,
            p.recipient2,
            p.recipient1Bps,
            p.verifier
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
        address recipient1,
        address recipient2,
        uint256 recipient1Bps,
        uint256 creationTimestamp
    ) external view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(
            tokenAddress,
            buyer,
            seller,
            amount,
            expiryTimestamp,
            recipient1,
            recipient2,
            recipient1Bps,
            creationTimestamp
        ));

        return Clones.predictDeterministicAddress(IMPLEMENTATION, salt, address(this));
    }
}
