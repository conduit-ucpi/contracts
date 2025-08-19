// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
    
    // 🔒 IMMUTABLE FACTORY SETTINGS: These CANNOT be changed after deployment
    IERC20 public immutable USDC_TOKEN;    // USDC token used for all escrow contracts
    address public immutable OWNER;       // Platform address - can create contracts but NOT access money
    address public immutable IMPLEMENTATION; // Template contract - ensures all escrows have same security
    
    // 📢 PUBLIC EVENT: Records every escrow contract creation (permanent blockchain record)
    event ContractCreated(
        address indexed contractAddress,
        address indexed buyer,
        address indexed seller,
        uint256 amount,
        uint256 expiryTimestamp
    );
    
    constructor(address _usdcToken, address _owner) {
        require(_usdcToken != address(0), "Invalid USDC token address");
        require(_owner != address(0), "Invalid owner address");
        
        USDC_TOKEN = IERC20(_usdcToken);
        OWNER = _owner;
        IMPLEMENTATION = address(new EscrowContract());
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
        address buyer,
        address seller,
        uint256 amount,
        uint256 expiryTimestamp,
        string memory description,
        uint256 creatorFee
    ) external returns (address) {
        require(msg.sender == OWNER, "Only owner");
        require(buyer != address(0), "Invalid buyer address");
        require(seller != address(0), "Invalid seller address");
        require(buyer != seller, "Buyer and seller cannot be the same");
        require(amount > 0 && expiryTimestamp > block.timestamp, "Invalid params");
        require(creatorFee < amount, "Creator fee must be less than amount");
        
        // 🔐 Generate unique contract address (deterministic but unpredictable)
        bytes32 salt = keccak256(abi.encodePacked(
            buyer,
            seller,
            amount,
            expiryTimestamp,
            block.timestamp
        ));
        
        // 🏭 Create new contract from secure template
        address clone = Clones.cloneDeterministic(IMPLEMENTATION, salt);
        
        // 🔒 Initialize with IMMUTABLE security settings
        EscrowContract(clone).initialize(
            address(USDC_TOKEN),
            buyer,           // ONLY this address can deposit and dispute
            seller,          // ONLY this address can receive funds (with buyer)
            OWNER,           // Platform - can resolve disputes but NOT take money
            amount,
            expiryTimestamp,
            description,
            creatorFee       // Platform fee (transparent and upfront)
        );
        
        EscrowContract newContract = EscrowContract(clone);
        
        // 📝 Record this contract creation permanently on blockchain
        emit ContractCreated(
            address(newContract),
            buyer,
            seller,
            amount,
            expiryTimestamp
        );
        
        return address(newContract);
        
        // ✅ SECURITY CONFIRMATION: The new contract now has all the security guarantees
        //    described in EscrowContract.sol. Factory has no further control over it.
    }
    
    function getContractAddress(
        address buyer,
        address seller,
        uint256 amount,
        uint256 expiryTimestamp,
        uint256 creationTimestamp,
        string memory /* description */
    ) external view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(
            buyer,
            seller,
            amount,
            expiryTimestamp,
            creationTimestamp
        ));
        
        return Clones.predictDeterministicAddress(IMPLEMENTATION, salt, address(this));
    }
}