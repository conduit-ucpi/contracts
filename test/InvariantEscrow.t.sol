// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {EscrowContract} from "../src/EscrowContract.sol";
import {EscrowContractFactory} from "../src/EscrowContractFactory.sol";

/// Minimal ERC20 with NO constructor pre-mint, so the total token supply equals
/// exactly what we mint. That lets the conservation invariant sum over a closed set
/// of participants and compare against AMOUNT.
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
        require(allowance[from][msg.sender] >= amount, "allowance");
        require(balanceOf[from] >= amount, "balance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// Drives one funded escrow through random legal actions: disputes, votes (by the
/// current seller/buyer/arbiter), claims, recipient reassignments, and fee sweeps (by
/// the sweeper and by impostors, whole and split). Every call is wrapped in try/catch so
/// reverts (wrong state, wrong caller) simply no-op.
contract EscrowHandler is Test {
    EscrowContract public escrow;
    InvToken public token;

    address public buyer;
    address public arbiter;
    address public feeSweeper;
    address public feeTargetA; // where the sweeper sends fees
    address public feeTargetB;
    address[] public reassignTargets; // legal newSeller candidates (never buyer/arbiter)

    constructor(
        EscrowContract _escrow,
        InvToken _token,
        address _buyer,
        address _arbiter,
        address _feeSweeper,
        address _feeTargetA,
        address _feeTargetB,
        address[] memory _reassignTargets
    ) {
        escrow = _escrow;
        token = _token;
        buyer = _buyer;
        arbiter = _arbiter;
        feeSweeper = _feeSweeper;
        feeTargetA = _feeTargetA;
        feeTargetB = _feeTargetB;
        reassignTargets = _reassignTargets;
    }

    /// The sweeper releases the fee, whole or split, at any point in the lifecycle. Legal
    /// targets only: the invariants sum over a closed set, so a stray target would read as
    /// a leak rather than a sweep.
    function sweepFees(uint256 bpsSeed) external {
        uint16 bps1 = uint16(bound(bpsSeed, 1, 10_000));
        uint16 bps2 = 10_000 - bps1;
        vm.prank(feeSweeper);
        try escrow.sweepFees(feeTargetA, bps1, bps2 == 0 ? address(0) : feeTargetB, bps2) {} catch {}
    }

    /// Anyone else trying to sweep, with any arguments, must be a no-op.
    function sweepFeesAsImpostor(uint256 callerSeed, uint256 bpsSeed) external {
        address[4] memory callers = [buyer, escrow.SELLER(), arbiter, address(this)];
        address caller = callers[callerSeed % 4];
        uint16 bps1 = uint16(bound(bpsSeed, 0, 10_000));
        vm.prank(caller);
        try escrow.sweepFees(caller, bps1, caller, 10_000 - bps1) {} catch {}
    }

    function raiseDispute() external {
        vm.prank(buyer);
        try escrow.raiseDispute() {} catch {}
    }

    function vote(uint256 voterSeed, uint256 pct) external {
        address currentSeller = escrow.SELLER();
        address[3] memory voters = [buyer, currentSeller, arbiter];
        address v = voters[voterSeed % 3];
        pct = bound(pct, 0, 100);
        vm.prank(v);
        try escrow.submitResolutionVote(pct) {} catch {}
    }

    function claim(uint256 warpBy) external {
        warpBy = bound(warpBy, 0, 30 days);
        vm.warp(block.timestamp + warpBy);
        try escrow.claimFunds() {} catch {}
    }

    function reassign(uint256 idx) external {
        address newSeller = reassignTargets[idx % reassignTargets.length];
        address currentSeller = escrow.SELLER();
        vm.prank(currentSeller);
        try escrow.changeRecipient(newSeller) {} catch {}
    }

    // Fuzz the one-shot approval path: sometimes approve, sometimes pull, sometimes
    // revoke — in random interleavings with disputes/claims/reassigns above.
    function approveTransfer(uint256 idx, bool revoke) external {
        address currentSeller = escrow.SELLER();
        vm.prank(currentSeller);
        if (revoke) {
            try escrow.approveRecipientTransfer(address(0), address(0)) {} catch {}
        } else {
            address target = reassignTargets[idx % reassignTargets.length];
            try escrow.approveRecipientTransfer(address(this), target) {} catch {}
        }
    }

    function pullTransfer(uint256 idx) external {
        // Handler acts as the operator; try both the approved target and wrong ones.
        address target = reassignTargets[idx % reassignTargets.length];
        try escrow.transferRecipientFrom(target) {} catch {}
    }
}

contract InvariantEscrowTest is Test {
    EscrowContractFactory factory;
    InvToken token;
    EscrowContract escrow;
    EscrowHandler handler;

    uint256 constant AMOUNT = 1000 * 10 ** 6;
    uint256 escrowAmount; // AMOUNT - CREATOR_FEE

    address buyer = address(0xB1);
    address seller = address(0x5E);
    address arbiter = address(0xA6);
    address feeSweeper = address(0xFEE); // the factory's FEE_SWEEPER; never a party, never a target
    address feeTargetA = address(0xFA);
    address feeTargetB = address(0xFB);
    address lp1 = address(0x11);
    address lp2 = address(0x22);

    // Closed set of every address that can ever hold the escrow token.
    address[] participants;

    function setUp() public {
        token = new InvToken();
        token.mint(buyer, AMOUNT);

        EscrowContract impl = new EscrowContract(address(0xDEFA17), bytes20(0));
        factory = new EscrowContractFactory(arbiter, address(impl), feeSweeper, bytes20(0));

        address esc = factory.createEscrowContract(
            address(token), buyer, seller, AMOUNT, block.timestamp + 7 days, "inv", arbiter, bytes32(uint256(64))
        );
        escrow = EscrowContract(esc);
        escrowAmount = escrow.payoutAmount();

        // Fund it so the invariant explores the post-funding state space.
        vm.prank(buyer);
        token.transfer(esc, AMOUNT);
        escrow.checkAndActivate();

        // newSeller candidates: never buyer, never arbiter (rejected on-chain), and we
        // deliberately exclude the fee targets so those addresses stay pure sinks and the
        // fee invariant remains meaningful. (Reassigning to one is legal on-chain but
        // nonsensical, and would just make it a seller receiving a payout.)
        address[] memory targets = new address[](3);
        targets[0] = seller;
        targets[1] = lp1;
        targets[2] = lp2;

        handler = new EscrowHandler(escrow, token, buyer, arbiter, feeSweeper, feeTargetA, feeTargetB, targets);

        participants = [buyer, seller, arbiter, feeSweeper, feeTargetA, feeTargetB, lp1, lp2, address(escrow)];

        targetContract(address(handler));
    }

    /// Total tokens across the closed participant set never changes: no tokens are
    /// created, destroyed, or leaked to any address outside the set.
    function invariant_fundsAreConserved() public view {
        uint256 sum;
        for (uint256 i = 0; i < participants.length; i++) {
            sum += token.balanceOf(participants[i]);
        }
        assertEq(sum, AMOUNT);
    }

    /// The escrow never holds more than the escrowed amount (AMOUNT - fee) plus whatever
    /// of the fee is still set aside: payouts and the sweep only ever reduce it.
    function invariant_escrowNeverExceedsEscrowedPlusRetainedFee() public view {
        assertLe(token.balanceOf(address(escrow)), escrowAmount + escrow.retainedFee());
    }

    /// The fee is conserved: whatever has been swept to the targets plus whatever is still
    /// retained is exactly the fee, at every moment. The sweeper itself never holds any of
    /// it (it only names targets), and no impostor sweep ever moves a unit.
    function invariant_feeIsExactAndOnlyEverSwept() public view {
        uint256 fee = AMOUNT - escrowAmount;
        assertEq(token.balanceOf(feeTargetA) + token.balanceOf(feeTargetB) + escrow.retainedFee(), fee);
        assertEq(token.balanceOf(feeSweeper), 0);
        assertEq(token.balanceOf(arbiter), 0);
    }

    /// The escrow's balance can never be below what it still owes: the escrowed funds
    /// while live, and the retained fee always.
    function invariant_escrowCoversWhatItOwes() public view {
        uint256 owed = escrow.retainedFee();
        if (escrow.isFunded() && !escrow.isClaimed()) owed += escrowAmount;
        assertGe(token.balanceOf(address(escrow)), owed);
    }
}
