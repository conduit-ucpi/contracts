// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {EscrowContractFactory} from "../src/EscrowContractFactory.sol";
import {EscrowContract} from "../src/EscrowContract.sol";
import {MockERC20} from "./EscrowContractFactory.t.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/**
 * The fee rule, asked rather than copied, and a fee a caller may choose above it.
 *
 * quoteCreatorFee is the only statement of the rule the services use; the default create
 * functions must charge exactly what it says. The ...WithFee variants accept a higher fee,
 * never a lower one, never all of the amount, and commit it to the address. There is no cap.
 */
contract ChosenFeeTest is Test {
    EscrowContractFactory internal factory;
    MockERC20 internal usdc;

    address internal owner = address(0x1);
    address internal buyer = address(0x2);
    address internal seller = address(0x3);
    address internal arbiter = address(0x9);
    bytes32 internal constant ID = keccak256("507f1f77bcf86cd799439011");

    uint256 internal constant AMOUNT = 1000 * 10 ** 6; // 1000 USDC: rule fee 10 USDC
    uint256 internal expiry;

    function setUp() public {
        usdc = new MockERC20();
        EscrowContract implementation = new EscrowContract(address(0xDEFA17), bytes20(0));
        factory = new EscrowContractFactory(owner, address(implementation), address(0), bytes20(0));
        expiry = block.timestamp + 7 days;
    }

    function _create(uint256 fee) internal returns (EscrowContract) {
        return EscrowContract(
            factory.createEscrowContractWithFee(address(usdc), buyer, seller, AMOUNT, expiry, "d", arbiter, ID, fee)
        );
    }

    // ── quoteCreatorFee: the rule, as a view ─────────────────────────────────────────────

    function testQuoteIsWhatTheDefaultCreateCharges() public {
        uint256[4] memory amounts = [uint256(1000), 500_000, 30 * 10 ** 6, AMOUNT];
        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 quoted = factory.quoteCreatorFee(address(usdc), amounts[i]);
            bytes32 id = keccak256(abi.encode(i));
            EscrowContract escrow = EscrowContract(
                factory.createEscrowContract(address(usdc), buyer, seller, amounts[i], expiry, "d", arbiter, id)
            );
            assertEq(escrow.CREATOR_FEE(), quoted, "the escrow charges exactly the quote");
        }
        assertEq(factory.quoteCreatorFee(address(usdc), 1000), 0, "dust: no fee");
        assertEq(factory.quoteCreatorFee(address(usdc), 500_000), 300_000, "the 0.30 floor");
        assertEq(factory.quoteCreatorFee(address(usdc), AMOUNT), 10 * 10 ** 6, "1%");
    }

    function testQuoteRevertsWhereCreatingWould() public {
        vm.expectRevert(EscrowContractFactory.AmountTooSmallForMinFee.selector);
        factory.quoteCreatorFee(address(usdc), 300_000);
    }

    // ── a chosen fee ─────────────────────────────────────────────────────────────────────

    function testAChosenFeeAboveTheRuleIsCharged() public {
        EscrowContract escrow = _create(50 * 10 ** 6); // 5%
        assertEq(escrow.CREATOR_FEE(), 50 * 10 ** 6);
    }

    function testAChosenFeeMayEqualTheRuleOrBeAlmostAllOfTheAmount() public {
        assertEq(_create(10 * 10 ** 6).CREATOR_FEE(), 10 * 10 ** 6);
        // No cap: anything short of the whole amount. (Same terms, different fee, different address.)
        assertEq(_create(AMOUNT - 1).CREATOR_FEE(), AMOUNT - 1);
    }

    function testAFeeBelowTheRuleIsRefused() public {
        vm.expectRevert(
            abi.encodeWithSelector(EscrowContractFactory.CreatorFeeBelowMinimum.selector, 9 * 10 ** 6, 10 * 10 ** 6)
        );
        _create(9 * 10 ** 6);
    }

    function testAFeeOfTheWholeAmountOrMoreIsRefused() public {
        vm.expectRevert(EscrowContractFactory.CreatorFeeMustBeLessThanAmount.selector);
        _create(AMOUNT);
        vm.expectRevert(EscrowContractFactory.CreatorFeeMustBeLessThanAmount.selector);
        _create(AMOUNT + 1);
    }

    function testAChosenFeeIsOpenToAnyCaller() public {
        vm.prank(address(0xBEEF));
        assertEq(_create(20 * 10 ** 6).CREATOR_FEE(), 20 * 10 ** 6);
    }

    // ── the address commits to the fee ───────────────────────────────────────────────────

    function testTheDefaultAddressIsUnchangedAndAChosenFeeMovesIt() public view {
        address byDefault = factory.getContractAddress(address(usdc), buyer, seller, AMOUNT, expiry, arbiter, ID);
        address atFive =
            factory.getContractAddressWithFee(address(usdc), buyer, seller, AMOUNT, expiry, arbiter, ID, 50 * 10 ** 6);
        address atSix =
            factory.getContractAddressWithFee(address(usdc), buyer, seller, AMOUNT, expiry, arbiter, ID, 60 * 10 ** 6);
        assertTrue(byDefault != atFive && atFive != atSix);
        // Even the rule's own figure, chosen explicitly, is a different address: the salt
        // depends only on which function was called, so nobody needs the rule to predict it.
        address atRule =
            factory.getContractAddressWithFee(address(usdc), buyer, seller, AMOUNT, expiry, arbiter, ID, 10 * 10 ** 6);
        assertTrue(atRule != byDefault);
    }

    /// Existing quotes stay valid: at the default fee the salt is the pre-change encoding.
    function testTheDefaultSaltIsTheOriginalEncoding() public view {
        bytes32 original = keccak256(abi.encodePacked(address(usdc), buyer, seller, AMOUNT, expiry, arbiter, ID));
        assertEq(
            factory.getContractAddress(address(usdc), buyer, seller, AMOUNT, expiry, arbiter, ID),
            Clones.predictDeterministicAddress(factory.IMPLEMENTATION(), original, address(factory))
        );
    }

    function testTheEscrowLandsWhereGetContractAddressWithFeeSays() public {
        address predicted =
            factory.getContractAddressWithFee(address(usdc), buyer, seller, AMOUNT, expiry, arbiter, ID, 50 * 10 ** 6);
        assertEq(address(_create(50 * 10 ** 6)), predicted);
    }

    /// The front-run the salt exists to stop: occupying a quoted address at a different fee.
    function testNobodyCanOccupyAQuotedAddressAtAnotherFee() public {
        address quoted =
            factory.getContractAddressWithFee(address(usdc), buyer, seller, AMOUNT, expiry, arbiter, ID, 50 * 10 ** 6);
        // Attacker deploys the same terms at the default fee and at a higher one first.
        factory.createEscrowContract(address(usdc), buyer, seller, AMOUNT, expiry, "d", arbiter, ID);
        _create(90 * 10 ** 6);
        // Neither took the quoted address; the quoted escrow still deploys there at its fee.
        assertEq(quoted.code.length, 0);
        EscrowContract escrow = _create(50 * 10 ** 6);
        assertEq(address(escrow), quoted);
        assertEq(escrow.CREATOR_FEE(), 50 * 10 ** 6);
    }

    function testLateFundingAtAChosenFeeDeploysAndPaysTheFee() public {
        address predicted =
            factory.getContractAddressWithFee(address(usdc), buyer, seller, AMOUNT, expiry, arbiter, ID, 50 * 10 ** 6);
        usdc.mint(predicted, AMOUNT);
        uint256 before = usdc.balanceOf(owner);

        address deployed = factory.createAndActivateWithFee(
            address(usdc), buyer, seller, AMOUNT, expiry, "d", arbiter, ID, 50 * 10 ** 6
        );

        assertEq(deployed, predicted);
        assertEq(EscrowContract(deployed).retainedFee(), 50 * 10 ** 6, "the chosen fee is set aside");
        vm.prank(owner); // the factory's FEE_SWEEPER, by default
        EscrowContract(deployed).sweepFees(owner, 10_000, address(0), 0);
        assertEq(usdc.balanceOf(owner) - before, 50 * 10 ** 6, "and the sweeper releases it in full");
        assertEq(usdc.balanceOf(deployed), AMOUNT - 50 * 10 ** 6, "the rest is escrowed");
    }
}
