// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {EscrowContract} from "../src/EscrowContract.sol";

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    string public name = "Mock USDC";
    string public symbol = "MUSDC";
    uint8 public decimals = 6;
    uint256 public totalSupply;

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

/**
 * Liveness of the arbiter nomination window, and the unforgeability of the fallback.
 *
 * `NOMINATION_WINDOW` is a 72-hour CONSTANT rather than a per-escrow parameter. It was
 * briefly a caller-supplied value, which was wrong twice over:
 *
 *   1. The value would be chosen by whoever CREATES the escrow, while the cost falls on
 *      the LP who buys the cashflow later — and in the self-dealt-escrow attack the
 *      creator IS the adversary. While the window runs the arbiter seat is empty, so a
 *      stonewalling buyer holds the recipient's capital hostage for its full duration.
 *      A creator-chosen window is a creator-chosen hostage duration.
 *   2. It bought the honest parties nothing, because `nominateArbiter` has no deadline
 *      check: a match seats right up until `seatDefaultArbiter` actually executes.
 *
 * These tests therefore assert the SAFETY PROPERTY — a disputed sold escrow always reaches
 * a third voter within a bounded, plausible time — rather than restating the constant.
 * They also pin the two things an attacker must not be able to forge on a direct clone:
 * the runtime codehash, and `DEFAULT_ARBITER`.
 */
contract ArbiterNominationWindowTest is Test {
    EscrowContract internal impl;
    MockERC20 internal usdc;

    address internal constant DEFAULT_ARBITER = address(0xDEFA17);
    address internal constant BUYER = address(0xB01); // attacker
    address internal constant SELLER = address(0x5E11); // attacker's other leg
    address internal constant ARBITER = address(0xA4B1);
    address internal constant LP = address(0x11D);
    address internal constant MARKETPLACE = address(0x3A4E);
    address internal constant FEE_RECIPIENT = address(0xFEE);

    uint256 internal constant AMOUNT = 1000 * 10 ** 6;
    uint256 internal constant CREATOR_FEE = 10 * 10 ** 6;

    function setUp() public {
        impl = new EscrowContract(DEFAULT_ARBITER);
        usdc = new MockERC20();
        usdc.mint(BUYER, AMOUNT * 10);
        vm.warp(1_700_000_000);
    }

    function _bareClone() internal returns (EscrowContract) {
        return EscrowContract(Clones.clone(address(impl)));
    }

    function _init(EscrowContract e) internal {
        e.initialize(
            address(usdc), BUYER, SELLER, ARBITER, AMOUNT, block.timestamp + 365 days, CREATOR_FEE, FEE_RECIPIENT
        );
    }

    function _clone() internal returns (EscrowContract) {
        EscrowContract e = _bareClone();
        _init(e);
        return e;
    }

    /// Fund, then sell the recipient role to the LP through an approved operator.
    function _fundAndSell(EscrowContract e) internal {
        vm.startPrank(BUYER);
        usdc.approve(address(e), AMOUNT);
        e.depositFunds();
        vm.stopPrank();

        vm.prank(SELLER);
        e.approveRecipientTransfer(MARKETPLACE, LP);
        vm.prank(MARKETPLACE);
        e.transferRecipientFrom(LP);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // What an attacker's direct clone can and cannot forge
    // ═══════════════════════════════════════════════════════════════════════════

    /// The factory-bypass is real: a direct clone is codehash-identical to a factory one,
    /// so it passes the marketplace's genuineness gate. Everything below exists because
    /// this is true.
    function test_DirectCloneIsCodehashGenuine() public {
        EscrowContract viaClone = _clone();
        assertEq(address(viaClone).codehash, Clones.clone(address(impl)).codehash);
    }

    /**
     * ...but the fallback arbitrator is NOT forgeable, which is what makes the bypass
     * survivable. DEFAULT_ARBITER is a Solidity `immutable`, so it lives in the
     * IMPLEMENTATION's runtime bytecode; a clone is a delegatecall stub that runs that same
     * code. Cloning copies no constructor args and no state, and there is no setter, no
     * `initialize` parameter, and no read of `FACTORY` anywhere in the path.
     *
     * This is exactly why the fallback must NOT be sourced from the factory: `initialize`
     * sets `FACTORY = msg.sender`, so on a direct clone the "factory" is the attacker's own
     * contract and could return any address it liked — a self-reported value, the precise
     * class of claim the codehash check exists to avoid trusting.
     */
    function test_DirectCloneCannotForgeDefaultArbiter() public {
        address attacker = address(0xBAD);

        vm.prank(attacker);
        EscrowContract rogue = EscrowContract(Clones.clone(address(impl)));

        assertEq(rogue.DEFAULT_ARBITER(), DEFAULT_ARBITER, "clone reads the honest Safe");
        assertEq(rogue.DEFAULT_ARBITER(), impl.DEFAULT_ARBITER(), "identical to the implementation");

        // Even after the attacker initializes it with themselves as FACTORY.
        vm.prank(attacker);
        _init(rogue);
        assertEq(rogue.FACTORY(), attacker, "attacker really does control FACTORY");
        assertEq(rogue.DEFAULT_ARBITER(), DEFAULT_ARBITER, "...and it changes nothing");
    }

    /// The window is likewise not forgeable, because it is a constant in the same bytecode.
    function test_DirectCloneCannotForgeTheWindow() public {
        vm.prank(address(0xBAD));
        EscrowContract rogue = EscrowContract(Clones.clone(address(impl)));

        assertEq(rogue.NOMINATION_WINDOW(), 72 hours);
        assertEq(rogue.NOMINATION_WINDOW(), impl.NOMINATION_WINDOW());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // LIVENESS GUARD — the property, not the constant.
    // ═══════════════════════════════════════════════════════════════════════════

    /// The longest hostage state we are willing to ship. Deliberately far looser than the
    /// 72-hour window, so this is a real safety bound rather than a restatement of the
    /// constant — but tight enough that any meaningful relaxation trips it.
    uint256 internal constant MAX_TOLERABLE_HOSTAGE = 90 days;

    /**
     * THE GUARD. However the escrow was created and whenever the dispute lands, the
     * fallback arbitrator must become seatable within a bounded, plausible time, and the LP
     * must then be able to settle WITHOUT the buyer's cooperation.
     *
     * Fuzzing the timestamp rather than the window (there is no window to fuzz any more)
     * keeps this honest about the property: raise NOMINATION_WINDOW past the tolerance and
     * this fails, whatever the constant happens to say.
     */
    function testFuzz_FallbackAlwaysReachableAndUnblocksTheLp(uint64 nowTs, uint64 disputeDelay) public {
        vm.warp(bound(nowTs, 1_600_000_000, 4_000_000_000));

        EscrowContract e = _clone();
        _fundAndSell(e);

        // Dispute at an arbitrary point before maturity.
        vm.warp(block.timestamp + bound(disputeDelay, 0, 300 days));
        vm.prank(BUYER);
        e.raiseDispute();

        // 1. The hostage window is bounded.
        uint256 deadline = e.nominationDeadline();
        assertLe(deadline, block.timestamp + MAX_TOLERABLE_HOSTAGE, "the LP is held hostage for too long");

        // 2. During it there is genuinely no escape: no fallback, and no seat to evict.
        vm.expectRevert(abi.encodeWithSelector(EscrowContract.NominationWindowStillOpen.selector, deadline));
        e.seatDefaultArbiter();
        vm.prank(LP);
        vm.expectRevert(EscrowContract.NoArbiterSeated.selector);
        e.evictArbiter();

        // 3. But it always ends, and the fallback is genuinely reachable.
        vm.warp(deadline + 1);
        e.seatDefaultArbiter();
        assertEq(e.ARBITER(), DEFAULT_ARBITER);

        // 4. And a third voter actually unblocks the LP, with the buyer stonewalling.
        vm.prank(DEFAULT_ARBITER);
        e.submitResolutionVote(0);
        vm.prank(LP);
        e.submitResolutionVote(0);

        assertTrue(e.isClaimed(), "LP must settle without the buyer");
        assertEq(usdc.balanceOf(LP), AMOUNT - CREATOR_FEE, "LP made whole");
    }

    /// The window must never outrun the eviction timeout: agreeing on an arbiter should
    /// never take longer than replacing a dead one.
    function test_WindowIsSizedAgainstSilenceTimeout() public view {
        assertLe(
            uint256(impl.NOMINATION_WINDOW()),
            impl.ARBITER_SILENCE_TIMEOUT(),
            "nomination window must not exceed the arbiter-silence timeout"
        );
        assertLe(uint256(impl.NOMINATION_WINDOW()), MAX_TOLERABLE_HOSTAGE, "window within tolerance");
    }

    /**
     * CHARACTERIZATION — why `_nominationDeadlineFromNow` must never clamp.
     *
     * A deadline at type(uint64).max is a PERMANENTLY unseatable fallback: seatDefaultArbiter
     * needs block.timestamp > nominationDeadline, evictArbiter refuses an empty seat, and the
     * escrow is left with two voters and a buyer free to stonewall forever. Clamping would be
     * the vulnerability, not a mitigation of it. Unreachable today only because the window is
     * a 72-hour constant — if that ever becomes caller-influenced, overflow must REVERT.
     */
    function test_SaturatedDeadlineWouldBrickTheEscrow() public {
        EscrowContract e = _clone();
        _fundAndSell(e);
        vm.prank(BUYER);
        e.raiseDispute();

        // nominationDeadline is a uint64 PACKED at slot 14, byte offset 20
        // (`forge inspect EscrowContract storage`). Mask it in rather than clobbering the
        // whole slot, which would corrupt its neighbour. The assert below is the guard: if
        // the layout ever shifts, this test fails loudly rather than silently testing
        // nothing.
        uint256 SLOT = 14;
        uint256 SHIFT = 160; // 20 bytes
        uint256 current = uint256(vm.load(address(e), bytes32(SLOT)));
        uint256 cleared = current & ~(uint256(type(uint64).max) << SHIFT);
        vm.store(address(e), bytes32(SLOT), bytes32(cleared | (uint256(type(uint64).max) << SHIFT)));
        assertEq(e.nominationDeadline(), type(uint64).max, "storage layout changed - fix SLOT/SHIFT");

        vm.warp(type(uint64).max);
        vm.expectRevert(abi.encodeWithSelector(EscrowContract.NominationWindowStillOpen.selector, type(uint64).max));
        e.seatDefaultArbiter();

        vm.prank(LP);
        vm.expectRevert(EscrowContract.NoArbiterSeated.selector);
        e.evictArbiter();

        vm.prank(LP);
        e.submitResolutionVote(0);
        assertFalse(e.consensusReached(), "no third voter exists");
        assertFalse(e.isClaimed(), "LP's capital is stranded");
    }

    /// A late match still wins: the deadline only ENABLES the fallback, it never blocks
    /// agreement. This is why a longer window would buy the honest parties nothing.
    function test_AgreementIsNeverForeclosedByTheDeadline() public {
        EscrowContract e = _clone();
        _fundAndSell(e);
        vm.prank(BUYER);
        e.raiseDispute();

        vm.warp(e.nominationDeadline() + 30 days); // long past the window
        address privateArbiter = address(0xC0FFEE);

        vm.prank(BUYER);
        e.nominateArbiter(privateArbiter);
        vm.prank(LP);
        e.nominateArbiter(privateArbiter);

        assertEq(e.ARBITER(), privateArbiter, "late agreement still seats");
    }
}
