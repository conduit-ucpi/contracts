// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract EscrowContract is ReentrancyGuard {
    
    IERC20 public immutable usdcToken;
    address public immutable factory;
    address public immutable buyer;
    address public immutable seller;
    address public immutable gasPayer;
    
    uint256 public immutable amount;
    uint256 public immutable expiryTimestamp;
    string public description;
    
    bool public disputed;
    bool public resolved;
    bool public claimed;
    
    event DisputeRaised(uint256 timestamp);
    event DisputeResolved(address recipient, uint256 timestamp);
    event FundsClaimed(address recipient, uint256 amount, uint256 timestamp);
    
    modifier onlyBuyer() {
        require(msg.sender == buyer, "Only buyer can call");
        _;
    }
    
    modifier onlyGasPayer() {
        require(msg.sender == gasPayer, "Only gas payer can call");
        _;
    }
    
    modifier onlySellerOrGasPayer() {
        require(msg.sender == seller || msg.sender == gasPayer, "Unauthorized");
        _;
    }
    
    constructor(
        address _usdcToken,
        address _buyer,
        address _seller,
        address _gasPayer,
        uint256 _amount,
        uint256 _expiryTimestamp,
        string memory _description
    ) {
        require(_usdcToken != address(0), "Invalid USDC address");
        require(_buyer != address(0), "Invalid buyer");
        require(_seller != address(0), "Invalid seller");
        require(_gasPayer != address(0), "Invalid gas payer");
        require(_amount > 0, "Amount must be positive");
        require(_expiryTimestamp > block.timestamp, "Expiry must be future");
        require(bytes(_description).length <= 160, "Description too long");
        
        usdcToken = IERC20(_usdcToken);
        factory = msg.sender;
        buyer = _buyer;
        seller = _seller;
        gasPayer = _gasPayer;
        amount = _amount;
        expiryTimestamp = _expiryTimestamp;
        description = _description;
        
        require(
            usdcToken.transferFrom(_buyer, address(this), _amount),
            "USDC transfer failed"
        );
    }
    
    function raiseDispute() external onlyBuyer nonReentrant {
        require(!disputed, "Already disputed");
        require(!claimed, "Already claimed");
        
        disputed = true;
        emit DisputeRaised(block.timestamp);
    }
    
    function resolveDispute(address recipient) external onlyGasPayer nonReentrant {
        require(disputed, "Not disputed");
        require(!resolved, "Already resolved");
        require(recipient == buyer || recipient == seller, "Invalid recipient");
        
        resolved = true;
        claimed = true;
        
        require(
            usdcToken.transfer(recipient, amount),
            "USDC transfer failed"
        );
        
        emit DisputeResolved(recipient, block.timestamp);
        emit FundsClaimed(recipient, amount, block.timestamp);
    }
    
    function claimFunds() external onlySellerOrGasPayer nonReentrant {
        require(block.timestamp >= expiryTimestamp, "Not expired yet");
        require(!disputed, "Contract disputed");
        require(!claimed, "Already claimed");
        
        claimed = true;
        
        require(
            usdcToken.transfer(seller, amount),
            "USDC transfer failed"
        );
        
        emit FundsClaimed(seller, amount, block.timestamp);
    }
    
    function getContractInfo() external view returns (
        address _buyer,
        address _seller,
        uint256 _amount,
        uint256 _expiryTimestamp,
        string memory _description,
        bool _disputed,
        bool _resolved,
        bool _claimed,
        uint256 _currentTimestamp
    ) {
        return (
            buyer,
            seller,
            amount,
            expiryTimestamp,
            description,
            disputed,
            resolved,
            claimed,
            block.timestamp
        );
    }
    
    function isExpired() external view returns (bool) {
        return block.timestamp >= expiryTimestamp;
    }
    
    function canClaim() external view returns (bool) {
        return block.timestamp >= expiryTimestamp && !disputed && !claimed;
    }
    
    function canDispute() external view returns (bool) {
        return !disputed && !claimed;
    }
}