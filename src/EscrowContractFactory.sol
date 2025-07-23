// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EscrowContract} from "./EscrowContract.sol";

contract EscrowContractFactory is Ownable, ReentrancyGuard {
    
    IERC20 public immutable USDC_TOKEN;
    
    event ContractCreated(
        address indexed contractAddress,
        address indexed buyer,
        address indexed seller,
        uint256 amount,
        uint256 expiryTimestamp,
        string description
    );
    
    constructor(address _usdcToken, address _owner) Ownable(_owner) {
        require(_usdcToken != address(0), "Invalid USDC address");
        require(_owner != address(0), "Invalid owner address");
        
        USDC_TOKEN = IERC20(_usdcToken);
    }
    
    function createEscrowContract(
        address seller,
        uint256 amount,
        uint256 expiryTimestamp,
        string calldata description
    ) external onlyOwner nonReentrant returns (address) {
        require(seller != address(0), "Invalid seller address");
        require(amount > 0, "Amount must be positive");
        require(expiryTimestamp > block.timestamp, "Expiry must be future");
        require(bytes(description).length <= 160, "Description too long");
        
        bytes32 salt = keccak256(abi.encodePacked(
            msg.sender,
            seller,
            amount,
            expiryTimestamp,
            block.timestamp
        ));
        
        // Transfer USDC from buyer to factory first
        require(
            USDC_TOKEN.transferFrom(msg.sender, address(this), amount),
            "USDC transfer failed"
        );
        
        EscrowContract newContract = new EscrowContract{salt: salt}(
            address(USDC_TOKEN),
            msg.sender,
            seller,
            owner(),
            amount,
            expiryTimestamp,
            description
        );
        
        // Transfer USDC from factory to the new escrow contract
        require(
            USDC_TOKEN.transfer(address(newContract), amount),
            "USDC transfer to escrow failed"
        );
        
        emit ContractCreated(
            address(newContract),
            msg.sender,
            seller,
            amount,
            expiryTimestamp,
            description
        );
        
        return address(newContract);
    }
    
    function getContractAddress(
        address buyer,
        address seller,
        uint256 amount,
        uint256 expiryTimestamp,
        uint256 creationTimestamp,
        string calldata description
    ) external view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(
            buyer,
            seller,
            amount,
            expiryTimestamp,
            creationTimestamp
        ));
        
        bytes32 hash = keccak256(abi.encodePacked(
            bytes1(0xff),
            address(this),
            salt,
            keccak256(abi.encodePacked(
                type(EscrowContract).creationCode,
                abi.encode(
                    address(USDC_TOKEN),
                    buyer,
                    seller,
                    owner(),
                    amount,
                    expiryTimestamp,
                    description
                )
            ))
        ));
        
        return address(uint160(uint256(hash)));
    }
}