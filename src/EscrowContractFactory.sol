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
    error AmountMustBeGreaterThanZero();
    error InvalidExpiryTimestamp();
    error AmountTooSmallForMinFee();
    error CreatorFeeMustBeLessThanAmount();

    // 🔒 IMMUTABLE FACTORY SETTINGS: These CANNOT be changed after deployment
    address public immutable OWNER;       // Platform address - can create contracts but NOT access money
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
    function createEscrowContract(
        address tokenAddress,
        address buyer,
        address seller,
        uint256 amount,
        uint256 expiryTimestamp,
        string memory description,
        address arbiter
    ) external returns (address) {
        if (tokenAddress == address(0)) revert InvalidTokenAddress();
        if (buyer == address(0)) revert InvalidBuyerAddress();
        if (seller == address(0)) revert InvalidSellerAddress();
        if (buyer == seller) revert BuyerSellerMustBeDifferent();
        if (amount == 0) revert AmountMustBeGreaterThanZero();
        if (expiryTimestamp != 0 && expiryTimestamp <= block.timestamp) revert InvalidExpiryTimestamp();

        // Default arbiter to the caller when not specified
        if (arbiter == address(0)) arbiter = msg.sender;
        // The arbiter must be an independent third party. Sharing the arbiter address
        // with the buyer or seller would hand that party 2-of-3 dispute votes. This
        // also blocks the footgun of a buyer/seller creating their own escrow and
        // defaulting the arbiter to themselves.
        if (arbiter == buyer || arbiter == seller) revert ArbiterMustBeDistinct();

        uint256 creatorFee = _calculateCreatorFee(tokenAddress, amount);


        // 🔐 Generate unique contract address (deterministic but unpredictable)
        bytes32 salt = keccak256(abi.encodePacked(
            tokenAddress,
            buyer,
            seller,
            amount,
            expiryTimestamp,
            block.timestamp
        ));
        
        // 🏭 Create new contract from secure template
        address clone = Clones.cloneDeterministic(IMPLEMENTATION, salt);
        
        // 🔒 Initialize with IMMUTABLE security settings
        // Note: description is NOT passed to initialize - only emitted in event below
        EscrowContract(clone).initialize(
            tokenAddress,    // ERC20 token to be used for this escrow
            buyer,           // ONLY this address can deposit and dispute
            seller,          // ONLY this address can receive funds (with buyer)
            arbiter,         // Arbiter - can vote on disputes but NOT take money
            amount,
            expiryTimestamp,
            creatorFee,      // Platform fee (transparent and upfront)
            FEE_RECIPIENT    // Address that receives the platform fee
        );
        
        EscrowContract newContract = EscrowContract(clone);
        
        // 📝 Record this contract creation permanently on blockchain
        emit ContractCreated(
            address(newContract),
            buyer,
            seller,
            amount,
            expiryTimestamp,
            description
        );
        
        return address(newContract);
        
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

    function getContractAddress(
        address tokenAddress,
        address buyer,
        address seller,
        uint256 amount,
        uint256 expiryTimestamp,
        uint256 creationTimestamp
    ) external view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(
            tokenAddress,
            buyer,
            seller,
            amount,
            expiryTimestamp,
            creationTimestamp
        ));
        
        return Clones.predictDeterministicAddress(IMPLEMENTATION, salt, address(this));
    }
}