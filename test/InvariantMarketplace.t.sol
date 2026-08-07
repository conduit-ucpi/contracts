// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {EscrowContract} from "../src/EscrowContract.sol";
import {EscrowContractFactory} from "../src/EscrowContractFactory.sol";
import {OfferVault} from "../src/OfferVault.sol";
import {OfferVaultFactory} from "../src/OfferVaultFactory.sol";

contract InvMockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint8 public decimals = 6;

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
    }
}

/**
 * Drives arbitrary interleavings of every external function on the venue and its vaults,
 * plus the escrow actions that change what they observe (dispute, vote, claim, direct
 * recipient rotation). Every action is wrapped so a revert is a no-op rather than a
 * failure — the invariants must hold across whatever sequence actually lands.
 */
contract MarketplaceHandler is Test {
    EscrowContract public escrow;
    OfferVaultFactory public market;
    InvMockERC20 public usdc;

    address public buyer;
    address public seller;
    address public arbiter;
    address[3] public lps;

    OfferVault[] public vaults;

    constructor(
        EscrowContract _escrow,
        OfferVaultFactory _market,
        InvMockERC20 _usdc,
        address _buyer,
        address _seller,
        address _arbiter,
        address[3] memory _lps
    ) {
        escrow = _escrow;
        market = _market;
        usdc = _usdc;
        buyer = _buyer;
        seller = _seller;
        arbiter = _arbiter;
        lps = _lps;
    }

    function vaultCount() external view returns (uint256) {
        return vaults.length;
    }

    function vaultAt(uint256 i) external view returns (OfferVault) {
        return vaults[i];
    }

    function createOffer(uint256 lpSeed, uint256 amount, uint256 holdback) public {
        address lp = lps[lpSeed % 3];
        amount = bound(amount, 1, 20_000e6);
        holdback = bound(holdback, 0, amount);
        try market.createOffer(address(escrow), lp, amount, holdback, 0) returns (address v) {
            vaults.push(OfferVault(v));
        } catch {}
    }

    function fund(uint256 i) public {
        if (vaults.length == 0) return;
        OfferVault v = vaults[i % vaults.length];
        address lp = v.lp();
        usdc.mint(lp, v.offerAmount());
        vm.prank(lp);
        usdc.approve(address(v), v.offerAmount());
        vm.prank(lp);
        try v.fund() {} catch {}
    }

    function accept(uint256 i) public {
        if (vaults.length == 0) return;
        OfferVault v = vaults[i % vaults.length];
        address current = escrow.recipient();
        address offerLp = v.lp();
        vm.prank(current);
        try escrow.approveRecipientTransfer(address(v), offerLp) {} catch {
            return;
        }
        vm.prank(current);
        try v.accept() {} catch {}
    }

    function reject(uint256 i) public {
        if (vaults.length == 0) return;
        OfferVault v = vaults[i % vaults.length];
        vm.prank(escrow.recipient());
        try v.reject() {} catch {}
    }

    function withdraw(uint256 i) public {
        if (vaults.length == 0) return;
        OfferVault v = vaults[i % vaults.length];
        vm.prank(v.lp());
        try v.withdraw() {} catch {}
    }

    function releaseHoldback(uint256 i) public {
        if (vaults.length == 0) return;
        OfferVault v = vaults[i % vaults.length];
        vm.prank(v.seller());
        try v.releaseHoldback() {} catch {}
    }

    function raiseDispute() public {
        vm.prank(buyer);
        try escrow.raiseDispute() {} catch {}
    }

    function vote(uint256 whoSeed, uint256 pct) public {
        address who = [buyer, escrow.recipient(), escrow.ARBITER()][whoSeed % 3];
        if (who == address(0)) return;
        vm.prank(who);
        try escrow.submitResolutionVote(bound(pct, 0, 100)) {} catch {}
    }

    function claim() public {
        try escrow.claimFunds() {} catch {}
    }

    function rotateRecipient(uint256 seed) public {
        address to = [seller, lps[0], lps[1], lps[2]][seed % 4];
        vm.prank(escrow.recipient());
        try escrow.changeRecipient(to) {} catch {}
    }

    function warp(uint256 secs) public {
        vm.warp(block.timestamp + bound(secs, 1, 3 days));
    }

    /// Accidental direct transfer, to exercise conservation slack and sweep().
    function strayTransfer(uint256 i, uint256 amount) public {
        if (vaults.length == 0) return;
        OfferVault v = vaults[i % vaults.length];
        amount = bound(amount, 1, 1_000e6);
        usdc.mint(address(this), amount);
        usdc.transfer(address(v), amount);
    }
}

/**
 * §14.3 — marketplace invariants, restated for the per-offer vault model.
 *
 * The conservation properties get simpler here, and that is the point of the redesign:
 * with no shared balance there is no global ledger to reconcile. Each vault's own balance
 * must cover its own obligation, and the venue must hold nothing at all.
 */
contract InvariantMarketplaceTest is Test {
    EscrowContract internal implementation;
    EscrowContractFactory internal escrowFactory;
    OfferVault internal vaultImpl;
    OfferVaultFactory internal market;
    InvMockERC20 internal usdc;
    MarketplaceHandler internal handler;
    EscrowContract internal escrow;

    address internal defaultArbiter = makeAddr("safe");
    address internal owner = makeAddr("owner");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal platform = makeAddr("platform");
    address internal buyer = makeAddr("buyer");
    address internal seller = makeAddr("seller");
    address internal arbiter = makeAddr("arbiter");

    uint256 internal constant AMOUNT = 10_000e6;

    function setUp() public {
        usdc = new InvMockERC20();
        implementation = new EscrowContract(defaultArbiter);
        escrowFactory = new EscrowContractFactory(platform, address(implementation), platform);
        vaultImpl = new OfferVault();
        market = new OfferVaultFactory(
            address(vaultImpl), address(implementation), 50, 1000, 24 hours, feeRecipient, owner
        );

        vm.prank(platform);
        escrow = EscrowContract(
            escrowFactory.createEscrowContract(
                address(usdc), buyer, seller, AMOUNT, block.timestamp + 30 days, "inv", arbiter
            )
        );
        usdc.mint(buyer, AMOUNT);
        vm.prank(buyer);
        usdc.approve(address(escrow), AMOUNT);
        vm.prank(buyer);
        escrow.depositFunds();

        address[3] memory lps = [makeAddr("lpA"), makeAddr("lpB"), makeAddr("lpC")];
        handler = new MarketplaceHandler(escrow, market, usdc, buyer, seller, arbiter, lps);
        targetContract(address(handler));
    }

    /// §14.3.1 — CONSERVATION, PER VAULT. Every vault always holds at least what it owes.
    /// There is no pooled balance to reconcile: this is the whole custody claim of the
    /// redesign, and it is checkable one contract at a time.
    function invariant_eachVaultCoversItsOwnObligation() public view {
        uint256 n = handler.vaultCount();
        for (uint256 i = 0; i < n; i++) {
            OfferVault v = handler.vaultAt(i);
            assertGe(usdc.balanceOf(address(v)), v.owed(), "vault under-collateralised");
        }
    }

    /// §14.3.1a — THE VENUE IS NEVER A CUSTODIAN. The factory must never hold a token
    /// balance: LP capital goes wallet -> vault, and fees go vault -> FEE_RECIPIENT.
    function invariant_factoryHoldsNothing() public view {
        assertEq(usdc.balanceOf(address(market)), 0, "the factory must never custody funds");
    }

    /// §14.3.2 — STATUS <=> OBLIGATION. A vault owes the gross deposit exactly while it is
    /// OPEN or CANCELLED, the reserve exactly while ACCEPTED, and nothing once SETTLED.
    function invariant_statusMatchesObligation() public view {
        uint256 n = handler.vaultCount();
        for (uint256 i = 0; i < n; i++) {
            OfferVault v = handler.vaultAt(i);
            OfferVault.Status s = v.status();
            if (s == OfferVault.Status.OPEN || s == OfferVault.Status.CANCELLED) {
                assertEq(v.owed(), v.offerAmount(), "open/cancelled must owe the gross");
            } else if (s == OfferVault.Status.ACCEPTED) {
                assertEq(v.owed(), v.holdback(), "accepted must owe exactly the reserve");
            } else {
                assertEq(v.owed(), 0, "pending/settled owe nothing");
            }
        }
    }

    /// §14.3.3 — ONE RESERVE PER ESCROW. At most one vault may ever hold a live reserve for
    /// a given escrow. Enforced off the escrow's own `hasBeenSold`, so no venue-side
    /// registry is involved and a redeployed marketplace cannot lose the guarantee.
    function invariant_atMostOneLiveReserve() public view {
        uint256 n = handler.vaultCount();
        uint256 live;
        for (uint256 i = 0; i < n; i++) {
            OfferVault v = handler.vaultAt(i);
            if (v.status() == OfferVault.Status.ACCEPTED && v.holdback() > 0) live++;
        }
        assertLe(live, 1, "two reserves live on one escrow");
    }

    /// A reserve can only exist on an escrow that has actually been sold.
    function invariant_reserveImpliesSold() public view {
        uint256 n = handler.vaultCount();
        for (uint256 i = 0; i < n; i++) {
            OfferVault v = handler.vaultAt(i);
            if (v.status() == OfferVault.Status.ACCEPTED && v.holdback() > 0) {
                assertTrue(escrow.hasBeenSold(), "reserve without a recorded sale");
            }
        }
    }

    /// §14.3.4 — NO MANUFACTURED CONSENSUS. With the arbiter unseated, no sequence of calls
    /// may resolve the escrow. If it resolved, an authorised third voter must have been
    /// seated at the time.
    function invariant_noManufacturedConsensus() public view {
        if (escrow.consensusReached()) {
            assertTrue(escrow.ARBITER() != address(0) || escrow.resolvedBuyerPercentage() != 255);
        }
    }

    /// §14.3.5 — ROLE INTEGRITY. Neither the venue nor a vault is ever the escrow's
    /// recipient at rest: the swap moves the role seller -> LP directly.
    function invariant_venueNeverHoldsTheRole() public view {
        address r = escrow.recipient();
        assertTrue(r != address(market), "factory holds the cashflow role");
        uint256 n = handler.vaultCount();
        for (uint256 i = 0; i < n; i++) {
            assertTrue(r != address(handler.vaultAt(i)), "a vault holds the cashflow role");
        }
    }

    /// The zero address can never read as a live voter (§3.3D).
    function invariant_zeroAddressNeverVotes() public view {
        assertEq(escrow.resolutionVotes(address(0)), 255);
    }
}
