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
/// current seller/buyer/arbiter), claims, and recipient reassignments. Every call is
/// wrapped in try/catch so reverts (wrong state, wrong caller) simply no-op.
contract EscrowHandler is Test {
    EscrowContract public escrow;
    InvToken public token;

    address public buyer;
    address public arbiter;
    address[] public reassignTargets; // legal newSeller candidates (never buyer/arbiter)

    constructor(
        EscrowContract _escrow,
        InvToken _token,
        address _buyer,
        address _arbiter,
        address[] memory _reassignTargets
    ) {
        escrow = _escrow;
        token = _token;
        buyer = _buyer;
        arbiter = _arbiter;
        reassignTargets = _reassignTargets;
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
    address feeRecipient = address(0xFEE);
    address lp1 = address(0x11);
    address lp2 = address(0x22);

    // Closed set of every address that can ever hold the escrow token.
    address[] participants;

    function setUp() public {
        token = new InvToken();
        token.mint(buyer, AMOUNT);

        EscrowContract impl = new EscrowContract(address(0xDEFA17));
        factory = new EscrowContractFactory(arbiter, address(impl), feeRecipient);

        address esc = factory.createEscrowContract(
            address(token), buyer, seller, AMOUNT, block.timestamp + 7 days, "inv", arbiter
        , uint64(0));
        escrow = EscrowContract(esc);
        escrowAmount = escrow.payoutAmount();

        // Fund it so the invariant explores the post-funding state space.
        vm.prank(buyer);
        token.approve(esc, AMOUNT);
        vm.prank(buyer);
        escrow.depositFunds();

        // newSeller candidates: never buyer, never arbiter (rejected on-chain), and we
        // deliberately exclude feeRecipient so the fee address stays a pure sink and the
        // fee invariant remains meaningful. (Reassigning to feeRecipient is legal on-chain
        // but nonsensical, and would just make it a seller receiving a payout.)
        address[] memory targets = new address[](3);
        targets[0] = seller;
        targets[1] = lp1;
        targets[2] = lp2;

        handler = new EscrowHandler(escrow, token, buyer, arbiter, targets);

        participants = [buyer, seller, arbiter, feeRecipient, lp1, lp2, address(escrow)];

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

    /// The escrow never holds more than the escrowed amount (AMOUNT - fee): the
    /// platform fee left immediately at deposit and payouts only ever reduce it.
    function invariant_escrowNeverExceedsEscrowed() public view {
        assertLe(token.balanceOf(address(escrow)), escrowAmount);
    }

    /// The fee recipient received exactly the fee and it never moves afterward.
    function invariant_feeIsExactAndImmutable() public view {
        assertEq(token.balanceOf(feeRecipient), AMOUNT - escrowAmount);
    }
}
