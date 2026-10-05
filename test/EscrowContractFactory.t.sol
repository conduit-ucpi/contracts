// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {EscrowContractFactory} from "../src/EscrowContractFactory.sol";
import {EscrowContract} from "../src/EscrowContract.sol";

contract MockERC20 is Test {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    string public name = "Mock USDC";
    string public symbol = "MUSDC";
    uint8 public decimals = 6;
    uint256 public totalSupply = 1000000 * 10 ** 6;

    constructor() {
        balanceOf[msg.sender] = totalSupply;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");

        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

contract EscrowContractFactoryTest is Test {
    EscrowContractFactory public factory;
    MockERC20 public usdc;
    MockERC20 public dai;

    address public owner = address(0x1);
    address public buyer = address(0x2);
    address public seller = address(0x3);
    address public other = address(0x4);

    uint256 public constant AMOUNT = 1000 * 10 ** 6; // 1000 USDC
    uint256 public expiryTimestamp;
    string public description = "Test escrow transaction";

    event ContractCreated(
        address indexed contractAddress,
        address indexed buyer,
        address indexed seller,
        uint256 amount,
        uint256 expiryTimestamp,
        string description
    );

    function setUp() public {
        usdc = new MockERC20();
        dai = new MockERC20();
        EscrowContract implementation = new EscrowContract(address(0xDEFA17), bytes20(0));
        factory = new EscrowContractFactory(owner, address(implementation), address(0), address(0), bytes20(0)); // feeRecipient defaults to owner

        expiryTimestamp = block.timestamp + 7 days;

        usdc.mint(buyer, AMOUNT * 10);
        usdc.mint(owner, AMOUNT * 10);
        dai.mint(buyer, AMOUNT * 10);
        dai.mint(owner, AMOUNT * 10);

        vm.prank(buyer);
        usdc.approve(address(factory), AMOUNT * 10);

        vm.prank(buyer);
        dai.approve(address(factory), AMOUNT * 10);

        vm.prank(owner);
        usdc.approve(address(factory), AMOUNT * 10);

        vm.prank(owner);
        dai.approve(address(factory), AMOUNT * 10);
    }

    function testConstructorValidation() public {
        // Constructor should accept valid addresses without reverting
        EscrowContract impl = new EscrowContract(address(0xDEFA17), bytes20(0));
        EscrowContractFactory testFactory = new EscrowContractFactory(owner, address(impl), address(0), address(0), bytes20(0));
        assertEq(testFactory.OWNER(), owner);
        assertEq(testFactory.IMPLEMENTATION(), address(impl));
        assertEq(testFactory.FEE_RECIPIENT(), owner); // Should default to owner
    }

    function testSuccessfulDeployment() public view {
        assertEq(factory.OWNER(), owner);
        assertTrue(factory.IMPLEMENTATION() != address(0));
        assertEq(factory.FEE_RECIPIENT(), owner); // Should default to owner
    }

    function testCreateEscrowContract() public {
        // Gas-payer (owner) calls factory with buyer and seller addresses
        vm.prank(owner);
        address escrowAddress = factory.createEscrowContract(
            address(usdc), buyer, seller, AMOUNT, expiryTimestamp, description, owner, bytes32(uint256(63))
        );

        assertTrue(escrowAddress != address(0));

        EscrowContract escrow = EscrowContract(escrowAddress);
        assertEq(escrow.BUYER(), buyer); // buyer is the actual buyer
        assertEq(escrow.SELLER(), seller);
        assertEq(escrow.ARBITER(), owner); // owner (factory caller) is the arbiter
        assertEq(escrow.FEE_RECIPIENT(), owner); // owner is the fee recipient (default)
        assertEq(escrow.AMOUNT(), AMOUNT);
        assertEq(escrow.EXPIRY_TIMESTAMP(), expiryTimestamp);
        // Description no longer stored in contract (emitted in events only to save gas)

        // Contract starts unfunded - no USDC transferred yet
        assertEq(usdc.balanceOf(escrowAddress), 0);
        assertEq(usdc.balanceOf(buyer), AMOUNT * 10); // buyer's balance unchanged
    }

    function testCreateEscrowWithDifferentTokens() public {
        vm.startPrank(owner);

        // Create USDC escrow
        address usdcEscrow = factory.createEscrowContract(
            address(usdc), buyer, seller, AMOUNT, expiryTimestamp, "USDC escrow", owner, bytes32(uint256(62))
        );

        // Create DAI escrow
        address daiEscrow = factory.createEscrowContract(
            address(dai), buyer, seller, AMOUNT, expiryTimestamp, "DAI escrow", owner, bytes32(uint256(61))
        );

        assertTrue(usdcEscrow != daiEscrow);

        EscrowContract usdcContract = EscrowContract(usdcEscrow);
        EscrowContract daiContract = EscrowContract(daiEscrow);

        assertEq(address(usdcContract.tokenAddress()), address(usdc));
        assertEq(address(daiContract.tokenAddress()), address(dai));

        vm.stopPrank();
    }

    function testAnyoneCanCreateEscrow() public {
        // Test that non-owner addresses can create escrow contracts
        vm.prank(other);
        address contractAddress = factory.createEscrowContract(
            address(usdc), buyer, seller, AMOUNT, expiryTimestamp, description, owner, bytes32(uint256(60))
        );

        // Verify contract was created successfully
        assertTrue(contractAddress != address(0), "Contract should be created");
        EscrowContract escrow = EscrowContract(contractAddress);
        assertEq(address(escrow.BUYER()), buyer);
        assertEq(address(escrow.SELLER()), seller);
    }

    function testExplicitArbiter() public {
        address customArbiter = address(0xABCD);

        vm.prank(other);
        address escrowAddress = factory.createEscrowContract(
            address(usdc), buyer, seller, AMOUNT, expiryTimestamp, description, customArbiter, bytes32(uint256(59))
        );

        EscrowContract escrow = EscrowContract(escrowAddress);
        assertEq(escrow.ARBITER(), customArbiter, "Arbiter should be the explicit address");
    }

    function testCreateEscrowValidation() public {
        vm.startPrank(owner);

        vm.expectRevert(EscrowContractFactory.InvalidTokenAddress.selector);
        factory.createEscrowContract(
            address(0), buyer, seller, AMOUNT, expiryTimestamp, description, owner, bytes32(uint256(57))
        );

        vm.expectRevert(EscrowContractFactory.InvalidBuyerAddress.selector);
        factory.createEscrowContract(
            address(usdc), address(0), seller, AMOUNT, expiryTimestamp, description, owner, bytes32(uint256(56))
        );

        vm.expectRevert(EscrowContractFactory.InvalidSellerAddress.selector);
        factory.createEscrowContract(
            address(usdc), buyer, address(0), AMOUNT, expiryTimestamp, description, owner, bytes32(uint256(55))
        );

        // Test same buyer and seller
        vm.expectRevert(EscrowContractFactory.BuyerSellerMustBeDifferent.selector);
        factory.createEscrowContract(
            address(usdc), buyer, buyer, AMOUNT, expiryTimestamp, description, owner, bytes32(uint256(54))
        );

        vm.expectRevert(EscrowContractFactory.AmountMustBeGreaterThanZero.selector);
        factory.createEscrowContract(
            address(usdc), buyer, seller, 0, expiryTimestamp, description, owner, bytes32(uint256(53))
        );

        // Warp forward so block.timestamp > 1, then test with past timestamp
        vm.warp(block.timestamp + 100);

        vm.expectRevert(EscrowContractFactory.InvalidExpiryTimestamp.selector);
        factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            block.timestamp - 1, // This will be 100, which is less than current 101
            description,
            owner,
            bytes32(uint256(69))
        );

        // Test that amounts equal to minimum fee are rejected
        // For USDC (6 decimals), minimum fee is 300,000 (30% of 1,000,000)
        // So amount of exactly 300,000 should be rejected as it can't cover the fee
        vm.expectRevert(EscrowContractFactory.AmountTooSmallForMinFee.selector);
        factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            300000, // 0.3 USDC - exactly equal to minimum fee
            expiryTimestamp,
            description,
            owner,
            bytes32(uint256(52))
        );

        // Test with invalid parameters - zero addresses
        vm.expectRevert(EscrowContractFactory.InvalidBuyerAddress.selector);
        factory.createEscrowContract(
            address(usdc), address(0), seller, AMOUNT, expiryTimestamp, description, owner, bytes32(uint256(51))
        );

        vm.stopPrank();
    }

    function testContractCreatedEvent() public {
        vm.expectEmit(false, true, true, true); // Check all except first indexed param (address)
        emit ContractCreated(
            address(0), // We don't know the address beforehand
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            description
        );

        vm.prank(owner);
        address escrowAddress = factory.createEscrowContract(
            address(usdc), buyer, seller, AMOUNT, expiryTimestamp, description, owner, bytes32(uint256(50))
        );

        assertTrue(escrowAddress != address(0));
    }

    function testMultipleContracts() public {
        vm.startPrank(owner);

        string memory firstDesc = "First escrow";
        string memory secondDesc = "Second escrow";

        address escrow1 = factory.createEscrowContract(
            address(usdc), buyer, seller, AMOUNT, expiryTimestamp, firstDesc, owner, bytes32(uint256(49))
        );

        address escrow2 = factory.createEscrowContract(
            address(usdc), buyer, seller, AMOUNT * 2, expiryTimestamp + 1 days, secondDesc, owner, bytes32(uint256(48))
        );

        assertTrue(escrow1 != escrow2);
        assertTrue(escrow1 != address(0));
        assertTrue(escrow2 != address(0));

        EscrowContract contract1 = EscrowContract(escrow1);
        EscrowContract contract2 = EscrowContract(escrow2);

        assertEq(contract1.AMOUNT(), AMOUNT);
        assertEq(contract2.AMOUNT(), AMOUNT * 2);
        // Description no longer stored in contract (emitted in events only to save gas)

        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Counterfactual funding: money arrives BEFORE the escrow exists
    // ═══════════════════════════════════════════════════════════════════════════

    function testCreateAndActivateOnAnAddressFundedBeforeItExisted() public {
        bytes32 externalId = keccak256("pending-contract-1");
        address predicted =
            factory.getContractAddress(address(usdc), buyer, seller, AMOUNT, expiryTimestamp, owner, externalId);

        // Nothing is deployed there yet - it is empty space.
        assertEq(predicted.code.length, 0, "must not exist yet");

        // The payer sends to the bare address. This is a ledger update inside the TOKEN
        // contract: no code runs at `predicted`, nothing is triggered, nobody is notified.
        vm.prank(buyer);
        usdc.transfer(predicted, AMOUNT);
        assertEq(usdc.balanceOf(predicted), AMOUNT);
        assertEq(predicted.code.length, 0, "a transfer does not deploy anything");

        // Someone - anyone - then brings the escrow into existence on top of those funds.
        vm.prank(other);
        address deployed = factory.createAndActivate(
            address(usdc), buyer, seller, AMOUNT, expiryTimestamp, description, owner, externalId
        );

        assertEq(deployed, predicted, "deployed where the money already was");

        EscrowContract escrow = EscrowContract(deployed);
        assertTrue(escrow.isFunded(), "activated from the pre-existing balance");
        assertEq(escrow.BUYER(), buyer);
        assertEq(escrow.SELLER(), seller);
        assertEq(escrow.ARBITER(), owner);
        assertEq(escrow.AMOUNT(), AMOUNT);
        assertEq(escrow.EXPIRY_TIMESTAMP(), expiryTimestamp);
    }

    function testCreateAndActivateIsAllOrNothingWhenUnfunded() public {
        bytes32 externalId = keccak256("pending-contract-1");
        address predicted =
            factory.getContractAddress(address(usdc), buyer, seller, AMOUNT, expiryTimestamp, owner, externalId);

        // checkAndActivate reverts without the balance, and it is in the same transaction
        // as the deploy - so the whole thing rolls back rather than leaving a deployed but
        // unfunded escrow sitting at the predicted address.
        vm.prank(owner);
        vm.expectRevert(EscrowContract.InsufficientDirectPayment.selector);
        factory.createAndActivate(address(usdc), buyer, seller, AMOUNT, expiryTimestamp, description, owner, externalId);

        assertEq(predicted.code.length, 0, "nothing may be left behind");
    }

    function testCreateAndActivateSettlesAnInstantTransferStraightToSeller() public {
        bytes32 externalId = keccak256("instant");
        // expiryTimestamp == 0 is the instant-transfer branch: no escrow period, no dispute.
        address predicted = factory.getContractAddress(address(usdc), buyer, seller, AMOUNT, 0, owner, externalId);

        vm.prank(buyer);
        usdc.transfer(predicted, AMOUNT);

        uint256 sellerBefore = usdc.balanceOf(seller);

        vm.prank(other);
        address deployed =
            factory.createAndActivate(address(usdc), buyer, seller, AMOUNT, 0, description, owner, externalId);

        EscrowContract escrow = EscrowContract(deployed);
        assertGt(usdc.balanceOf(seller) - sellerBefore, 0, "seller paid immediately");
        assertEq(usdc.balanceOf(deployed), 0, "nothing retained");
        assertFalse(escrow.canDispute(), "an instant transfer has no dispute window");
    }

    /**
     * Money that arrives after the dispute window has already closed must still be
     * recoverable. Refusing the deploy would strand it permanently: nothing else can move
     * funds at an address that holds no code.
     *
     * The escrow therefore lands funded-and-expired - seller can claim, buyer cannot
     * dispute - which is the same bargain an instant transfer makes, except the buyer did
     * not choose it here.
     */
    function testLateFundingStillDeploysSoTheMoneyIsNotStranded() public {
        bytes32 externalId = keccak256("late");
        address predicted =
            factory.getContractAddress(address(usdc), buyer, seller, AMOUNT, expiryTimestamp, owner, externalId);

        vm.prank(buyer);
        usdc.transfer(predicted, AMOUNT);

        vm.warp(expiryTimestamp + 1);

        vm.prank(other);
        address deployed = factory.createAndActivate(
            address(usdc), buyer, seller, AMOUNT, expiryTimestamp, description, owner, externalId
        );
        assertEq(deployed, predicted);

        EscrowContract escrow = EscrowContract(deployed);
        assertTrue(escrow.isFunded(), "funded, not stranded");

        // The window is gone, so there is no dispute to be had...
        vm.prank(buyer);
        vm.expectRevert(EscrowContract.CannotDisputeAfterExpiry.selector);
        escrow.raiseDispute();

        // ...and the seller can take the money straight away.
        uint256 sellerBefore = usdc.balanceOf(seller);
        escrow.claimFunds();
        assertGt(usdc.balanceOf(seller) - sellerBefore, 0, "seller can claim immediately");
    }

    /// A fresh escrow whose window has already closed is a caller bug, and there is no
    /// stranded money to rescue - so the ordinary entry point still rejects it.
    function testCreateEscrowContractStillRejectsAPastExpiry() public {
        vm.warp(block.timestamp + 100);
        vm.prank(owner);
        vm.expectRevert(EscrowContractFactory.InvalidExpiryTimestamp.selector);
        factory.createEscrowContract(
            address(usdc), buyer, seller, AMOUNT, block.timestamp - 1, description, owner, keccak256("past")
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // The wallet that pays is not the wallet that holds the buyer's rights
    // ═══════════════════════════════════════════════════════════════════════════
    //
    // An ERC20 transfer is a balance entry inside the token contract, so an escrow has no way
    // of knowing who funded it and never asks. BUYER is fixed by the terms its address was
    // derived from, which is what lets a payment link be paid from any wallet at all - and
    // what means the dispute right and any refund stay with the named buyer rather than
    // following the money back to its source.

    /// Funds an escrow from `funder` and brings it into existence around them.
    function _fundedByStranger(address funder, uint256 sent) internal returns (EscrowContract) {
        bytes32 externalId = keccak256("stranger-funded");
        address predicted =
            factory.getContractAddress(address(usdc), buyer, seller, AMOUNT, expiryTimestamp, owner, externalId);

        usdc.mint(funder, sent);
        vm.prank(funder);
        usdc.transfer(predicted, sent);

        vm.prank(funder);
        return EscrowContract(
            factory.createAndActivate(
                address(usdc), buyer, seller, AMOUNT, expiryTimestamp, description, owner, externalId
            )
        );
    }

    function testAnyWalletMayFundAnEscrowWithoutBecomingItsBuyer() public {
        address stranger = makeAddr("stranger");
        EscrowContract escrow = _fundedByStranger(stranger, AMOUNT);

        assertTrue(escrow.isFunded(), "a stranger's money funds it just the same");
        assertEq(escrow.BUYER(), buyer, "the named buyer is unchanged by who paid");
        assertTrue(escrow.BUYER() != stranger, "funding confers nothing");
    }

    function testOnlyTheNamedBuyerMayDispute() public {
        address stranger = makeAddr("stranger");
        EscrowContract escrow = _fundedByStranger(stranger, AMOUNT);

        // Paying for it does not buy the right to dispute it.
        vm.prank(stranger);
        vm.expectRevert(EscrowContract.OnlyBuyer.selector);
        escrow.raiseDispute();

        vm.prank(buyer);
        escrow.raiseDispute();
        assertTrue(escrow.hasActiveDispute(), "the named buyer may");
    }

    /**
     * The consequence worth knowing about: a refund does not go back where the money came
     * from. It goes to BUYER, which is whoever was named when the address was derived.
     */
    function testARefundReturnsToTheNamedBuyerNotTheFunder() public {
        address stranger = makeAddr("stranger");
        EscrowContract escrow = _fundedByStranger(stranger, AMOUNT);
        uint256 escrowAmount = escrow.payoutAmount();

        vm.prank(buyer);
        escrow.raiseDispute();

        uint256 buyerBefore = usdc.balanceOf(buyer);

        // Two matching votes settle it: the buyer's and the arbiter's.
        vm.prank(buyer);
        escrow.submitResolutionVote(100);
        vm.prank(owner);
        escrow.submitResolutionVote(100);

        assertEq(usdc.balanceOf(buyer) - buyerBefore, escrowAmount, "the refund went to the named buyer");
        assertEq(usdc.balanceOf(stranger), 0, "and not to whoever paid");
    }

    /// Short of the amount, there is nothing to activate - and the money waits rather than
    /// being lost. Any later transfer to the same address completes it.
    function testAnUnderfundedEscrowCannotActivateUntilToppedUp() public {
        bytes32 externalId = keccak256("short");
        address predicted =
            factory.getContractAddress(address(usdc), buyer, seller, AMOUNT, expiryTimestamp, owner, externalId);

        vm.prank(buyer);
        usdc.transfer(predicted, AMOUNT - 1);

        vm.prank(owner);
        vm.expectRevert(EscrowContract.InsufficientDirectPayment.selector);
        factory.createAndActivate(address(usdc), buyer, seller, AMOUNT, expiryTimestamp, description, owner, externalId);

        // The shortfall can come from anywhere too.
        address stranger = makeAddr("stranger");
        usdc.mint(stranger, 1);
        vm.prank(stranger);
        usdc.transfer(predicted, 1);

        vm.prank(owner);
        address deployed = factory.createAndActivate(
            address(usdc), buyer, seller, AMOUNT, expiryTimestamp, description, owner, externalId
        );
        assertTrue(EscrowContract(deployed).isFunded(), "topped up, it activates");
    }

    /// An overpayment is recoverable, but only once the escrow has settled - and it too goes
    /// to the named buyer rather than back to the wallet that sent it.
    function testAnOverpaymentReturnsToTheNamedBuyerOnceClaimed() public {
        address stranger = makeAddr("stranger");
        uint256 extra = 1_000_000;
        EscrowContract escrow = _fundedByStranger(stranger, AMOUNT + extra);

        // Still held while the escrow is live.
        vm.expectRevert(EscrowContract.CannotSweepEscrowToken.selector);
        escrow.sweepToken(address(usdc));

        vm.warp(expiryTimestamp + 1);
        escrow.claimFunds();

        uint256 buyerBefore = usdc.balanceOf(buyer);
        escrow.sweepToken(address(usdc));
        assertEq(usdc.balanceOf(buyer) - buyerBefore, extra, "the overpayment returns to the named buyer");
        assertEq(usdc.balanceOf(stranger), 0, "not to whoever sent it");
    }

    function testPredictedAddressMatchesDeployment() public {
        vm.startPrank(owner);

        bytes32 externalId = keccak256("pending-contract-1");

        address predicted =
            factory.getContractAddress(address(usdc), buyer, seller, AMOUNT, expiryTimestamp, owner, externalId);

        address deployed = factory.createEscrowContract(
            address(usdc), buyer, seller, AMOUNT, expiryTimestamp, description, owner, externalId
        );

        // The whole point: the address was knowable before anything was on-chain.
        assertEq(deployed, predicted);

        vm.stopPrank();
    }

    function testExternalIdSeparatesOtherwiseIdenticalEscrows() public {
        vm.startPrank(owner);

        address a = factory.createEscrowContract(
            address(usdc), buyer, seller, AMOUNT, expiryTimestamp, description, owner, keccak256("pending-a")
        );
        address b = factory.createEscrowContract(
            address(usdc), buyer, seller, AMOUNT, expiryTimestamp, description, owner, keccak256("pending-b")
        );

        // Same terms, same block - previously separated by block.timestamp, now by externalId.
        assertTrue(a != b);

        vm.stopPrank();
    }

    function testRedeployingTheSameEscrowReverts() public {
        vm.startPrank(owner);

        bytes32 externalId = keccak256("pending-contract-1");
        factory.createEscrowContract(
            address(usdc), buyer, seller, AMOUNT, expiryTimestamp, description, owner, externalId
        );

        // Clones.cloneDeterministic reverts when the address is already occupied, so a
        // predicted address cannot be quietly taken over after the fact.
        vm.expectRevert();
        factory.createEscrowContract(
            address(usdc), buyer, seller, AMOUNT, expiryTimestamp, description, owner, externalId
        );

        vm.stopPrank();
    }

    /**
     * Every initialize parameter must be in the salt, or an attacker could front-run the
     * deploy of a known address and choose that parameter themselves. Changing any one of
     * them must move the address.
     */
    function testEveryParameterChangesThePredictedAddress() public {
        bytes32 externalId = keccak256("pending-contract-1");
        address base =
            factory.getContractAddress(address(usdc), buyer, seller, AMOUNT, expiryTimestamp, owner, externalId);

        assertTrue(
            base != factory.getContractAddress(address(dai), buyer, seller, AMOUNT, expiryTimestamp, owner, externalId),
            "token must change the address"
        );
        assertTrue(
            base
                != factory.getContractAddress(address(usdc), other, seller, AMOUNT, expiryTimestamp, owner, externalId),
            "buyer must change the address"
        );
        assertTrue(
            base != factory.getContractAddress(address(usdc), buyer, other, AMOUNT, expiryTimestamp, owner, externalId),
            "seller must change the address"
        );
        assertTrue(
            base
                != factory.getContractAddress(
                    address(usdc), buyer, seller, AMOUNT + 1, expiryTimestamp, owner, externalId
                ),
            "amount must change the address"
        );
        assertTrue(
            base
                != factory.getContractAddress(
                    address(usdc), buyer, seller, AMOUNT, expiryTimestamp + 1, owner, externalId
                ),
            "expiry must change the address"
        );
        assertTrue(
            base
                != factory.getContractAddress(address(usdc), buyer, seller, AMOUNT, expiryTimestamp, other, externalId),
            "arbiter must change the address"
        );
        assertTrue(
            base
                != factory.getContractAddress(
                    address(usdc), buyer, seller, AMOUNT, expiryTimestamp, owner, keccak256("other")
                ),
            "externalId must change the address"
        );
    }

    function testArbiterMustBeStatedExplicitly() public {
        vm.prank(owner);
        // address(0) used to mean "default to msg.sender", which made the address
        // unpredictable to everyone but the caller. It is now rejected.
        vm.expectRevert(EscrowContractFactory.InvalidArbiterAddress.selector);
        factory.createEscrowContract(
            address(usdc), buyer, seller, AMOUNT, expiryTimestamp, description, address(0), keccak256("x")
        );
    }

    function testNoFeeThreshold() public {
        vm.startPrank(owner);

        // Test amount at no-fee threshold (1/1000 of one unit)
        // For USDC (6 decimals): 1 unit = 1,000,000, so threshold = 1,000
        uint256 noFeeAmount = 1000; // 1000 microUSDC = 0.001 USDC

        address escrowAddress = factory.createEscrowContract(
            address(usdc), buyer, seller, noFeeAmount, expiryTimestamp, "No fee test", owner, bytes32(uint256(45))
        );

        EscrowContract escrow = EscrowContract(escrowAddress);
        assertEq(escrow.CREATOR_FEE(), 0); // Should be 0 fee

        // Test amount just above threshold - should have minimum fee
        // For USDC minimum fee is 300,000, so amount must be > 300,000
        uint256 smallFeeAmount = 400000; // 0.4 USDC - above threshold and minimum fee

        address escrowAddress2 = factory.createEscrowContract(
            address(usdc), buyer, seller, smallFeeAmount, expiryTimestamp, "Small fee test", owner, bytes32(uint256(44))
        );

        EscrowContract escrow2 = EscrowContract(escrowAddress2);
        uint256 expectedMinFee = 300000; // 30% of 1,000,000
        assertEq(escrow2.CREATOR_FEE(), expectedMinFee); // Should have minimum fee

        vm.stopPrank();
    }

    function testAmountTooSmallForMinFee() public {
        vm.prank(owner);

        // Test amount that's above no-fee threshold but below minimum fee
        // For USDC: no-fee threshold = 1,000, minimum fee = 300,000
        // So amounts between 1,001 and 300,000 should be rejected
        uint256 tooSmallAmount = 200000; // 0.2 USDC - above threshold but can't cover 0.3 USDC min fee

        vm.expectRevert(EscrowContractFactory.AmountTooSmallForMinFee.selector);
        factory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            tooSmallAmount,
            expiryTimestamp,
            "Too small amount test",
            owner,
            bytes32(uint256(43))
        );
    }

    function testReentrancyProtection() public {
        vm.prank(owner);
        address escrowAddress = factory.createEscrowContract(
            address(usdc), buyer, seller, AMOUNT, expiryTimestamp, description, owner, bytes32(uint256(42))
        );

        assertTrue(escrowAddress != address(0));
    }

    function testInsufficientBalance() public {
        // Create a new buyer with no USDC balance
        address poorBuyer = address(0x5);

        // Factory no longer transfers funds, so this should succeed
        vm.prank(owner);
        address escrowAddress = factory.createEscrowContract(
            address(usdc), poorBuyer, seller, AMOUNT, expiryTimestamp, description, owner, bytes32(uint256(41))
        );

        assertTrue(escrowAddress != address(0));

        // But depositFunds should fail for poor buyer
        EscrowContract escrow = EscrowContract(escrowAddress);
        vm.prank(poorBuyer);
        vm.expectRevert("Insufficient balance");
        escrow.depositFunds();
    }

    function testInsufficientAllowance() public {
        // Factory no longer transfers funds, so creation should succeed
        vm.prank(owner);
        address escrowAddress = factory.createEscrowContract(
            address(usdc), buyer, seller, AMOUNT, expiryTimestamp, description, owner, bytes32(uint256(40))
        );

        assertTrue(escrowAddress != address(0));

        // But depositFunds should fail with insufficient allowance
        EscrowContract escrow = EscrowContract(escrowAddress);

        // Reduce buyer's allowance to escrow contract
        vm.prank(buyer);
        usdc.approve(address(escrow), AMOUNT - 1);

        vm.prank(buyer);
        vm.expectRevert("Insufficient allowance");
        escrow.depositFunds();
    }

    function testCustomFeeRecipientInFactory() public {
        // Test factory with custom fee recipient address
        address customFeeRecipient = address(0x999);

        EscrowContract impl = new EscrowContract(address(0xDEFA17), bytes20(0));
        EscrowContractFactory customFactory = new EscrowContractFactory(owner, address(impl), customFeeRecipient, address(0), bytes20(0));

        assertEq(customFactory.OWNER(), owner);
        assertEq(customFactory.FEE_RECIPIENT(), customFeeRecipient); // Should use custom fee recipient

        // Create escrow contract and verify it inherits custom fee recipient
        vm.prank(owner);
        address escrowAddress = customFactory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            "Custom fee recipient test",
            owner,
            bytes32(uint256(39))
        );

        EscrowContract escrow = EscrowContract(escrowAddress);
        assertEq(escrow.FEE_RECIPIENT(), customFeeRecipient); // Escrow should inherit custom fee recipient
        assertEq(escrow.BUYER(), buyer);
        assertEq(escrow.SELLER(), seller);
        assertEq(escrow.ARBITER(), owner); // ARBITER is the factory caller (owner)
    }

    function testDefaultFeeRecipientWhenAddressZero() public {
        // Test that address(0) defaults to OWNER
        EscrowContract impl = new EscrowContract(address(0xDEFA17), bytes20(0));
        EscrowContractFactory defaultFactory = new EscrowContractFactory(owner, address(impl), address(0), address(0), bytes20(0));

        assertEq(defaultFactory.FEE_RECIPIENT(), owner); // Should default to owner

        // Create escrow contract and verify it uses owner as fee recipient
        vm.prank(owner);
        address escrowAddress = defaultFactory.createEscrowContract(
            address(usdc),
            buyer,
            seller,
            AMOUNT,
            expiryTimestamp,
            "Default fee recipient test",
            owner,
            bytes32(uint256(38))
        );

        EscrowContract escrow = EscrowContract(escrowAddress);
        assertEq(escrow.FEE_RECIPIENT(), owner); // Escrow should use owner as fee recipient
    }

    function testAllEscrowsInheritSameFeeRecipient() public {
        // Test that all escrows from same factory inherit same fee recipient
        address customFeeRecipient = address(0x888);

        EscrowContract impl = new EscrowContract(address(0xDEFA17), bytes20(0));
        EscrowContractFactory customFactory = new EscrowContractFactory(owner, address(impl), customFeeRecipient, address(0), bytes20(0));

        vm.startPrank(owner);

        // Create multiple escrow contracts
        address escrow1 = customFactory.createEscrowContract(
            address(usdc), buyer, seller, AMOUNT, expiryTimestamp, "First escrow", owner, bytes32(uint256(37))
        );

        address escrow2 = customFactory.createEscrowContract(
            address(usdc),
            address(0x7),
            address(0x8),
            AMOUNT * 2,
            expiryTimestamp + 1 days,
            "Second escrow",
            owner,
            bytes32(uint256(36))
        );

        vm.stopPrank();

        // Both should have same fee recipient
        assertEq(EscrowContract(escrow1).FEE_RECIPIENT(), customFeeRecipient);
        assertEq(EscrowContract(escrow2).FEE_RECIPIENT(), customFeeRecipient);
    }

    function testFeeRecipientReceivesFee() public {
        // Test that custom fee recipient actually receives the fee
        address customFeeRecipient = address(0x777);

        EscrowContract impl = new EscrowContract(address(0xDEFA17), bytes20(0));
        EscrowContractFactory customFactory = new EscrowContractFactory(owner, address(impl), customFeeRecipient, address(0), bytes20(0));

        vm.prank(owner);
        address escrowAddress = customFactory.createEscrowContract(
            address(usdc), buyer, seller, AMOUNT, expiryTimestamp, "Fee test", owner, bytes32(uint256(35))
        );

        EscrowContract escrow = EscrowContract(escrowAddress);
        uint256 expectedFee = escrow.CREATOR_FEE();

        // Approve escrow to spend buyer's tokens
        vm.prank(buyer);
        usdc.approve(escrowAddress, AMOUNT);

        uint256 feeRecipientBalanceBefore = usdc.balanceOf(customFeeRecipient);

        // Deposit funds as buyer
        vm.prank(buyer);
        escrow.depositFunds();

        uint256 feeRecipientBalanceAfter = usdc.balanceOf(customFeeRecipient);

        // Verify fee recipient received the fee
        assertEq(feeRecipientBalanceAfter - feeRecipientBalanceBefore, expectedFee);
    }
}
