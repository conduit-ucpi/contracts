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
 * ❌ Cannot change BUYER or SELLER addresses after creation
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
     * ✅ Locks in the BUYER and SELLER addresses (cannot be changed)
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
        string memory description
    ) external returns (address) {
        if (tokenAddress == address(0)) revert InvalidTokenAddress();
        if (buyer == address(0)) revert InvalidBuyerAddress();
        if (seller == address(0)) revert InvalidSellerAddress();
        if (buyer == seller) revert BuyerSellerMustBeDifferent();
        if (amount == 0) revert AmountMustBeGreaterThanZero();
        if (expiryTimestamp != 0 && expiryTimestamp <= block.timestamp) revert InvalidExpiryTimestamp();
        
        // 📊 Query token decimals and calculate dynamic fee
        uint8 decimals = IERC20Metadata(tokenAddress).decimals();
        
        // Calculate one unit and special no-fee threshold (1/1000 of one unit)
        uint256 oneUnit = 10 ** decimals;
        uint256 noFeeThreshold = oneUnit / 1000;
        
        uint256 creatorFee;
        
        // Special case: amounts at or below 1/1000 of one unit have no fee
        if (amount <= noFeeThreshold) {
            creatorFee = 0;
        } else {
            // Calculate minimum fee (30% of one token unit)
            // For USDC (6 decimals): 1 unit = 1,000,000, so 30% = 300,000
            // For other tokens: adjust based on decimals
            uint256 minFee = (oneUnit * 30) / 100;
            
            // Reject contracts that can't afford the minimum fee
            if (amount <= minFee) revert AmountTooSmallForMinFee();

            // Calculate 1% of the amount
            uint256 onePercentFee = amount / 100;

            // Use the greater of 1% or minimum fee
            creatorFee = onePercentFee > minFee ? onePercentFee : minFee;

            // Ensure fee doesn't exceed the amount (should never happen with our logic, but safety check)
            if (creatorFee >= amount) revert CreatorFeeMustBeLessThanAmount();
        }
        
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
            OWNER,           // Platform - can resolve disputes but NOT take money
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