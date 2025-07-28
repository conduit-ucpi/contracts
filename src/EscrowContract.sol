// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";

contract EscrowContract is ERC2771Context {
    
    IERC20 public USDC_TOKEN;
    address public BUYER;
    address public SELLER;
    address public GAS_PAYER;
    
    uint256 public AMOUNT;
    uint256 public EXPIRY_TIMESTAMP;
    string public DESCRIPTION;
    uint256 public CREATOR_FEE; // Fee amount to be sent to creator on deposit
    
    uint8 private _state; // 0=unfunded, 1=funded, 2=disputed, 3=resolved, 4=claimed
    address private _trustedForwarderOverride;
    
    event FundsDeposited(address buyer, uint256 amount, uint256 timestamp);
    event DisputeRaised(uint256 timestamp);
    event DisputeResolved(uint256 buyerPercentage, uint256 sellerPercentage, uint256 timestamp);
    event FundsClaimed(address recipient, uint256 amount, uint256 timestamp);
    
    modifier onlyBuyer() {
        require(_msgSender() == BUYER, "Only buyer can call");
        _;
    }
    
    modifier onlyGasPayer() {
        require(_msgSender() == GAS_PAYER, "Only gas payer can call");
        _;
    }
    
    modifier onlySellerOrGasPayer() {
        require(_msgSender() == SELLER || _msgSender() == GAS_PAYER, "Unauthorized");
        _;
    }
    
    modifier initialized() {
        require(_state != 255, "Not initialized");
        _;
    }
    
    constructor() ERC2771Context(address(0)) {
        // Implementation contract - disable initialization
        _state = 255; // Mark as disabled
    }
    
    function trustedForwarder() public view virtual override returns (address) {
        return _trustedForwarderOverride != address(0) ? _trustedForwarderOverride : super.trustedForwarder();
    }
    
    function initialize(
        address _usdcToken,
        address _buyer,
        address _seller,
        address _gasPayer,
        uint256 _amount,
        uint256 _expiryTimestamp,
        string memory _description,
        address _trustedForwarder,
        uint256 _creatorFee
    ) external {
        require(_state == 0, "Already initialized");
        
        USDC_TOKEN = IERC20(_usdcToken);
        BUYER = _buyer;
        SELLER = _seller;
        GAS_PAYER = _gasPayer;
        AMOUNT = _amount;
        EXPIRY_TIMESTAMP = _expiryTimestamp;
        DESCRIPTION = _description;
        _trustedForwarderOverride = _trustedForwarder;
        CREATOR_FEE = _creatorFee;
        require(_creatorFee < _amount, "Creator fee must be less than amount");
        _state = 0; // Set to unfunded state
    }
    
    function depositFunds() external onlyBuyer initialized {
        require(_state == 0, "Already funded or claimed");
        
        _state = 1; // funded
        
        // Transfer full amount from buyer to contract
        require(
            USDC_TOKEN.transferFrom(_msgSender(), address(this), AMOUNT),
            "USDC transfer failed"
        );
        
        // Immediately transfer creator fee to gas payer (creator)
        if (CREATOR_FEE > 0) {
            require(
                USDC_TOKEN.transfer(GAS_PAYER, CREATOR_FEE),
                "Creator fee transfer failed"
            );
        }
        
        emit FundsDeposited(_msgSender(), AMOUNT, block.timestamp);
    }
    
    function raiseDispute() external onlyBuyer initialized {
        require(_state == 1, "Not funded or already processed");
        
        _state = 2; // disputed
        emit DisputeRaised(block.timestamp);
    }
    
    function resolveDispute(uint256 buyerPercentage, uint256 sellerPercentage) external onlyGasPayer initialized {
        require(_state == 2, "Not disputed");
        require(buyerPercentage + sellerPercentage == 100, "Percentages must sum to 100");
        
        _state = 4; // claimed (resolved)
        
        uint256 escrowAmount = AMOUNT - CREATOR_FEE;
        uint256 buyerAmount = (escrowAmount * buyerPercentage) / 100;
        uint256 sellerAmount = escrowAmount - buyerAmount; // Use subtraction to handle rounding
        
        // Transfer to buyer if their share > 0
        if (buyerAmount > 0) {
            require(
                USDC_TOKEN.transfer(BUYER, buyerAmount),
                "Buyer transfer failed"
            );
        }
        
        // Transfer to seller if their share > 0
        if (sellerAmount > 0) {
            require(
                USDC_TOKEN.transfer(SELLER, sellerAmount),
                "Seller transfer failed"
            );
        }
        
        emit DisputeResolved(buyerPercentage, sellerPercentage, block.timestamp);
        emit FundsClaimed(BUYER, buyerAmount, block.timestamp);
        if (sellerAmount > 0) {
            emit FundsClaimed(SELLER, sellerAmount, block.timestamp);
        }
    }
    
    function claimFunds() external onlySellerOrGasPayer initialized {
        require(_state == 1, "Not funded or already processed");
        require(block.timestamp >= EXPIRY_TIMESTAMP, "Not expired yet");
        
        _state = 4; // claimed
        
        uint256 escrowAmount = AMOUNT - CREATOR_FEE;
        require(
            USDC_TOKEN.transfer(SELLER, escrowAmount),
            "USDC transfer failed"
        );
        
        emit FundsClaimed(SELLER, escrowAmount, block.timestamp);
    }
    
    function getContractInfo() external view initialized returns (
        address _buyer,
        address _seller,
        uint256 _amount,
        uint256 _expiryTimestamp,
        string memory _description,
        uint8 _currentState,
        uint256 _currentTimestamp,
        uint256 _creatorFee
    ) {
        return (
            BUYER,
            SELLER,
            AMOUNT,
            EXPIRY_TIMESTAMP,
            DESCRIPTION,
            _state,
            block.timestamp,
            CREATOR_FEE
        );
    }
    
    function isExpired() external view initialized returns (bool) {
        return block.timestamp >= EXPIRY_TIMESTAMP;
    }
    
    function canClaim() external view initialized returns (bool) {
        return _state == 1 && block.timestamp >= EXPIRY_TIMESTAMP;
    }
    
    function canDispute() external view initialized returns (bool) {
        return _state == 1;
    }
    
    function isFunded() external view initialized returns (bool) {
        return _state >= 1;
    }
    
    function canDeposit() external view initialized returns (bool) {
        return _state == 0;
    }
    
    function isDisputed() external view initialized returns (bool) {
        return _state == 2;
    }
    
    function isClaimed() external view initialized returns (bool) {
        return _state == 4;
    }
}