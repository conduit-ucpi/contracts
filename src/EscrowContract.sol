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
    
    uint8 private _state; // 0=unfunded, 1=funded, 2=disputed, 3=resolved, 4=claimed
    address private _trustedForwarderOverride;
    
    event FundsDeposited(address buyer, uint256 amount, uint256 timestamp);
    event DisputeRaised(uint256 timestamp);
    event DisputeResolved(address recipient, uint256 timestamp);
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
        address _trustedForwarder
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
        _state = 0; // Set to unfunded state
    }
    
    function depositFunds() external onlyBuyer initialized {
        require(_state == 0, "Already funded or claimed");
        
        _state = 1; // funded
        
        require(
            USDC_TOKEN.transferFrom(_msgSender(), address(this), AMOUNT),
            "USDC transfer failed"
        );
        
        emit FundsDeposited(_msgSender(), AMOUNT, block.timestamp);
    }
    
    function raiseDispute() external onlyBuyer initialized {
        require(_state == 1, "Not funded or already processed");
        
        _state = 2; // disputed
        emit DisputeRaised(block.timestamp);
    }
    
    function resolveDispute(address recipient) external onlyGasPayer initialized {
        require(_state == 2, "Not disputed");
        require(recipient == BUYER || recipient == SELLER, "Invalid recipient");
        
        _state = 4; // claimed (resolved)
        
        require(
            USDC_TOKEN.transfer(recipient, AMOUNT),
            "USDC transfer failed"
        );
        
        emit DisputeResolved(recipient, block.timestamp);
        emit FundsClaimed(recipient, AMOUNT, block.timestamp);
    }
    
    function claimFunds() external onlySellerOrGasPayer initialized {
        require(_state == 1, "Not funded or already processed");
        require(block.timestamp >= EXPIRY_TIMESTAMP, "Not expired yet");
        
        _state = 4; // claimed
        
        require(
            USDC_TOKEN.transfer(SELLER, AMOUNT),
            "USDC transfer failed"
        );
        
        emit FundsClaimed(SELLER, AMOUNT, block.timestamp);
    }
    
    function getContractInfo() external view initialized returns (
        address _buyer,
        address _seller,
        uint256 _amount,
        uint256 _expiryTimestamp,
        string memory _description,
        uint8 _currentState,
        uint256 _currentTimestamp
    ) {
        return (
            BUYER,
            SELLER,
            AMOUNT,
            EXPIRY_TIMESTAMP,
            DESCRIPTION,
            _state,
            block.timestamp
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