// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./EscrowContract.sol";

contract EscrowContractFactory is Ownable, ReentrancyGuard {
    
    IERC20 public immutable usdcToken;
    
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
        
        usdcToken = IERC20(_usdcToken);
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
        
        EscrowContract newContract = new EscrowContract{salt: salt}(
            address(usdcToken),
            msg.sender,
            seller,
            owner(),
            amount,
            expiryTimestamp,
            description
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
                    address(usdcToken),
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