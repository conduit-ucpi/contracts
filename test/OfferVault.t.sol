// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {EscrowContract} from "../src/EscrowContract.sol";
import {EscrowContractFactory} from "../src/EscrowContractFactory.sol";
import {OfferVault} from "../src/OfferVault.sol";
import {OfferVaultFactory} from "../src/OfferVaultFactory.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
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

/**
 * §14.2, restated for the per-offer model.
 *
 * The design claim under test is that capital is never pooled: each offer's money lives in
 * its own contract, reachable only by that offer's LP or that offer's seller. Several tests
 * assert vault balances directly, which is possible here precisely because there is no
 * shared ledger to reason about.
 *
 * Integration runs against REAL clones of the phase-1 escrow implementation throughout —
 * the codehash gate makes mocks useless by design, which is the point of the gate.
 */
contract OfferVaultTest is Test {
    EscrowContract internal implementation;
    EscrowContractFactory internal escrowFactory;
    OfferVault internal vaultImpl;
    OfferVaultFactory internal market;
    MockERC20 internal usdc;

    address internal defaultArbiter = makeAddr("defaultArbiterSafe");
    address internal owner = makeAddr("marketplaceOwner");
    address internal feeRecipient = makeAddr("feeRecipient");
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
        escrowFactory = new EscrowContractFactory(platform, address(implementation), platform);
        vaultImpl = new OfferVault();
        market = new OfferVaultFactory(
            address(vaultImpl), address(implementation), FEE_BPS, MIN_OFFER_BPS, DEFAULT_DURATION, feeRecipient, owner
        );
        expiry = block.timestamp + 30 days;
    }

    // ───────────────────────────────────────────────────────────────────────────
    // Helpers
    // ───────────────────────────────────────────────────────────────────────────

    function _createFunded() internal returns (EscrowContract escrow) {
        vm.warp(block.timestamp + 1); // keep the factory's clone salt unique
        vm.prank(platform);
        address addr = escrowFactory.createEscrowContract(address(usdc), buyer, seller, AMOUNT, expiry, "test", arbiter);
        escrow = EscrowContract(addr);

        usdc.mint(buyer, AMOUNT);
        vm.prank(buyer);
        usdc.approve(addr, AMOUNT);
        vm.prank(buyer);
        escrow.depositFunds();
    }

    /// The platform deploys the vault; the LP funds it. Mirrors create-then-deposit.
    function _offer(EscrowContract escrow, address who, uint256 amount, uint256 holdback)
        internal
        returns (OfferVault vault)
    {
        vm.prank(platform);
        vault = OfferVault(market.createOffer(address(escrow), who, amount, holdback, 0));

        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(vault), amount);
        vm.prank(who);
        vault.fund();
    }

    function _accept(EscrowContract escrow, OfferVault vault) internal {
        address currentSeller = escrow.recipient();
        // Read the LP BEFORE the prank: an argument-position call would consume it, and the
        // approval would then come from the test contract rather than the seller.
        address offerLp = vault.lp();
        vm.prank(currentSeller);
        escrow.approveRecipientTransfer(address(vault), offerLp);
        vm.prank(currentSeller);
        vault.accept();
    }

    function _payout(EscrowContract escrow) internal view returns (uint256) {
        return AMOUNT - escrow.CREATOR_FEE();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // The codehash gate — unchanged from the pooled design
    // ═══════════════════════════════════════════════════════════════════════════

    function testCreate_RejectsEOA() public {
        vm.expectRevert(abi.encodeWithSelector(OfferVaultFactory.UntrustedEscrow.selector, outsider));
        market.createOffer(outsider, lp, 1000e6, 0, 0);
    }

    function testCreate_RejectsRawImplementation() public {
        vm.expectRevert(abi.encodeWithSelector(OfferVaultFactory.UntrustedEscrow.selector, address(implementation)));
        market.createOffer(address(implementation), lp, 1000e6, 0, 0);
    }

    function testCreate_RejectsWrongImplementationClone() public {
        EscrowContract otherImpl = new EscrowContract(defaultArbiter);
        address rogue = Clones.clone(address(otherImpl));
        vm.expectRevert(abi.encodeWithSelector(OfferVaultFactory.UntrustedEscrow.selector, rogue));
        market.createOffer(rogue, lp, 1000e6, 0, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Deployment is unprivileged; funding is not
    // ═══════════════════════════════════════════════════════════════════════════

    function testCreate_IsPermissionlessAndMovesNoMoney() public {
        EscrowContract escrow = _createFunded();

        // An outsider may deploy a vault naming someone else as LP — mirroring
        // createEscrowContract, which anyone may call with the parties as parameters.
        vm.prank(outsider);
        OfferVault vault = OfferVault(market.createOffer(address(escrow), lp, 5_000e6, 0, 0));

        // ...but it is an empty shell. No approval was touched, no capital moved.
        assertEq(uint256(vault.status()), uint256(OfferVault.Status.PENDING));
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(vault.lp(), lp);
    }

    function testFund_OnlyTheNamedLp() public {
        EscrowContract escrow = _createFunded();
        vm.prank(platform);
        OfferVault vault = OfferVault(market.createOffer(address(escrow), lp, 5_000e6, 0, 0));

        usdc.mint(outsider, 5_000e6);
        vm.prank(outsider);
        usdc.approve(address(vault), 5_000e6);

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(OfferVault.NotOfferLp.selector, outsider));
        vault.fund();
    }

    function testFund_MakesTheOfferLiveAndHoldsItsOwnCapital() public {
        EscrowContract escrow = _createFunded();
        OfferVault vault = _offer(escrow, lp, 5_000e6, 0);

        assertEq(uint256(vault.status()), uint256(OfferVault.Status.OPEN));
        // The whole point of the model: this offer's money is in this offer's contract.
        assertEq(usdc.balanceOf(address(vault)), 5_000e6);
        assertEq(usdc.balanceOf(address(market)), 0, "the factory must never hold capital");
    }

    function testFund_RejectsAfterExpiry() public {
        EscrowContract escrow = _createFunded();
        vm.prank(platform);
        OfferVault vault = OfferVault(market.createOffer(address(escrow), lp, 5_000e6, 0, 0));

        vm.warp(block.timestamp + DEFAULT_DURATION + 1);
        usdc.mint(lp, 5_000e6);
        vm.prank(lp);
        usdc.approve(address(vault), 5_000e6);
        vm.prank(lp);
        vm.expectRevert(OfferVault.OfferExpiredError.selector);
        vault.fund();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Each function answers to exactly one role
    // ═══════════════════════════════════════════════════════════════════════════

    function testAccept_OnlySeller() public {
        EscrowContract escrow = _createFunded();
        OfferVault vault = _offer(escrow, lp, 5_000e6, 0);

        vm.prank(seller);
        escrow.approveRecipientTransfer(address(vault), lp);

        vm.prank(lp); // the LP cannot force their own offer through
        vm.expectRevert(abi.encodeWithSelector(OfferVault.NotEscrowRecipient.selector, lp));
        vault.accept();

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(OfferVault.NotEscrowRecipient.selector, outsider));
        vault.accept();
    }

    function testReject_OnlySeller() public {
        EscrowContract escrow = _createFunded();
        OfferVault vault = _offer(escrow, lp, 5_000e6, 0);

        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(OfferVault.NotEscrowRecipient.selector, lp));
        vault.reject();
    }

    function testWithdraw_OnlyLp() public {
        EscrowContract escrow = _createFunded();
        OfferVault vault = _offer(escrow, lp, 5_000e6, 0);

        vm.prank(seller);
        vault.reject();

        vm.prank(seller); // even the seller who rejected cannot pull the LP's money out
        vm.expectRevert(abi.encodeWithSelector(OfferVault.NotOfferLp.selector, seller));
        vault.withdraw();
    }

    function testSweep_OnlyFactoryOwner() public {
        EscrowContract escrow = _createFunded();
        OfferVault vault = _offer(escrow, lp, 5_000e6, 0);

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(OfferVault.OnlyFactoryOwner.selector, outsider));
        vault.sweep(address(usdc));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // The swap, the fee, and where the money ends up
    // ═══════════════════════════════════════════════════════════════════════════

    function testAccept_PaysSellerNetAndFeeRecipientImmediately() public {
        EscrowContract escrow = _createFunded();
        uint256 offerAmount = 9_000e6;
        OfferVault vault = _offer(escrow, lp, offerAmount, 0);

        uint256 fee = (offerAmount * FEE_BPS) / 10000;
        _accept(escrow, vault);

        // §6.5: the fee is paid out at acceptance — nothing accrues, so the owner never
        // holds a withdrawable balance anywhere.
        assertEq(usdc.balanceOf(feeRecipient), fee);
        assertEq(usdc.balanceOf(seller), offerAmount - fee);
        assertEq(escrow.recipient(), lp, "the cashflow moved to the LP");
        // With no reserve, the vault is finished and empty.
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(uint256(vault.status()), uint256(OfferVault.Status.SETTLED));
    }

    function testAccept_RequiresTheSellersOneShotApprovalOfThisVault() public {
        EscrowContract escrow = _createFunded();
        OfferVault vault = _offer(escrow, lp, 5_000e6, 0);

        // No approveRecipientTransfer — the pull must fail and nothing may move.
        vm.prank(seller);
        vm.expectRevert();
        vault.accept();

        assertEq(usdc.balanceOf(address(vault)), 5_000e6);
        assertEq(escrow.recipient(), seller);
    }

    function testAccept_UnseatsTheArbiter() public {
        EscrowContract escrow = _createFunded();
        OfferVault vault = _offer(escrow, lp, 5_000e6, 0);
        assertEq(escrow.ARBITER(), arbiter);

        _accept(escrow, vault);

        // §3.3A: the sale empties the seat in the same transaction.
        assertEq(escrow.ARBITER(), address(0));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Exits
    // ═══════════════════════════════════════════════════════════════════════════

    function testReject_LeavesCapitalUntilTheLpWithdraws() public {
        EscrowContract escrow = _createFunded();
        OfferVault vault = _offer(escrow, lp, 5_000e6, 0);

        vm.prank(seller);
        vault.reject();

        // Rejection does not push funds back — the seller shouldn't pay to return them.
        assertEq(usdc.balanceOf(address(vault)), 5_000e6);

        vm.prank(lp);
        vault.withdraw();
        assertEq(usdc.balanceOf(lp), 5_000e6, "returned in full gross, fee never charged");
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    function testWithdraw_OnExpiry() public {
        EscrowContract escrow = _createFunded();
        OfferVault vault = _offer(escrow, lp, 5_000e6, 0);

        vm.prank(lp);
        vm.expectRevert(OfferVault.NothingToWithdraw.selector);
        vault.withdraw();

        vm.warp(block.timestamp + DEFAULT_DURATION + 1);
        vm.prank(lp);
        vault.withdraw();
        assertEq(usdc.balanceOf(lp), 5_000e6);
    }

    function testWithdraw_WhenStaleAfterAnotherLpWon() public {
        EscrowContract escrow = _createFunded();
        OfferVault winner = _offer(escrow, lp, 5_000e6, 0);
        OfferVault loser = _offer(escrow, lp2, 4_000e6, 0);

        _accept(escrow, winner);

        // The losing offer is stale the instant recipient() changed — no cancellation loop
        // was needed, which is what stops sybil dust offers DoS-ing acceptance.
        vm.prank(lp2);
        loser.withdraw();
        assertEq(usdc.balanceOf(lp2), 4_000e6);
    }

    function testWithdraw_WhenEscrowDisputed() public {
        EscrowContract escrow = _createFunded();
        OfferVault vault = _offer(escrow, lp, 5_000e6, 0);

        vm.prank(buyer);
        escrow.raiseDispute();

        // Permanently unacceptable, so the LP exits at once rather than waiting out expiry.
        vm.prank(lp);
        vault.withdraw();
        assertEq(usdc.balanceOf(lp), 5_000e6);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Holdback — one reserve per escrow, and the §0.4c High
    // ═══════════════════════════════════════════════════════════════════════════

    function testHoldback_RetainedInTheVaultAtAcceptance() public {
        EscrowContract escrow = _createFunded();
        uint256 offerAmount = 9_000e6;
        uint256 holdback = 1_000e6;
        OfferVault vault = _offer(escrow, lp, offerAmount, holdback);

        uint256 fee = (offerAmount * FEE_BPS) / 10000;
        _accept(escrow, vault);

        assertEq(usdc.balanceOf(seller), offerAmount - fee - holdback);
        assertEq(usdc.balanceOf(address(vault)), holdback, "the reserve stays in this offer's own vault");
        assertEq(uint256(vault.status()), uint256(OfferVault.Status.ACCEPTED));
    }

    function testHoldback_RejectedOnResaleAtCreation() public {
        EscrowContract escrow = _createFunded();
        OfferVault first = _offer(escrow, lp, 9_000e6, 500e6);
        _accept(escrow, first);

        vm.expectRevert(abi.encodeWithSelector(OfferVaultFactory.HoldbackOnResale.selector, address(escrow)));
        market.createOffer(address(escrow), lp2, 8_000e6, 400e6, 0);
    }

    /**
     * §0.4c High, restated for this model.
     *
     * Two LPs both bid with a reserve while the escrow is unsold — both legal at creation.
     * The seller accepts the first, recording the one permitted reserve. The position then
     * returns to that same seller, which makes the second offer live again. Accepting it
     * must REVERT: in the pooled design it silently overwrote the reserve record and
     * stranded the first reserve forever.
     */
    function testHoldback_SecondReserveRevertsWhenPositionReturns() public {
        EscrowContract escrow = _createFunded();

        OfferVault a = _offer(escrow, lp, 9_000e6, 500e6);
        OfferVault b = _offer(escrow, lp2, 8_000e6, 400e6);

        _accept(escrow, a); // lp now holds the cashflow, reserve recorded against vault a

        // The position comes back to the original seller by a direct transfer.
        vm.prank(lp);
        escrow.changeRecipient(seller);

        // Offer b's seller snapshot matches the current recipient again, so it is live —
        // but it must not be acceptable, because its reserve would strand a's.
        vm.prank(seller);
        escrow.approveRecipientTransfer(address(b), lp2);
        vm.prank(seller);
        vm.expectRevert(OfferVault.HoldbackOnResale.selector);
        b.accept();

        // a's reserve is intact.
        assertEq(usdc.balanceOf(address(a)), 500e6);

        // And b's LP is not trapped — the offer is permanently unacceptable, so they exit.
        vm.prank(lp2);
        b.withdraw();
        assertEq(usdc.balanceOf(lp2), 8_000e6);
    }

    function testReleaseHoldback_PaysFunderWhenNoDispute() public {
        EscrowContract escrow = _createFunded();
        OfferVault vault = _offer(escrow, lp, 9_000e6, 1_000e6);
        _accept(escrow, vault);

        vm.warp(expiry + 1);
        escrow.claimFunds(); // permissionless at maturity; pays the LP as recipient

        uint256 before = usdc.balanceOf(seller);
        vm.prank(seller); // the funder may release
        vault.releaseHoldback();

        assertEq(usdc.balanceOf(seller) - before, 1_000e6, "never disputed => funder gets it all");
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    function testReleaseHoldback_OnlyFunderOrBeneficiary() public {
        EscrowContract escrow = _createFunded();
        OfferVault vault = _offer(escrow, lp, 9_000e6, 1_000e6);
        _accept(escrow, vault);

        vm.warp(expiry + 1);
        escrow.claimFunds();

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(OfferVault.NotHoldbackParty.selector, outsider));
        vault.releaseHoldback();

        // The current beneficiary (the LP who bought the cashflow) may.
        vm.prank(lp);
        vault.releaseHoldback();
    }

    function testReleaseHoldback_RevertsBeforeSettlement() public {
        EscrowContract escrow = _createFunded();
        OfferVault vault = _offer(escrow, lp, 9_000e6, 1_000e6);
        _accept(escrow, vault);

        vm.prank(seller);
        vm.expectRevert(OfferVault.EscrowNotSettled.selector);
        vault.releaseHoldback();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Owner surface — bounded, and never over funds
    // ═══════════════════════════════════════════════════════════════════════════

    function testPause_BlocksNewOffersButNeverExits() public {
        EscrowContract escrow = _createFunded();
        OfferVault vault = _offer(escrow, lp, 5_000e6, 0);

        vm.prank(owner);
        market.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        market.createOffer(address(escrow), lp2, 4_000e6, 0, 0);

        // Exits stay open while paused — §5.2.10.
        vm.prank(seller);
        vault.reject();
        vm.prank(lp);
        vault.withdraw();
        assertEq(usdc.balanceOf(lp), 5_000e6);
    }

    function testSweep_RecoversMisSentTokensButNeverTheDeposit() public {
        EscrowContract escrow = _createFunded();
        OfferVault vault = _offer(escrow, lp, 5_000e6, 0);

        // Someone fat-fingers a transfer straight to the vault.
        usdc.mint(outsider, 123e6);
        vm.prank(outsider);
        usdc.transfer(address(vault), 123e6);

        vm.prank(owner);
        vault.sweep(address(usdc));

        assertEq(usdc.balanceOf(feeRecipient), 123e6, "only the surplus");
        assertEq(usdc.balanceOf(address(vault)), 5_000e6, "the LP's deposit is untouchable");

        // And the LP can still exit in full afterwards.
        vm.prank(seller);
        vault.reject();
        vm.prank(lp);
        vault.withdraw();
        assertEq(usdc.balanceOf(lp), 5_000e6);
    }

    function testSweep_CannotTouchALiveReserve() public {
        EscrowContract escrow = _createFunded();
        OfferVault vault = _offer(escrow, lp, 9_000e6, 1_000e6);
        _accept(escrow, vault);

        vm.prank(owner);
        vm.expectRevert(OfferVault.NothingToSweep.selector);
        vault.sweep(address(usdc));

        assertEq(usdc.balanceOf(address(vault)), 1_000e6);
    }

    function testFactoryHoldsNoBalanceEverAcrossAFullCycle() public {
        EscrowContract escrow = _createFunded();
        OfferVault a = _offer(escrow, lp, 9_000e6, 1_000e6);
        OfferVault b = _offer(escrow, lp2, 4_000e6, 0);

        assertEq(usdc.balanceOf(address(market)), 0);
        _accept(escrow, a);
        assertEq(usdc.balanceOf(address(market)), 0);

        vm.prank(lp2);
        b.withdraw();
        assertEq(usdc.balanceOf(address(market)), 0, "the venue is never a custodian");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Registry integrity
    // ═══════════════════════════════════════════════════════════════════════════

    /// The one-reserve fact now lives on the escrow, set by the swap itself — so there is
    /// no venue-side registry that a redeploy could lose or a caller could forge.
    function testEscrowRecordsTheSaleItself() public {
        EscrowContract escrow = _createFunded();
        assertFalse(escrow.hasBeenSold());

        OfferVault vault = _offer(escrow, lp, 5_000e6, 0);
        _accept(escrow, vault);

        assertTrue(escrow.hasBeenSold());
    }

    /// A seller rotating their own payout wallet is NOT a sale (§3.3A draws the same line
    /// for arbiter unseating), so it must not consume the one permitted reserve.
    function testChangeRecipientIsNotASale() public {
        EscrowContract escrow = _createFunded();

        vm.prank(seller);
        escrow.changeRecipient(outsider);

        assertFalse(escrow.hasBeenSold(), "an OTC rotation must not count as a sale");
    }

    function testImplementationCannotBeInitialized() public {
        vm.expectRevert(OfferVault.ImplementationCannotBeInitialized.selector);
        vaultImpl.initialize(address(1), address(2), address(3), address(usdc), 1, 0, 1, 0, block.timestamp + 1);
    }

    function testFactoryHasNoPerEscrowStorage() public {
        EscrowContract escrow = _createFunded();
        _offer(escrow, lp, 5_000e6, 0);
        _offer(escrow, lp2, 4_000e6, 0);

        // Nothing accumulates on the venue: the offer book is the OfferCreated event, and
        // the one-reserve fact is on the escrow. A redeployed factory loses nothing.
        assertEq(usdc.balanceOf(address(market)), 0);
        assertTrue(market.isTrustedEscrow(address(escrow)));
    }
}
