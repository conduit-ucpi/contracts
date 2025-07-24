// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract EscrowContract is ReentrancyGuard {
    
    IERC20 public immutable USDC_TOKEN;
    address public immutable FACTORY;
    address public immutable BUYER;
    address public immutable SELLER;
    address public immutable GAS_PAYER;
    
    uint256 public immutable AMOUNT;
    uint256 public immutable EXPIRY_TIMESTAMP;
    string public description;
    
    bool public funded;
    bool public disputed;
    bool public resolved;
    bool public claimed;
    
    event FundsDeposited(address buyer, uint256 amount, uint256 timestamp);
    event DisputeRaised(uint256 timestamp);
    event DisputeResolved(address recipient, uint256 timestamp);
    event FundsClaimed(address recipient, uint256 amount, uint256 timestamp);
    
    modifier onlyBuyer() {
        require(msg.sender == BUYER, "Only buyer can call");
        _;
    }
    
    modifier onlyGasPayer() {
        require(msg.sender == GAS_PAYER, "Only gas payer can call");
        _;
    }
    
    modifier onlySellerOrGasPayer() {
        require(msg.sender == SELLER || msg.sender == GAS_PAYER, "Unauthorized");
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
        // Factory validates all parameters, so we only need basic non-zero checks
        require(_usdcToken != address(0), "Invalid USDC address");
        require(_buyer != address(0), "Invalid buyer");
        require(_seller != address(0), "Invalid seller");  
        require(_gasPayer != address(0), "Invalid gas payer");
        
        USDC_TOKEN = IERC20(_usdcToken);
        FACTORY = msg.sender;
        BUYER = _buyer;
        SELLER = _seller;
        GAS_PAYER = _gasPayer;
        AMOUNT = _amount;
        EXPIRY_TIMESTAMP = _expiryTimestamp;
        description = _description;
        
        // Note: Contract starts unfunded - buyer must call depositFunds()
    }
    
    function depositFunds() external onlyBuyer nonReentrant {
        require(!funded, "Already funded");
        require(!claimed, "Already claimed");
        
        funded = true;
        
        require(
            USDC_TOKEN.transferFrom(msg.sender, address(this), AMOUNT),
            "USDC transfer failed"
        );
        
        emit FundsDeposited(msg.sender, AMOUNT, block.timestamp);
    }
    
    function raiseDispute() external onlyBuyer nonReentrant {
        require(funded, "Contract not funded");
        require(!disputed, "Already disputed");
        require(!claimed, "Already claimed");
        
        disputed = true;
        emit DisputeRaised(block.timestamp);
    }
    
    function resolveDispute(address recipient) external onlyGasPayer nonReentrant {
        require(funded, "Contract not funded");
        require(disputed, "Not disputed");
        require(!resolved, "Already resolved");
        require(recipient == BUYER || recipient == SELLER, "Invalid recipient");
        
        resolved = true;
        claimed = true;
        
        require(
            USDC_TOKEN.transfer(recipient, AMOUNT),
            "USDC transfer failed"
        );
        
        emit DisputeResolved(recipient, block.timestamp);
        emit FundsClaimed(recipient, AMOUNT, block.timestamp);
    }
    
    function claimFunds() external onlySellerOrGasPayer nonReentrant {
        require(funded, "Contract not funded");
        require(block.timestamp >= EXPIRY_TIMESTAMP, "Not expired yet");
        require(!disputed, "Contract disputed");
        require(!claimed, "Already claimed");
        
        claimed = true;
        
        require(
            USDC_TOKEN.transfer(SELLER, AMOUNT),
            "USDC transfer failed"
        );
        
        emit FundsClaimed(SELLER, AMOUNT, block.timestamp);
    }
    
    function getContractInfo() external view returns (
        address _buyer,
        address _seller,
        uint256 _amount,
        uint256 _expiryTimestamp,
        string memory _description,
        bool _funded,
        bool _disputed,
        bool _resolved,
        bool _claimed,
        uint256 _currentTimestamp
    ) {
        return (
            BUYER,
            SELLER,
            AMOUNT,
            EXPIRY_TIMESTAMP,
            description,
            funded,
            disputed,
            resolved,
            claimed,
            block.timestamp
        );
    }
    
    function isExpired() external view returns (bool) {
        return block.timestamp >= EXPIRY_TIMESTAMP;
    }
    
    function canClaim() external view returns (bool) {
        return funded && block.timestamp >= EXPIRY_TIMESTAMP && !disputed && !claimed;
    }
    
    function canDispute() external view returns (bool) {
        return funded && !disputed && !claimed;
    }
    
    function isFunded() external view returns (bool) {
        return funded;
    }
    
    function canDeposit() external view returns (bool) {
        return !funded && !claimed;
    }
}