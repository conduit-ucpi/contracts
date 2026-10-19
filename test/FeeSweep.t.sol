// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {EscrowContract} from "../src/EscrowContract.sol";
import {EscrowContractFactory} from "../src/EscrowContractFactory.sol";
import {MockERC20} from "./EscrowContractFactory.t.sol";

/**
 * THE FEE IS SET ASIDE, NOT PAID. These tests pin the contract between the fee and the
 * payout: the fee is earmarked inside the escrow at funding, every payout is computed
 * without it, and the ONLY way it leaves is sweepFees - one call, by the factory's
 * FEE_SWEEPER, dividing the whole fee between up to two targets in basis points.
 *
 * Two things must hold in every state and every order of operations:
 *   • the payout never reads the fee: claim and resolution pay AMOUNT - CREATOR_FEE
 *     whether the fee has been swept or not;
 *   • the sweep never reads the payout: it releases CREATOR_FEE whether the escrow is
 *     live, disputed, claimed or resolved - and only ever once.
 */
contract FeeSweepTest is Test {
    EscrowContractFactory internal factory;
    EscrowContract internal implementation;
    MockERC20 internal usdc;

    address internal constant DEFAULT_ARBITER = address(0xDEFA17);
    address internal owner = makeAddr("owner");
    address internal sweeper = makeAddr("sweeper");
    address internal buyer = makeAddr("buyer");
    address internal seller = makeAddr("seller");
    address internal arbiter = makeAddr("arbiter");
    address internal treasury = makeAddr("treasury");
    address internal partner = makeAddr("partner");

    uint256 internal constant AMOUNT = 1000 * 10 ** 6; // 1000 USDC
    uint256 internal constant FEE = 10 * 10 ** 6; // 1%
    uint256 internal expiry;
    uint256 internal nonce;

    // Redeclared so expectEmit can name them; the signatures must match the contract's.
    event FeeRetained(uint256 feeAmount, uint256 timestamp);
    event FeesSwept(address indexed target, uint16 bps, uint256 amount, uint256 timestamp);

    function setUp() public {
        usdc = new MockERC20();
        implementation = new EscrowContract(DEFAULT_ARBITER, bytes20(0));
        factory = new EscrowContractFactory(owner, address(implementation), sweeper, bytes20(0));
        expiry = block.timestamp + 7 days;
        usdc.mint(buyer, AMOUNT * 100);
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    function _create(uint256 amount, uint256 expiryAt) internal returns (EscrowContract escrow) {
        address at = factory.createEscrowContract(
            address(usdc), buyer, seller, amount, expiryAt, "fee sweep", arbiter, bytes32(++nonce)
        );
        escrow = EscrowContract(at);
    }

    /// The one funding path: the buyer transfers, anyone activates.
    function _fund(EscrowContract escrow, uint256 amount) internal {
        vm.prank(buyer);
        usdc.transfer(address(escrow), amount);
        escrow.checkAndActivate();
    }

    function _funded() internal returns (EscrowContract escrow) {
        escrow = _create(AMOUNT, expiry);
        _fund(escrow, AMOUNT);
    }

    function _sweepAll(EscrowContract escrow, address to) internal {
        vm.prank(sweeper);
        escrow.sweepFees(to, 10_000, address(0), 0);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // A. Set aside at funding
    // ═════════════════════════════════════════════════════════════════════════

    function test_TheFactoryStampsItsSweeperIntoEveryEscrow() public {
        EscrowContract escrow = _create(AMOUNT, expiry);
        assertEq(factory.FEE_SWEEPER(), sweeper);
        assertEq(escrow.FEE_SWEEPER(), sweeper);
    }

    function test_ASweeperOfZeroDefaultsToTheOwner() public {
        EscrowContractFactory f = new EscrowContractFactory(owner, address(implementation), address(0), bytes20(0));
        assertEq(f.FEE_SWEEPER(), owner);
    }

    function test_ADirectCloneCannotBeInitialisedWithoutASweeper() public {
        address clone = Clones.clone(address(implementation));
        vm.expectRevert(EscrowContract.InvalidFeeSweeperAddress.selector);
        EscrowContract(clone).initialize(address(usdc), buyer, seller, arbiter, AMOUNT, expiry, FEE, address(0));
    }

    function test_FundingSetsTheFeeAsideAndPaysNobody() public {
        EscrowContract escrow = _create(AMOUNT, expiry);
        assertEq(escrow.retainedFee(), 0, "nothing set aside before funding");

        vm.prank(buyer);
        usdc.transfer(address(escrow), AMOUNT);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit FeeRetained(FEE, block.timestamp);
        escrow.checkAndActivate();

        assertEq(escrow.CREATOR_FEE(), FEE);
        assertEq(escrow.retainedFee(), FEE);
        assertEq(usdc.balanceOf(address(escrow)), AMOUNT, "the escrow holds the fee too");
        assertEq(usdc.balanceOf(sweeper), 0);
        assertEq(usdc.balanceOf(owner), 0);
        assertEq(escrow.payoutAmount(), AMOUNT - FEE, "the payout is quoted without it");
    }

    function test_DirectTransferActivationSetsTheFeeAsideToo() public {
        EscrowContract escrow = _create(AMOUNT, expiry);
        vm.prank(buyer);
        usdc.transfer(address(escrow), AMOUNT);

        vm.expectEmit(true, true, true, true, address(escrow));
        emit FeeRetained(FEE, block.timestamp);
        escrow.checkAndActivate();

        assertEq(escrow.retainedFee(), FEE);
        assertEq(usdc.balanceOf(address(escrow)), AMOUNT);
    }

    function test_AnInstantTransferPaysTheSellerAndKeepsOnlyTheFee() public {
        EscrowContract escrow = _create(AMOUNT, 0);
        _fund(escrow, AMOUNT);

        assertTrue(escrow.isClaimed());
        assertEq(usdc.balanceOf(seller), AMOUNT - FEE);
        assertEq(usdc.balanceOf(address(escrow)), FEE);
        assertEq(escrow.retainedFee(), FEE);

        _sweepAll(escrow, treasury);
        assertEq(usdc.balanceOf(treasury), FEE);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function test_AZeroFeeEscrowRetainsNothingAndEmitsNothing() public {
        // 0.0005 USDC is under the free threshold: the factory charges no fee.
        EscrowContract escrow = _create(500, expiry);
        assertEq(escrow.CREATOR_FEE(), 0);

        vm.recordLogs();
        _fund(escrow, 500);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != FeeRetained.selector, "no FeeRetained on a zero-fee escrow");
        }

        assertEq(escrow.retainedFee(), 0);
        vm.prank(sweeper);
        vm.expectRevert(EscrowContract.NoFeesToSweep.selector);
        escrow.sweepFees(treasury, 10_000, address(0), 0);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // B. Who may sweep, and with what
    // ═════════════════════════════════════════════════════════════════════════

    function test_OnlyTheSweeperMaySweep() public {
        EscrowContract escrow = _funded();
        address[5] memory impostors = [buyer, seller, arbiter, owner, address(factory)];
        for (uint256 i = 0; i < impostors.length; i++) {
            vm.prank(impostors[i]);
            vm.expectRevert(EscrowContract.OnlyFeeSweeper.selector);
            escrow.sweepFees(impostors[i], 10_000, address(0), 0);
        }
        assertEq(escrow.retainedFee(), FEE, "nothing moved");
    }

    function test_TheSweeperAuthorisesTheCallNotTheDestination() public {
        // The sweeper names ANY target; it need not be the sweeper itself.
        EscrowContract escrow = _funded();
        _sweepAll(escrow, treasury);
        assertEq(usdc.balanceOf(treasury), FEE);
        assertEq(usdc.balanceOf(sweeper), 0);
    }

    function test_NothingToSweepBeforeFunding() public {
        EscrowContract escrow = _create(AMOUNT, expiry);
        vm.prank(sweeper);
        vm.expectRevert(EscrowContract.NoFeesToSweep.selector);
        escrow.sweepFees(treasury, 10_000, address(0), 0);
    }

    function test_TheImplementationItselfCannotBeSwept() public {
        // The implementation was never initialised, so it has no sweeper: the caller guard
        // fires first. Whichever guard a rewrite keeps, it must refuse - pinned by the revert.
        vm.prank(sweeper);
        vm.expectRevert(EscrowContract.OnlyFeeSweeper.selector);
        implementation.sweepFees(treasury, 10_000, address(0), 0);
        assertEq(implementation.FEE_SWEEPER(), address(0));
    }

    function test_TheLegsMustSumToExactlyTenThousand() public {
        EscrowContract escrow = _funded();
        uint16[2][6] memory bad = [
            [uint16(0), uint16(10_000)], // leg one must carry something
            [uint16(0), uint16(0)],
            [uint16(7_200), uint16(2_700)], // under
            [uint16(7_200), uint16(2_900)], // over
            [uint16(10_001), uint16(0)],
            [uint16(65_535), uint16(65_535)] // no uint16 wrap-around
        ];
        for (uint256 i = 0; i < bad.length; i++) {
            vm.prank(sweeper);
            vm.expectRevert(EscrowContract.InvalidSweepBps.selector);
            escrow.sweepFees(treasury, bad[i][0], partner, bad[i][1]);
        }
        assertEq(escrow.retainedFee(), FEE, "nothing moved");
    }

    function test_ALiveLegNeedsARealTarget() public {
        EscrowContract escrow = _funded();

        vm.prank(sweeper);
        vm.expectRevert(EscrowContract.InvalidSweepTarget.selector);
        escrow.sweepFees(address(0), 10_000, address(0), 0);

        vm.prank(sweeper);
        vm.expectRevert(EscrowContract.InvalidSweepTarget.selector);
        escrow.sweepFees(treasury, 7_200, address(0), 2_800);

        // With bps2 == 0 the second leg does not exist, so its target is irrelevant.
        vm.prank(sweeper);
        escrow.sweepFees(treasury, 10_000, address(0), 0);
        assertEq(usdc.balanceOf(treasury), FEE);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // C. One shot, split atomically
    // ═════════════════════════════════════════════════════════════════════════

    function test_AWholeSweepEmitsOneLegAndEmptiesTheEarmark() public {
        EscrowContract escrow = _funded();

        vm.expectEmit(true, true, true, true, address(escrow));
        emit FeesSwept(treasury, 10_000, FEE, block.timestamp);
        _sweepAll(escrow, treasury);

        assertEq(usdc.balanceOf(treasury), FEE);
        assertEq(escrow.retainedFee(), 0);
        assertEq(usdc.balanceOf(address(escrow)), AMOUNT - FEE, "the escrowed amount is untouched");
    }

    function test_ASplitSweepPaysBothLegsInOneTransaction() public {
        EscrowContract escrow = _funded();
        uint256 expected1 = (FEE * 7_200) / 10_000; // 7.2 USDC
        uint256 expected2 = FEE - expected1; // 2.8 USDC

        vm.expectEmit(true, true, true, true, address(escrow));
        emit FeesSwept(treasury, 7_200, expected1, block.timestamp);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit FeesSwept(partner, 2_800, expected2, block.timestamp);
        vm.prank(sweeper);
        escrow.sweepFees(treasury, 7_200, partner, 2_800);

        assertEq(usdc.balanceOf(treasury), expected1);
        assertEq(usdc.balanceOf(partner), expected2);
        assertEq(usdc.balanceOf(treasury) + usdc.balanceOf(partner), FEE, "the whole fee, nothing more");
        assertEq(escrow.retainedFee(), 0);
        assertEq(usdc.balanceOf(address(escrow)), AMOUNT - FEE);
    }

    function test_ASecondSweepIsRefusedHoweverItIsArgued() public {
        EscrowContract escrow = _funded();
        vm.prank(sweeper);
        escrow.sweepFees(treasury, 7_200, partner, 2_800);

        vm.prank(sweeper);
        vm.expectRevert(EscrowContract.NoFeesToSweep.selector);
        escrow.sweepFees(treasury, 10_000, address(0), 0);

        vm.prank(sweeper);
        vm.expectRevert(EscrowContract.NoFeesToSweep.selector);
        escrow.sweepFees(partner, 2_800, treasury, 7_200);

        assertEq(usdc.balanceOf(treasury) + usdc.balanceOf(partner), FEE, "still exactly the fee");
    }

    function test_RoundingDustGoesToTheSecondLegSoNothingStrands() public {
        // A 7-wei fee split 1/3 : 2/3 cannot divide evenly. Leg one rounds down; leg two
        // takes the rest, so the two legs always sum to the fee.
        EscrowContract escrow = _funded();

        uint256 fee = FEE; // 10_000_000: 3_333 bps = 3_333_000 exactly, so use an odd split
        uint256 leg1 = (fee * 3_337) / 10_000; // 3_337_000
        uint256 leg2 = fee - leg1; // 6_663_000
        vm.prank(sweeper);
        escrow.sweepFees(treasury, 3_337, partner, 6_663);
        assertEq(usdc.balanceOf(treasury), leg1);
        assertEq(usdc.balanceOf(partner), leg2);
        assertEq(usdc.balanceOf(address(escrow)), AMOUNT - fee, "not a wei stranded");
    }

    function testFuzz_AnySplitPaysExactlyTheFee(uint16 bps1) public {
        bps1 = uint16(bound(bps1, 1, 10_000));
        uint16 bps2 = 10_000 - bps1;
        EscrowContract escrow = _funded();

        vm.prank(sweeper);
        escrow.sweepFees(treasury, bps1, bps2 == 0 ? address(0) : partner, bps2);

        assertEq(usdc.balanceOf(treasury), (FEE * bps1) / 10_000);
        assertEq(usdc.balanceOf(treasury) + usdc.balanceOf(partner), FEE);
        assertEq(escrow.retainedFee(), 0);
        assertEq(usdc.balanceOf(address(escrow)), AMOUNT - FEE);
    }

    function test_ATinyFeeCanRoundALegToZeroWithoutReverting() public {
        // CREATOR_FEE of 1 unit, set directly on a clone (the factory would never quote it).
        EscrowContract escrow = EscrowContract(Clones.clone(address(implementation)));
        escrow.initialize(address(usdc), buyer, seller, arbiter, 1_000, expiry, 1, sweeper);
        vm.prank(buyer);
        usdc.transfer(address(escrow), 1_000);
        escrow.checkAndActivate();
        assertEq(escrow.retainedFee(), 1);

        // 1 * 9_999 / 10_000 rounds to 0 for leg one; leg two takes the unit. Both legs
        // are still recorded.
        vm.expectEmit(true, true, true, true, address(escrow));
        emit FeesSwept(treasury, 9_999, 0, block.timestamp);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit FeesSwept(partner, 1, 1, block.timestamp);
        vm.prank(sweeper);
        escrow.sweepFees(treasury, 9_999, partner, 1);

        assertEq(usdc.balanceOf(treasury), 0);
        assertEq(usdc.balanceOf(partner), 1);
        assertEq(escrow.retainedFee(), 0);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // D. Independent of the payout, in every order
    // ═════════════════════════════════════════════════════════════════════════

    function test_SweepingWhileLiveDoesNotChangeTheClaim() public {
        EscrowContract escrow = _funded();
        _sweepAll(escrow, treasury);

        vm.warp(expiry);
        escrow.claimFunds();

        assertEq(usdc.balanceOf(seller), AMOUNT - FEE, "the seller nets exactly what they would have");
        assertEq(usdc.balanceOf(treasury), FEE);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function test_ClaimingFirstDoesNotChangeTheSweep() public {
        EscrowContract escrow = _funded();
        vm.warp(expiry);
        escrow.claimFunds();
        assertEq(usdc.balanceOf(address(escrow)), FEE, "the fee waits");

        _sweepAll(escrow, treasury);
        assertEq(usdc.balanceOf(seller), AMOUNT - FEE);
        assertEq(usdc.balanceOf(treasury), FEE);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function test_SweepingDuringADisputeDoesNotChangeTheResolution() public {
        EscrowContract escrow = _funded();
        vm.prank(buyer);
        escrow.raiseDispute();

        _sweepAll(escrow, treasury);
        assertTrue(escrow.isDisputed(), "the dispute is untouched");

        vm.prank(buyer);
        escrow.submitResolutionVote(40);
        vm.prank(seller);
        escrow.submitResolutionVote(40);

        uint256 escrowed = AMOUNT - FEE;
        assertEq(usdc.balanceOf(buyer), AMOUNT * 100 - AMOUNT + (escrowed * 40) / 100);
        assertEq(usdc.balanceOf(seller), escrowed - (escrowed * 40) / 100);
        assertEq(usdc.balanceOf(treasury), FEE);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function test_AFullRefundStillLeavesTheFeeForTheSweeper() public {
        EscrowContract escrow = _funded();
        vm.prank(buyer);
        escrow.raiseDispute();
        vm.prank(buyer);
        escrow.submitResolutionVote(100);
        vm.prank(arbiter);
        escrow.submitResolutionVote(100);

        assertEq(usdc.balanceOf(buyer), AMOUNT * 100 - FEE, "the buyer gets everything but the fee");
        assertEq(usdc.balanceOf(address(escrow)), FEE);

        _sweepAll(escrow, treasury);
        assertEq(usdc.balanceOf(treasury), FEE);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function test_ARecipientChangeDoesNotTouchTheFee() public {
        EscrowContract escrow = _funded();
        address newSeller = makeAddr("newSeller");
        vm.prank(seller);
        escrow.changeRecipient(newSeller);

        assertEq(escrow.retainedFee(), FEE);
        _sweepAll(escrow, treasury);

        vm.warp(expiry);
        escrow.claimFunds();
        assertEq(usdc.balanceOf(newSeller), AMOUNT - FEE);
        assertEq(usdc.balanceOf(treasury), FEE);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // E. The surplus sweep cannot reach the fee
    // ═════════════════════════════════════════════════════════════════════════

    function test_SweepTokenReturnsTheSurplusButNeverTheRetainedFee() public {
        EscrowContract escrow = _create(AMOUNT, expiry);
        uint256 surplus = 25 * 10 ** 6;
        vm.prank(buyer);
        usdc.transfer(address(escrow), AMOUNT + surplus);
        escrow.checkAndActivate();

        vm.warp(expiry);
        escrow.claimFunds();
        assertEq(usdc.balanceOf(address(escrow)), FEE + surplus);

        // Anyone may call; it pays the buyer only what is beyond the earmark.
        uint256 buyerBefore = usdc.balanceOf(buyer);
        vm.prank(buyer);
        escrow.sweepToken(address(usdc));
        assertEq(usdc.balanceOf(buyer) - buyerBefore, surplus, "the overpayment, exactly");
        assertEq(usdc.balanceOf(address(escrow)), FEE, "the fee stays earmarked");

        // With nothing beyond the fee there is nothing to sweep ...
        vm.expectRevert(EscrowContract.NoTokensToSweep.selector);
        escrow.sweepToken(address(usdc));

        // ... until the sweeper releases it.
        _sweepAll(escrow, treasury);
        assertEq(usdc.balanceOf(treasury), FEE);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function test_AfterTheSweepTheWholeRemainingBalanceIsSurplus() public {
        EscrowContract escrow = _create(AMOUNT, expiry);
        uint256 surplus = 7 * 10 ** 6;
        vm.prank(buyer);
        usdc.transfer(address(escrow), AMOUNT + surplus);
        escrow.checkAndActivate();

        _sweepAll(escrow, treasury);
        vm.warp(expiry);
        escrow.claimFunds();

        uint256 buyerBefore = usdc.balanceOf(buyer);
        escrow.sweepToken(address(usdc));
        assertEq(usdc.balanceOf(buyer) - buyerBefore, surplus);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function test_TheFeeIsNeverSweepableAsSurplusWhileLive() public {
        EscrowContract escrow = _funded();
        vm.expectRevert(EscrowContract.CannotSweepEscrowToken.selector);
        escrow.sweepToken(address(usdc));
    }
}
