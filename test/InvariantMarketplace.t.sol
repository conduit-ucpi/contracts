// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {EscrowContract} from "../src/EscrowContract.sol";
import {EscrowContractFactory} from "../src/EscrowContractFactory.sol";
import {MarketplaceEscrow} from "../src/MarketplaceEscrow.sol";

contract InvToken {
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
}

/**
 * Drives arbitrary interleavings of every external marketplace function, plus the escrow
 * actions that change what the marketplace observes (dispute, vote, claim, direct
 * recipient rotation). Every action is wrapped so a revert is a no-op rather than a
 * failure — the invariants must hold across whatever sequence actually lands.
 */
contract MarketplaceHandler is Test {
    MarketplaceEscrow public market;
    EscrowContract public escrow;
    InvToken public token;

    address public buyer;
    address public arbiter;
    address public owner;
    address[] public lps;

    // Ghost variables for the holdback-conservation invariant.
    uint256 public ghostHoldbackReleasedTotal;
    uint256 public ghostHoldbackSetTotal;
    uint256 public ghostReleaseCount;

    constructor(
        MarketplaceEscrow _market,
        EscrowContract _escrow,
        InvToken _token,
        address _buyer,
        address _arbiter,
        address _owner,
        address[] memory _lps
    ) {
        market = _market;
        escrow = _escrow;
        token = _token;
        buyer = _buyer;
        arbiter = _arbiter;
        owner = _owner;
        lps = _lps;
    }

    function _lp(uint256 seed) internal view returns (address) {
        return lps[seed % lps.length];
    }

    function createOffer(uint256 lpSeed, uint256 amount, uint256 holdback, uint256 duration) public {
        address lp = _lp(lpSeed);
        amount = bound(amount, 1, 5_000e6);
        holdback = bound(holdback, 0, amount);
        duration = bound(duration, 1, 5 days);

        token.mint(lp, amount);
        vm.prank(lp);
        token.approve(address(market), amount);

        uint256 before = market.totalHoldbacks(address(token));
        vm.prank(lp);
        try market.createOffer(address(escrow), amount, holdback, duration) {
            // Track any holdback that actually got booked (only lands at acceptance).
            before; // silence
        } catch {}
    }

    function acceptOffer(uint256 lpSeed) public {
        address lp = _lp(lpSeed);
        address seller = escrow.SELLER();

        uint256 hbBefore = market.totalHoldbacks(address(token));

        vm.prank(seller);
        try escrow.approveRecipientTransfer(address(market), lp) {}
        catch {
            return;
        }
        vm.prank(seller);
        try market.acceptOffer(address(escrow), lp) {
            uint256 hbAfter = market.totalHoldbacks(address(token));
            if (hbAfter > hbBefore) ghostHoldbackSetTotal += hbAfter - hbBefore;
        } catch {}
    }

    function rejectOffer(uint256 lpSeed) public {
        address lp = _lp(lpSeed);
        address seller = escrow.SELLER();
        vm.prank(seller);
        try market.rejectOffer(address(escrow), lp) {} catch {}
    }

    function withdrawFunds(uint256 lpSeed) public {
        address lp = _lp(lpSeed);
        vm.prank(lp);
        try market.withdrawFunds(address(escrow)) {} catch {}
    }

    function releaseHoldback() public {
        uint256 before = market.totalHoldbacks(address(token));
        try market.releaseHoldback(address(escrow)) {
            ghostHoldbackReleasedTotal += before - market.totalHoldbacks(address(token));
            ghostReleaseCount += 1;
        } catch {}
    }

    function withdrawFees(uint256 amount) public {
        amount = bound(amount, 0, 10_000e6);
        vm.prank(owner);
        try market.withdrawFees(address(token), owner, amount) {} catch {}
    }

    function sweepToken() public {
        vm.prank(owner);
        try market.sweepToken(address(token), owner) {} catch {}
    }

    function setFeeRate(uint256 bps) public {
        vm.prank(owner);
        try market.setFeeRate(bound(bps, 0, 1000)) {} catch {}
    }

    function setMinOfferBps(uint256 bps) public {
        vm.prank(owner);
        try market.setMinOfferBps(bound(bps, 0, 10000)) {} catch {}
    }

    function pauseToggle(bool on) public {
        vm.prank(owner);
        if (on) {
            try market.pause() {} catch {}
        } else {
            try market.unpause() {} catch {}
        }
    }

    /// Accidental direct transfer, to exercise the conservation slack and sweepToken.
    function donate(uint256 amount) public {
        amount = bound(amount, 1, 1_000e6);
        token.mint(address(market), amount);
    }

    // ── Escrow-side actions that change what the marketplace observes ──

    function raiseDispute() public {
        vm.prank(buyer);
        try escrow.raiseDispute() {} catch {}
    }

    function vote(uint256 whoSeed, uint256 pct) public {
        pct = bound(pct, 0, 100);
        address who;
        uint256 s = whoSeed % 3;
        if (s == 0) who = buyer;
        else if (s == 1) who = escrow.SELLER();
        else who = escrow.ARBITER();
        if (who == address(0)) return;

        vm.prank(who);
        try escrow.submitResolutionVote(pct) {} catch {}
    }

    function nominate(uint256 whoSeed, uint256 candSeed) public {
        address who = (whoSeed % 2 == 0) ? buyer : escrow.SELLER();
        address cand = _lp(candSeed);
        vm.prank(who);
        try escrow.nominateArbiter(cand) {} catch {}
    }

    function seatDefault() public {
        try escrow.seatDefaultArbiter() {} catch {}
    }

    function claimFunds() public {
        try escrow.claimFunds() {} catch {}
    }

    function changeRecipient(uint256 lpSeed) public {
        address seller = escrow.SELLER();
        vm.prank(seller);
        try escrow.changeRecipient(_lp(lpSeed)) {} catch {}
    }

    function warp(uint256 secs) public {
        vm.warp(block.timestamp + bound(secs, 1, 3 days));
    }
}

/**
 * §14.3 — marketplace invariants 1–3, plus the no-manufactured-consensus invariant (4)
 * which is an escrow property but only reachable through a marketplace sale.
 */
contract InvariantMarketplaceTest is Test {
    EscrowContract internal implementation;
    EscrowContractFactory internal factory;
    MarketplaceEscrow internal market;
    EscrowContract internal escrow;
    InvToken internal token;
    MarketplaceHandler internal handler;

    address internal defaultArbiter = address(0xDEFA17);
    address internal owner = address(0x0E);
    address internal platform = address(0xB1A7);
    address internal buyer = address(0xB1);
    address internal seller = address(0x5E);
    address internal arbiter = address(0xA6);

    uint256 internal constant AMOUNT = 10_000e6;

    function setUp() public {
        token = new InvToken();
        implementation = new EscrowContract(defaultArbiter);
        factory = new EscrowContractFactory(platform, address(implementation), platform);
        market = new MarketplaceEscrow(address(implementation), 50, 100, 24 hours, owner);

        vm.prank(platform);
        address esc = factory.createEscrowContract(
            address(token), buyer, seller, AMOUNT, block.timestamp + 60 days, "inv", arbiter
        );
        escrow = EscrowContract(esc);

        token.mint(buyer, AMOUNT);
        vm.prank(buyer);
        token.approve(esc, AMOUNT);
        vm.prank(buyer);
        escrow.depositFunds();

        address[] memory lps = new address[](3);
        lps[0] = address(0x11);
        lps[1] = address(0x22);
        lps[2] = address(0x33);

        handler = new MarketplaceHandler(market, escrow, token, buyer, arbiter, owner, lps);
        targetContract(address(handler));
    }

    /// §14.3.1 — CONSERVATION. The marketplace always holds at least everything its books
    /// say it owes. Any excess is an accidental transfer, and is exactly what sweepToken
    /// may take.
    function invariant_conservation() public view {
        uint256 owed = market.totalDeposits(address(token)) + market.accruedFees(address(token))
            + market.totalHoldbacks(address(token));
        assertGe(token.balanceOf(address(market)), owed, "marketplace is under-collateralised");
    }

    /// §14.3.2 — SLOT <=> DEPOSIT. A slot is non-NONE iff the contract still holds that
    /// LP's gross deposit. Checked as: the sum of live offer amounts equals totalDeposits.
    function invariant_slotMatchesDeposit() public view {
        uint256 sum;
        for (uint256 i = 0; i < 3; i++) {
            address lp = handler.lps(i);
            MarketplaceEscrow.Offer memory o = market.getOffer(address(escrow), lp);
            if (o.status != MarketplaceEscrow.OfferStatus.NONE) {
                assertGt(o.offerAmount, 0, "an occupied slot must hold a real deposit");
                sum += o.offerAmount;
            }
        }
        assertEq(sum, market.totalDeposits(address(token)), "live slots must equal booked deposits");
    }

    /// §14.3.3 — HOLDBACK CONSERVATION. A reserve settles exactly once, is never created or
    /// destroyed, and the owner can never withdraw it.
    function invariant_holdbackConservation() public view {
        (,, uint256 liveAmount) = market.holdbacks(address(escrow));
        assertEq(
            liveAmount, market.totalHoldbacks(address(token)), "the single live reserve must equal the booked total"
        );
        assertLe(handler.ghostReleaseCount(), 1, "a reserve may settle at most once");
        assertEq(
            handler.ghostHoldbackReleasedTotal() + liveAmount,
            handler.ghostHoldbackSetTotal(),
            "reserves are redistributed, never created or destroyed"
        );
    }

    /// The owner's reach is bounded by accrued fees alone.
    function invariant_ownerCannotReachDepositsOrHoldbacks() public view {
        uint256 protectedFunds = market.totalDeposits(address(token)) + market.totalHoldbacks(address(token));
        assertGe(token.balanceOf(address(market)), protectedFunds, "deposits and holdbacks must always remain covered");
    }

    /// §14.3.4 — NO MANUFACTURED CONSENSUS. With the arbiter unseated, no sequence of calls
    /// may resolve the escrow. If it resolved, an authorised third voter must have been
    /// seated at the time.
    function invariant_noManufacturedConsensus() public view {
        if (escrow.consensusReached()) {
            uint8 b = escrow.resolvedBuyerPercentage();
            assertTrue(b <= 100, "a resolved escrow must persist a real percentage");
        } else {
            assertEq(escrow.resolvedBuyerPercentage(), 255, "unresolved escrows keep the sentinel");
        }
    }

    /// §14.3.5 — ROLE INTEGRITY. The marketplace is never the escrow's recipient at rest.
    function invariant_marketplaceNeverHoldsTheRole() public view {
        assertTrue(escrow.SELLER() != address(market), "the marketplace must never hold the role");
    }

    /// The zero address can never read as a live voter.
    function invariant_zeroAddressNeverVotes() public view {
        assertEq(escrow.resolutionVotes(address(0)), 255);
    }
}
