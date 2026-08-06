// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {EscrowContract} from "../src/EscrowContract.sol";
import {EscrowContractFactory} from "../src/EscrowContractFactory.sol";
import {MarketplaceEscrow} from "../src/MarketplaceEscrow.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    string public name = "Mock USDC";
    string public symbol = "MUSDC";
    uint8 public decimals = 6;
    uint256 public totalSupply;

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "balance");
        require(allowance[from][msg.sender] >= amount, "allowance");
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

/// Delivers 1% less than requested, to prove the balance-delta guard rejects it.
contract FeeOnTransferERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint8 public decimals = 6;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        uint256 delivered = amount - (amount / 100);
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += delivered;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "allowance");
        allowance[from][msg.sender] -= amount;
        uint256 delivered = amount - (amount / 100);
        balanceOf[from] -= amount;
        balanceOf[to] += delivered;
        return true;
    }
}

/**
 * §14.2 — MarketplaceEscrow unit tests.
 *
 * Integration runs against REAL clones of the phase-1 implementation throughout: the
 * codehash gate makes mocks useless by design, which is the point of the gate.
 */
contract MarketplaceEscrowTest is Test {
    EscrowContract internal implementation;
    EscrowContractFactory internal factory;
    MarketplaceEscrow internal market;
    MockERC20 internal usdc;

    address internal defaultArbiter = makeAddr("defaultArbiterSafe");
    address internal owner = makeAddr("marketplaceOwner");
    address internal platform = makeAddr("platform");
    address internal buyer = makeAddr("buyer");
    address internal seller = makeAddr("seller");
    address internal arbiter = makeAddr("arbiter");
    address internal lp = makeAddr("lp");
    address internal lp2 = makeAddr("lp2");
    address internal outsider = makeAddr("outsider");

    uint256 internal constant AMOUNT = 10_000 * 1e6;
    uint256 internal constant FEE_BPS = 50; // 0.5%
    uint256 internal constant MIN_OFFER_BPS = 1000; // 10%
    uint256 internal constant DEFAULT_DURATION = 24 hours;

    uint256 internal expiry;

    function setUp() public {
        usdc = new MockERC20();
        implementation = new EscrowContract(defaultArbiter);
        factory = new EscrowContractFactory(platform, address(implementation), platform);
        market = new MarketplaceEscrow(address(implementation), FEE_BPS, MIN_OFFER_BPS, DEFAULT_DURATION, owner);
        expiry = block.timestamp + 30 days;
    }

    // ───────────────────────────────────────────────────────────────────────────
    // Helpers
    // ───────────────────────────────────────────────────────────────────────────

    function _createFunded() internal returns (EscrowContract escrow) {
        vm.warp(block.timestamp + 1); // keep the factory's clone salt unique
        vm.prank(platform);
        address addr = factory.createEscrowContract(address(usdc), buyer, seller, AMOUNT, expiry, "test", arbiter);
        escrow = EscrowContract(addr);

        usdc.mint(buyer, AMOUNT);
        vm.prank(buyer);
        usdc.approve(addr, AMOUNT);
        vm.prank(buyer);
        escrow.depositFunds();
    }

    function _offer(EscrowContract escrow, address who, uint256 amount, uint256 holdback) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(market), amount);
        vm.prank(who);
        market.createOffer(address(escrow), amount, holdback, 0);
    }

    function _accept(EscrowContract escrow, address who) internal {
        address currentSeller = escrow.SELLER();
        vm.prank(currentSeller);
        escrow.approveRecipientTransfer(address(market), who);
        vm.prank(currentSeller);
        market.acceptOffer(address(escrow), who);
    }

    function _payout(EscrowContract escrow) internal view returns (uint256) {
        return AMOUNT - escrow.CREATOR_FEE();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // createOffer — the codehash gate
    // ═══════════════════════════════════════════════════════════════════════════

    function testCreate_RejectsEOA() public {
        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(MarketplaceEscrow.UntrustedEscrow.selector, outsider));
        market.createOffer(outsider, 1000e6, 0, 0);
    }

    function testCreate_RejectsRawImplementation() public {
        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(MarketplaceEscrow.UntrustedEscrow.selector, address(implementation)));
        market.createOffer(address(implementation), 1000e6, 0, 0);
    }

    function testCreate_RejectsWrongImplementationClone() public {
        EscrowContract otherImpl = new EscrowContract(defaultArbiter);
        address rogue = Clones.clone(address(otherImpl));

        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(MarketplaceEscrow.UntrustedEscrow.selector, rogue));
        market.createOffer(rogue, 1000e6, 0, 0);
    }

    /// A DIRECT clone of the trusted implementation IS accepted — the gate proves code, not
    /// honest parties. This is §8.1a's premise and must be true.
    function testCreate_AcceptsDirectCloneOfTrustedImplementation() public {
        address clone = Clones.clone(address(implementation));
        assertTrue(market.isTrustedEscrow(clone));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // createOffer — gates
    // ═══════════════════════════════════════════════════════════════════════════

    function testCreate_HappyPathBooksEverything() public {
        EscrowContract escrow = _createFunded();
        uint256 amount = 9_000e6;
        uint256 holdback = 500e6;

        _offer(escrow, lp, amount, holdback);

        MarketplaceEscrow.Offer memory o = market.getOffer(address(escrow), lp);
        uint256 expectedFee = (amount * FEE_BPS) / 10000;

        assertEq(uint8(o.status), uint8(MarketplaceEscrow.OfferStatus.OPEN));
        assertEq(o.seller, seller);
        assertEq(o.lp, lp);
        assertEq(o.token, address(usdc));
        assertEq(o.offerAmount, amount);
        assertEq(o.fee, expectedFee);
        assertEq(o.holdback, holdback);
        assertEq(o.netAmount, amount - expectedFee - holdback);
        assertEq(o.offerExpiry, block.timestamp + DEFAULT_DURATION);
        assertEq(market.totalDeposits(address(usdc)), amount);
        assertEq(usdc.balanceOf(address(market)), amount);
    }

    function testCreate_SlotOccupied() public {
        EscrowContract escrow = _createFunded();
        _offer(escrow, lp, 5_000e6, 0);

        usdc.mint(lp, 5_000e6);
        vm.prank(lp);
        usdc.approve(address(market), 5_000e6);
        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(MarketplaceEscrow.OfferSlotOccupied.selector, address(escrow), lp));
        market.createOffer(address(escrow), 5_000e6, 0, 0);
    }

    function testCreate_RejectsInstantEscrow() public {
        vm.prank(platform);
        address addr = factory.createEscrowContract(address(usdc), buyer, seller, AMOUNT, 0, "instant", arbiter);

        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(MarketplaceEscrow.InstantEscrowNotSupported.selector, addr));
        market.createOffer(addr, 5_000e6, 0, 0);
    }

    function testCreate_RejectsUnfunded() public {
        vm.prank(platform);
        address addr = factory.createEscrowContract(address(usdc), buyer, seller, AMOUNT, expiry, "unfunded", arbiter);

        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(MarketplaceEscrow.EscrowNotSellable.selector, addr));
        market.createOffer(addr, 5_000e6, 0, 0);
    }

    function testCreate_RejectsDisputed() public {
        EscrowContract escrow = _createFunded();
        vm.prank(buyer);
        escrow.raiseDispute();

        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(MarketplaceEscrow.EscrowNotSellable.selector, address(escrow)));
        market.createOffer(address(escrow), 5_000e6, 0, 0);
    }

    function testCreate_RejectsClaimed() public {
        EscrowContract escrow = _createFunded();
        vm.warp(expiry + 1);
        escrow.claimFunds();

        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(MarketplaceEscrow.EscrowNotSellable.selector, address(escrow)));
        market.createOffer(address(escrow), 5_000e6, 0, 0);
    }

    function testCreate_RejectsExpiryBeyondMaturity() public {
        EscrowContract escrow = _createFunded();
        uint256 tooLong = expiry - block.timestamp + 1;

        usdc.mint(lp, 5_000e6);
        vm.prank(lp);
        usdc.approve(address(market), 5_000e6);
        vm.prank(lp);
        vm.expectRevert(
            abi.encodeWithSelector(
                MarketplaceEscrow.OfferExpiryExceedsEscrowMaturity.selector, block.timestamp + tooLong, expiry
            )
        );
        market.createOffer(address(escrow), 5_000e6, 0, tooLong);
    }

    function testCreate_RejectsEscrowParties() public {
        EscrowContract escrow = _createFunded();

        address[3] memory parties = [seller, buyer, arbiter];
        for (uint256 i = 0; i < parties.length; i++) {
            usdc.mint(parties[i], 5_000e6);
            vm.prank(parties[i]);
            usdc.approve(address(market), 5_000e6);
            vm.prank(parties[i]);
            vm.expectRevert(abi.encodeWithSelector(MarketplaceEscrow.LpCannotBeEscrowParty.selector, parties[i]));
            market.createOffer(address(escrow), 5_000e6, 0, 0);
        }
    }

    function testCreate_EnforcesMinimumOffer() public {
        EscrowContract escrow = _createFunded();
        uint256 minimum = (_payout(escrow) * MIN_OFFER_BPS) / 10000;

        usdc.mint(lp, minimum);
        vm.prank(lp);
        usdc.approve(address(market), minimum);
        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(MarketplaceEscrow.OfferBelowMinimum.selector, minimum - 1, minimum));
        market.createOffer(address(escrow), minimum - 1, 0, 0);

        // Exactly at the floor is fine.
        _offer(escrow, lp, minimum, 0);
        assertEq(market.totalDeposits(address(usdc)), minimum);
    }

    /// The dust edge: the minimum is never zero, even at minOfferBps == 0.
    function testCreate_MinimumNeverZero() public {
        vm.prank(owner);
        market.setMinOfferBps(0);

        EscrowContract escrow = _createFunded();
        assertEq(market.minimumOffer(address(escrow)), 1, "floor must clamp up to 1");

        usdc.mint(lp, 1);
        vm.prank(lp);
        usdc.approve(address(market), 1);
        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(MarketplaceEscrow.OfferBelowMinimum.selector, 0, 1));
        market.createOffer(address(escrow), 0, 0, 0);
    }

    function testCreate_RejectsHoldbackExceedingOffer() public {
        EscrowContract escrow = _createFunded();
        uint256 amount = 5_000e6;
        uint256 fee = (amount * FEE_BPS) / 10000;

        usdc.mint(lp, amount);
        vm.prank(lp);
        usdc.approve(address(market), amount);
        vm.prank(lp);
        vm.expectRevert(
            abi.encodeWithSelector(MarketplaceEscrow.HoldbackExceedsOffer.selector, amount - fee + 1, fee, amount)
        );
        market.createOffer(address(escrow), amount, amount - fee + 1, 0);
    }

    function testCreate_RejectsHoldbackOnResale() public {
        EscrowContract escrow = _createFunded();
        _offer(escrow, lp, 9_000e6, 0);
        _accept(escrow, lp);

        assertTrue(market.hasBeenSold(address(escrow)));

        usdc.mint(lp2, 8_000e6);
        vm.prank(lp2);
        usdc.approve(address(market), 8_000e6);
        vm.prank(lp2);
        vm.expectRevert(abi.encodeWithSelector(MarketplaceEscrow.HoldbackOnResale.selector, address(escrow)));
        market.createOffer(address(escrow), 8_000e6, 100e6, 0);

        // A zero-holdback resale offer is fine.
        _offer(escrow, lp2, 8_000e6, 0);
    }

    function testCreate_RejectsFeeOnTransferToken() public {
        FeeOnTransferERC20 fot = new FeeOnTransferERC20();

        vm.prank(platform);
        address addr = factory.createEscrowContract(address(fot), buyer, seller, AMOUNT, expiry, "fot", arbiter);
        EscrowContract escrow = EscrowContract(addr);

        // Fund it by direct transfer so the escrow's own guard is bypassed.
        fot.mint(address(escrow), AMOUNT * 2);
        escrow.checkAndActivate();

        fot.mint(lp, 5_000e6);
        vm.prank(lp);
        fot.approve(address(market), 5_000e6);
        vm.prank(lp);
        vm.expectRevert(MarketplaceEscrow.TransferAmountMismatch.selector);
        market.createOffer(addr, 5_000e6, 0, 0);
    }

    function testCreate_RevertsWhenPaused() public {
        EscrowContract escrow = _createFunded();
        vm.prank(owner);
        market.pause();

        usdc.mint(lp, 5_000e6);
        vm.prank(lp);
        usdc.approve(address(market), 5_000e6);
        vm.prank(lp);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        market.createOffer(address(escrow), 5_000e6, 0, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // acceptOffer
    // ═══════════════════════════════════════════════════════════════════════════

    function testAccept_AtomicSwapPaysSellerNet() public {
        EscrowContract escrow = _createFunded();
        uint256 amount = 9_000e6;
        uint256 holdback = 400e6;
        _offer(escrow, lp, amount, holdback);

        uint256 fee = (amount * FEE_BPS) / 10000;
        uint256 net = amount - fee - holdback;
        uint256 sellerBefore = usdc.balanceOf(seller);

        _accept(escrow, lp);

        assertEq(escrow.SELLER(), lp, "role must have moved to the LP");
        assertEq(usdc.balanceOf(seller), sellerBefore + net, "seller receives amount - fee - holdback");
        assertEq(market.accruedFees(address(usdc)), fee);
        assertEq(market.totalDeposits(address(usdc)), 0);
        assertEq(market.totalHoldbacks(address(usdc)), holdback);
        assertTrue(market.hasBeenSold(address(escrow)));

        // The slot is freed, not marked COMPLETED.
        MarketplaceEscrow.Offer memory o = market.getOffer(address(escrow), lp);
        assertEq(uint8(o.status), uint8(MarketplaceEscrow.OfferStatus.NONE));

        // The holdback is recorded against the ORIGINAL seller as funder.
        (address hToken, address hFunder, uint256 hAmount) = market.holdbacks(address(escrow));
        assertEq(hToken, address(usdc));
        assertEq(hFunder, seller);
        assertEq(hAmount, holdback);

        // And the marketplace never held the role.
        assertTrue(escrow.SELLER() != address(market));
    }

    function testAccept_RevertsWithoutApproval() public {
        EscrowContract escrow = _createFunded();
        _offer(escrow, lp, 9_000e6, 0);

        vm.prank(seller);
        vm.expectRevert(EscrowContract.NotApprovedOperator.selector);
        market.acceptOffer(address(escrow), lp);
    }

    function testAccept_RevertsOnExpiredApproval() public {
        EscrowContract escrow = _createFunded();
        _offer(escrow, lp, 9_000e6, 0);

        vm.prank(seller);
        escrow.approveRecipientTransfer(address(market), lp);

        vm.warp(block.timestamp + 6 minutes); // past RECIPIENT_APPROVAL_TTL
        vm.prank(seller);
        vm.expectRevert(EscrowContract.RecipientApprovalExpired.selector);
        market.acceptOffer(address(escrow), lp);
    }

    function testAccept_RevertsWhenApprovalBoundToDifferentLp() public {
        EscrowContract escrow = _createFunded();
        _offer(escrow, lp, 9_000e6, 0);
        _offer(escrow, lp2, 8_000e6, 0);

        vm.prank(seller);
        escrow.approveRecipientTransfer(address(market), lp2); // bound to lp2

        vm.prank(seller);
        vm.expectRevert(EscrowContract.ApprovedTargetMismatch.selector);
        market.acceptOffer(address(escrow), lp); // but accepting lp's offer
    }

    function testAccept_OnlyCurrentRecipient() public {
        EscrowContract escrow = _createFunded();
        _offer(escrow, lp, 9_000e6, 0);

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(MarketplaceEscrow.NotEscrowRecipient.selector, outsider));
        market.acceptOffer(address(escrow), lp);
    }

    function testAccept_RevertsOnStaleOffer() public {
        EscrowContract escrow = _createFunded();
        _offer(escrow, lp, 9_000e6, 0);

        // Seller rotates their wallet — every existing offer is now stale.
        vm.prank(seller);
        escrow.changeRecipient(outsider);

        vm.prank(outsider);
        escrow.approveRecipientTransfer(address(market), lp);
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(MarketplaceEscrow.OfferStale.selector, address(escrow), lp));
        market.acceptOffer(address(escrow), lp);
    }

    function testAccept_RevertsWhenExpired() public {
        EscrowContract escrow = _createFunded();
        _offer(escrow, lp, 9_000e6, 0);

        vm.warp(block.timestamp + DEFAULT_DURATION + 1);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(MarketplaceEscrow.OfferExpired.selector, address(escrow), lp));
        market.acceptOffer(address(escrow), lp);
    }

    function testAccept_SecondAcceptFails() public {
        EscrowContract escrow = _createFunded();
        _offer(escrow, lp, 9_000e6, 0);
        _accept(escrow, lp);

        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(MarketplaceEscrow.OfferNotOpen.selector, address(escrow), lp));
        market.acceptOffer(address(escrow), lp);
    }

    function testAccept_CompetingOffersBecomeStaleAndWithdrawable() public {
        EscrowContract escrow = _createFunded();
        _offer(escrow, lp, 9_000e6, 0);
        _offer(escrow, lp2, 8_500e6, 0);

        _accept(escrow, lp);

        // lp2's offer was never touched — no loop, no gas ceiling — but is now withdrawable.
        uint256 before = usdc.balanceOf(lp2);
        vm.prank(lp2);
        market.withdrawFunds(address(escrow));
        assertEq(usdc.balanceOf(lp2), before + 8_500e6, "full gross refund");
        assertEq(market.totalDeposits(address(usdc)), 0);
    }

    function testAccept_RevertsWhenPaused() public {
        EscrowContract escrow = _createFunded();
        _offer(escrow, lp, 9_000e6, 0);

        vm.prank(owner);
        market.pause();

        vm.prank(seller);
        escrow.approveRecipientTransfer(address(market), lp);
        vm.prank(seller);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        market.acceptOffer(address(escrow), lp);
    }

    /// Resale: the LP who bought may sell on, and may even re-bid on the same escrow later.
    function testAccept_ResaleWorksAndSlotIsReusable() public {
        EscrowContract escrow = _createFunded();
        _offer(escrow, lp, 9_000e6, 0);
        _accept(escrow, lp);

        _offer(escrow, lp2, 9_200e6, 0);
        _accept(escrow, lp2);
        assertEq(escrow.SELLER(), lp2);

        // The original LP can bid again — no COMPLETED state barred them.
        _offer(escrow, lp, 9_400e6, 0);
        MarketplaceEscrow.Offer memory o = market.getOffer(address(escrow), lp);
        assertEq(uint8(o.status), uint8(MarketplaceEscrow.OfferStatus.OPEN));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // rejectOffer / withdrawFunds — the withdrawability matrix
    // ═══════════════════════════════════════════════════════════════════════════

    function testReject_MarksCancelledButKeepsSlot() public {
        EscrowContract escrow = _createFunded();
        _offer(escrow, lp, 9_000e6, 0);

        vm.prank(seller);
        market.rejectOffer(address(escrow), lp);

        MarketplaceEscrow.Offer memory o = market.getOffer(address(escrow), lp);
        assertEq(uint8(o.status), uint8(MarketplaceEscrow.OfferStatus.CANCELLED));
        assertEq(market.totalDeposits(address(usdc)), 9_000e6, "deposit still held");

        // The LP cannot re-bid until they withdraw.
        usdc.mint(lp, 100e6);
        vm.prank(lp);
        usdc.approve(address(market), 100e6);
        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(MarketplaceEscrow.OfferSlotOccupied.selector, address(escrow), lp));
        market.createOffer(address(escrow), 100e6, 0, 0);
    }

    function testReject_OnlyCurrentRecipient() public {
        EscrowContract escrow = _createFunded();
        _offer(escrow, lp, 9_000e6, 0);

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(MarketplaceEscrow.NotEscrowRecipient.selector, outsider));
        market.rejectOffer(address(escrow), lp);
    }

    function testWithdraw_Cancelled() public {
        EscrowContract escrow = _createFunded();
        _offer(escrow, lp, 9_000e6, 0);
        vm.prank(seller);
        market.rejectOffer(address(escrow), lp);

        uint256 before = usdc.balanceOf(lp);
        vm.prank(lp);
        market.withdrawFunds(address(escrow));

        assertEq(usdc.balanceOf(lp), before + 9_000e6, "full gross including the never-accrued fee");
        assertEq(market.totalDeposits(address(usdc)), 0);
        assertEq(market.accruedFees(address(usdc)), 0, "no fee may accrue on a deal that did not happen");

        MarketplaceEscrow.Offer memory o = market.getOffer(address(escrow), lp);
        assertEq(uint8(o.status), uint8(MarketplaceEscrow.OfferStatus.NONE), "slot freed");
    }

    function testWithdraw_Expired() public {
        EscrowContract escrow = _createFunded();
        _offer(escrow, lp, 9_000e6, 0);

        vm.warp(block.timestamp + DEFAULT_DURATION + 1);
        uint256 before = usdc.balanceOf(lp);
        vm.prank(lp);
        market.withdrawFunds(address(escrow));
        assertEq(usdc.balanceOf(lp), before + 9_000e6);
    }

    function testWithdraw_Stale() public {
        EscrowContract escrow = _createFunded();
        _offer(escrow, lp, 9_000e6, 0);

        vm.prank(seller);
        escrow.changeRecipient(outsider);

        uint256 before = usdc.balanceOf(lp);
        vm.prank(lp);
        market.withdrawFunds(address(escrow));
        assertEq(usdc.balanceOf(lp), before + 9_000e6);
    }

    function testWithdraw_Disputed() public {
        EscrowContract escrow = _createFunded();
        _offer(escrow, lp, 9_000e6, 0);

        vm.prank(buyer);
        escrow.raiseDispute();

        // The LP exits immediately rather than waiting out offerExpiry.
        uint256 before = usdc.balanceOf(lp);
        vm.prank(lp);
        market.withdrawFunds(address(escrow));
        assertEq(usdc.balanceOf(lp), before + 9_000e6);
    }

    function testWithdraw_Claimed() public {
        EscrowContract escrow = _createFunded();
        _offer(escrow, lp, 9_000e6, 0);

        vm.warp(expiry + 1);
        escrow.claimFunds();

        uint256 before = usdc.balanceOf(lp);
        vm.prank(lp);
        market.withdrawFunds(address(escrow));
        assertEq(usdc.balanceOf(lp), before + 9_000e6);
    }

    function testWithdraw_LiveAcceptableOfferReverts() public {
        EscrowContract escrow = _createFunded();
        _offer(escrow, lp, 9_000e6, 0);

        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(MarketplaceEscrow.NothingToWithdraw.selector, address(escrow), lp));
        market.withdrawFunds(address(escrow));
    }

    function testWithdraw_EmptySlotReverts() public {
        EscrowContract escrow = _createFunded();
        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(MarketplaceEscrow.NothingToWithdraw.selector, address(escrow), lp));
        market.withdrawFunds(address(escrow));
    }

    /// §14.2: no state exists where an offer is simultaneously acceptable and withdrawable.
    function testFuzz_NeverBothAcceptableAndWithdrawable(uint8 action, uint32 skipTime) public {
        EscrowContract escrow = _createFunded();
        _offer(escrow, lp, 9_000e6, 0);

        action = action % 4;
        if (action == 1) {
            vm.prank(seller);
            market.rejectOffer(address(escrow), lp);
        } else if (action == 2) {
            vm.prank(seller);
            escrow.changeRecipient(outsider);
        } else if (action == 3) {
            vm.prank(buyer);
            escrow.raiseDispute();
        }
        vm.warp(block.timestamp + (uint256(skipTime) % (40 days)));

        bool withdrawable;
        uint256 snap = vm.snapshotState();
        vm.prank(lp);
        try market.withdrawFunds(address(escrow)) {
            withdrawable = true;
        } catch {
            withdrawable = false;
        }
        vm.revertToState(snap);

        bool acceptable;
        address currentSeller = escrow.SELLER();
        snap = vm.snapshotState();
        vm.prank(currentSeller);
        try escrow.approveRecipientTransfer(address(market), lp) {
            vm.prank(currentSeller);
            try market.acceptOffer(address(escrow), lp) {
                acceptable = true;
            } catch {
                acceptable = false;
            }
        } catch {
            acceptable = false;
        }
        vm.revertToState(snap);

        assertFalse(withdrawable && acceptable, "an offer must never be both at once");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // releaseHoldback
    // ═══════════════════════════════════════════════════════════════════════════

    function testHoldback_RevertsBeforeSettlement() public {
        EscrowContract escrow = _createFunded();
        _offer(escrow, lp, 9_000e6, 500e6);
        _accept(escrow, lp);

        vm.expectRevert(abi.encodeWithSelector(MarketplaceEscrow.EscrowNotSettled.selector, address(escrow)));
        market.releaseHoldback(address(escrow));
    }

    function testHoldback_RevertsWhenNoneExists() public {
        EscrowContract escrow = _createFunded();
        _offer(escrow, lp, 9_000e6, 0);
        _accept(escrow, lp);

        vm.expectRevert(abi.encodeWithSelector(MarketplaceEscrow.NoHoldback.selector, address(escrow)));
        market.releaseHoldback(address(escrow));
    }

    function testHoldback_UndisputedPaysFunderInFull() public {
        EscrowContract escrow = _createFunded();
        uint256 holdback = 500e6;
        _offer(escrow, lp, 9_000e6, holdback);
        _accept(escrow, lp);

        vm.warp(expiry + 1);
        escrow.claimFunds(); // LP collects the whole cashflow

        uint256 sellerBefore = usdc.balanceOf(seller);
        market.releaseHoldback(address(escrow));

        assertEq(usdc.balanceOf(seller), sellerBefore + holdback, "funder gets the reserve back");
        assertEq(market.totalHoldbacks(address(usdc)), 0);
    }

    function testHoldback_DisputedSplitsByLoss() public {
        EscrowContract escrow = _createFunded();
        uint256 holdback = 2_000e6;
        _offer(escrow, lp, 9_000e6, holdback);
        _accept(escrow, lp);

        // Buyer disputes and the parties settle at 10% to the buyer.
        vm.prank(buyer);
        escrow.raiseDispute();
        vm.prank(buyer);
        escrow.submitResolutionVote(10);
        vm.prank(lp);
        escrow.submitResolutionVote(10);
        assertTrue(escrow.isClaimed());

        uint256 loss = (_payout(escrow) * 10) / 100;
        uint256 toBeneficiary = loss < holdback ? loss : holdback;
        uint256 toFunder = holdback - toBeneficiary;

        uint256 lpBefore = usdc.balanceOf(lp);
        uint256 sellerBefore = usdc.balanceOf(seller);

        market.releaseHoldback(address(escrow));

        assertEq(usdc.balanceOf(lp), lpBefore + toBeneficiary, "beneficiary made whole up to the reserve");
        assertEq(usdc.balanceOf(seller), sellerBefore + toFunder);
        assertEq(toBeneficiary + toFunder, holdback, "reserve is redistributed, never created/destroyed");
    }

    /// The reserve FOLLOWS THE POSITION: after a resale it lands on the new holder, not on
    /// the LP who set it.
    function testHoldback_BeneficiaryReadLiveAfterResale() public {
        EscrowContract escrow = _createFunded();
        uint256 holdback = 3_000e6;
        _offer(escrow, lp, 9_000e6, holdback);
        _accept(escrow, lp);

        _offer(escrow, lp2, 9_100e6, 0);
        _accept(escrow, lp2);
        assertEq(escrow.SELLER(), lp2);

        vm.prank(buyer);
        escrow.raiseDispute();
        vm.prank(buyer);
        escrow.submitResolutionVote(100);
        vm.prank(lp2);
        escrow.submitResolutionVote(100);

        uint256 lpBefore = usdc.balanceOf(lp);
        uint256 lp2Before = usdc.balanceOf(lp2);
        market.releaseHoldback(address(escrow));

        assertEq(usdc.balanceOf(lp), lpBefore, "LP1 exits flat - the reserve is not theirs");
        assertEq(usdc.balanceOf(lp2), lp2Before + holdback, "the CURRENT holder is protected");
    }

    function testHoldback_BeneficiaryFollowsDirectChangeRecipient() public {
        EscrowContract escrow = _createFunded();
        uint256 holdback = 3_000e6;
        _offer(escrow, lp, 9_000e6, holdback);
        _accept(escrow, lp);

        // A direct OTC transfer, outside the marketplace entirely.
        vm.prank(lp);
        escrow.changeRecipient(outsider);

        vm.prank(buyer);
        escrow.raiseDispute();
        vm.prank(buyer);
        escrow.submitResolutionVote(100);
        vm.prank(outsider);
        escrow.submitResolutionVote(100);

        uint256 before = usdc.balanceOf(outsider);
        market.releaseHoldback(address(escrow));
        assertEq(usdc.balanceOf(outsider), before + holdback);
    }

    function testHoldback_SecondCallReverts() public {
        EscrowContract escrow = _createFunded();
        _offer(escrow, lp, 9_000e6, 500e6);
        _accept(escrow, lp);

        vm.warp(expiry + 1);
        escrow.claimFunds();
        market.releaseHoldback(address(escrow));

        vm.expectRevert(abi.encodeWithSelector(MarketplaceEscrow.NoHoldback.selector, address(escrow)));
        market.releaseHoldback(address(escrow));
    }

    /// A 0% resolution and the 255 sentinel must both pay the funder in full.
    function testHoldback_ZeroPercentResolutionPaysFunderInFull() public {
        EscrowContract escrow = _createFunded();
        uint256 holdback = 500e6;
        _offer(escrow, lp, 9_000e6, holdback);
        _accept(escrow, lp);

        vm.prank(buyer);
        escrow.raiseDispute();
        vm.prank(buyer);
        escrow.submitResolutionVote(0);
        vm.prank(lp);
        escrow.submitResolutionVote(0);
        assertEq(escrow.resolvedBuyerPercentage(), 0);

        uint256 before = usdc.balanceOf(seller);
        market.releaseHoldback(address(escrow));
        assertEq(usdc.balanceOf(seller), before + holdback);
    }

    /// §14.2: the marketplace's loss maths must match _executeResolution's division to the
    /// wei, across the whole percentage range.
    function testFuzz_HoldbackRoundingMatchesEscrow(uint8 pct, uint256 holdbackSeed) public {
        pct = uint8(bound(pct, 0, 100));
        EscrowContract escrow = _createFunded();
        uint256 payout = _payout(escrow);
        uint256 holdback = bound(holdbackSeed, 1, 4_000e6);

        _offer(escrow, lp, 9_000e6, holdback);
        _accept(escrow, lp);

        vm.prank(buyer);
        escrow.raiseDispute();
        vm.prank(buyer);
        escrow.submitResolutionVote(pct);
        vm.prank(lp);
        escrow.submitResolutionVote(pct);

        // The exact figure the escrow paid the buyer.
        uint256 escrowBuyerAmount = (payout * pct) / 100;

        uint256 lpBefore = usdc.balanceOf(lp);
        uint256 sellerBefore = usdc.balanceOf(seller);
        market.releaseHoldback(address(escrow));

        uint256 toBeneficiary = usdc.balanceOf(lp) - lpBefore;
        uint256 toFunder = usdc.balanceOf(seller) - sellerBefore;

        uint256 expectedToBeneficiary = escrowBuyerAmount < holdback ? escrowBuyerAmount : holdback;
        assertEq(toBeneficiary, expectedToBeneficiary, "split must use the escrow's own division");
        assertEq(toBeneficiary + toFunder, holdback, "conservation");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Owner surface
    // ═══════════════════════════════════════════════════════════════════════════

    function testOwner_FeeCap() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(MarketplaceEscrow.FeeTooHigh.selector, 1001, 1000));
        market.setFeeRate(1001);

        vm.prank(owner);
        market.setFeeRate(1000);
        assertEq(market.feeRateBps(), 1000);
    }

    function testOwner_MinOfferCap() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(MarketplaceEscrow.MinOfferTooHigh.selector, 10001, 10000));
        market.setMinOfferBps(10001);
    }

    function testOwner_DurationMustBeNonZero() public {
        vm.prank(owner);
        vm.expectRevert(MarketplaceEscrow.ZeroOfferDuration.selector);
        market.setDefaultOfferDuration(0);
    }

    function testOwner_OnlyOwnerGuards() public {
        vm.startPrank(outsider);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        market.setFeeRate(10);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        market.pause();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        market.withdrawFees(address(usdc), outsider, 1);
        vm.stopPrank();
    }

    function testOwner_WithdrawFeesCappedByAccrued() public {
        EscrowContract escrow = _createFunded();
        uint256 amount = 9_000e6;
        _offer(escrow, lp, amount, 0);
        _accept(escrow, lp);

        uint256 fee = (amount * FEE_BPS) / 10000;
        assertEq(market.accruedFees(address(usdc)), fee);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(MarketplaceEscrow.InsufficientAccruedFees.selector, address(usdc), fee + 1, fee)
        );
        market.withdrawFees(address(usdc), owner, fee + 1);

        vm.prank(owner);
        market.withdrawFees(address(usdc), owner, fee);
        assertEq(usdc.balanceOf(owner), fee);
        assertEq(market.accruedFees(address(usdc)), 0);
    }

    /// The owner cannot reach a live LP deposit even though it sits in the same balance.
    function testOwner_CannotTouchLiveDeposits() public {
        EscrowContract escrow = _createFunded();
        _offer(escrow, lp, 9_000e6, 0);

        assertEq(usdc.balanceOf(address(market)), 9_000e6);
        assertEq(market.accruedFees(address(usdc)), 0);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(MarketplaceEscrow.InsufficientAccruedFees.selector, address(usdc), 1, 0));
        market.withdrawFees(address(usdc), owner, 1);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(MarketplaceEscrow.NothingToSweep.selector, address(usdc)));
        market.sweepToken(address(usdc), owner);
    }

    function testSweep_MovesOnlyExcess() public {
        EscrowContract escrow = _createFunded();
        _offer(escrow, lp, 9_000e6, 0);

        // Someone fat-fingers a transfer straight to the marketplace.
        usdc.mint(address(market), 1_234e6);

        vm.prank(owner);
        market.sweepToken(address(usdc), owner);

        assertEq(usdc.balanceOf(owner), 1_234e6, "only the excess moves");
        assertEq(usdc.balanceOf(address(market)), 9_000e6, "the deposit is untouched");

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(MarketplaceEscrow.NothingToSweep.selector, address(usdc)));
        market.sweepToken(address(usdc), owner);
    }

    function testSweep_CannotTouchHoldbacks() public {
        EscrowContract escrow = _createFunded();
        _offer(escrow, lp, 9_000e6, 1_000e6);
        _accept(escrow, lp);

        // Fees were accrued and the holdback is held; nothing is sweepable.
        // Read BEFORE pranking: a view call would otherwise consume the prank.
        uint256 accrued = market.accruedFees(address(usdc));
        vm.prank(owner);
        market.withdrawFees(address(usdc), owner, accrued);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(MarketplaceEscrow.NothingToSweep.selector, address(usdc)));
        market.sweepToken(address(usdc), owner);

        assertEq(usdc.balanceOf(address(market)), 1_000e6, "the holdback remains");
    }

    function testConstructor_Validation() public {
        vm.expectRevert(MarketplaceEscrow.ZeroAddress.selector);
        new MarketplaceEscrow(address(0), FEE_BPS, MIN_OFFER_BPS, DEFAULT_DURATION, owner);

        vm.expectRevert(MarketplaceEscrow.ZeroAddress.selector);
        new MarketplaceEscrow(address(implementation), FEE_BPS, MIN_OFFER_BPS, DEFAULT_DURATION, address(0));

        vm.expectRevert(abi.encodeWithSelector(MarketplaceEscrow.FeeTooHigh.selector, 1001, 1000));
        new MarketplaceEscrow(address(implementation), 1001, MIN_OFFER_BPS, DEFAULT_DURATION, owner);

        vm.expectRevert(abi.encodeWithSelector(MarketplaceEscrow.MinOfferTooHigh.selector, 10001, 10000));
        new MarketplaceEscrow(address(implementation), FEE_BPS, 10001, DEFAULT_DURATION, owner);

        vm.expectRevert(MarketplaceEscrow.ZeroOfferDuration.selector);
        new MarketplaceEscrow(address(implementation), FEE_BPS, MIN_OFFER_BPS, 0, owner);
    }

    function testConstructor_CodehashMatchesRealClone() public {
        EscrowContract escrow = _createFunded();
        assertEq(address(escrow).codehash, market.EXPECTED_ESCROW_CODEHASH());
        assertTrue(market.isTrustedEscrow(address(escrow)));
    }

    /// A live offer's fee is firm — a later setFeeRate does not change its payout.
    function testFeeSnapshot_LiveOfferUnaffectedByRateChange() public {
        EscrowContract escrow = _createFunded();
        uint256 amount = 9_000e6;
        _offer(escrow, lp, amount, 0);
        uint256 quotedFee = (amount * FEE_BPS) / 10000;

        vm.prank(owner);
        market.setFeeRate(1000); // 10x the rate

        uint256 sellerBefore = usdc.balanceOf(seller);
        _accept(escrow, lp);

        assertEq(usdc.balanceOf(seller), sellerBefore + amount - quotedFee, "the seller's quote was firm");
        assertEq(market.accruedFees(address(usdc)), quotedFee);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // §5.2.10 — PAUSE ASYMMETRY. Exits are never pausable.
    // ═══════════════════════════════════════════════════════════════════════════

    function testPauseAsymmetry_AllExitsSucceedWhilePaused() public {
        EscrowContract escrowA = _createFunded();
        EscrowContract escrowB = _createFunded();

        // Set up: one offer to reject+withdraw, one sale with a holdback to release.
        _offer(escrowA, lp, 9_000e6, 0);
        _offer(escrowB, lp2, 9_000e6, 500e6);
        _accept(escrowB, lp2);

        vm.warp(expiry + 1);
        escrowB.claimFunds();

        vm.prank(owner);
        market.pause();

        // rejectOffer — not pausable.
        vm.prank(seller);
        market.rejectOffer(address(escrowA), lp);

        // withdrawFunds — not pausable.
        uint256 lpBefore = usdc.balanceOf(lp);
        vm.prank(lp);
        market.withdrawFunds(address(escrowA));
        assertEq(usdc.balanceOf(lp), lpBefore + 9_000e6);

        // releaseHoldback — not pausable.
        uint256 sellerBefore = usdc.balanceOf(seller);
        market.releaseHoldback(address(escrowB));
        assertEq(usdc.balanceOf(seller), sellerBefore + 500e6);

        assertTrue(market.paused(), "still paused throughout");
    }
}
