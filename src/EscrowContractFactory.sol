// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {EscrowContract} from "./EscrowContract.sol";

contract EscrowContractFactory {
    
    IERC20 public immutable USDC_TOKEN;
    address public immutable OWNER;
    address public immutable IMPLEMENTATION;
    
    event ContractCreated(
        address indexed contractAddress,
        address indexed buyer,
        address indexed seller,
        uint256 amount,
        uint256 expiryTimestamp
    );
    
    constructor(address _usdcToken, address _owner) {
        USDC_TOKEN = IERC20(_usdcToken);
        OWNER = _owner;
        IMPLEMENTATION = address(new EscrowContract());
    }
    
    function createEscrowContract(
        address buyer,
        address seller,
        uint256 amount,
        uint256 expiryTimestamp,
        string memory description
    ) external returns (address) {
        require(msg.sender == OWNER, "Only owner");
        require(buyer != address(0) && seller != address(0), "Invalid addresses");
        require(amount > 0 && expiryTimestamp > block.timestamp, "Invalid params");
        
        bytes32 salt = keccak256(abi.encodePacked(
            buyer,
            seller,
            amount,
            expiryTimestamp,
            block.timestamp
        ));
        
        address clone = Clones.cloneDeterministic(IMPLEMENTATION, salt);
        
        EscrowContract(clone).initialize(
            address(USDC_TOKEN),
            buyer,
            seller,
            OWNER,
            amount,
            expiryTimestamp,
            description
        );
        
        EscrowContract newContract = EscrowContract(clone);
        
        emit ContractCreated(
            address(newContract),
            buyer,
            seller,
            amount,
            expiryTimestamp
        );
        
        return address(newContract);
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